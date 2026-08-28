// remote.c — making the target execute something, and finding what to execute.
//
// Everything here is about driving a process we do not own: hijacking one of its threads to call a
// function, resolving a symbol by walking an image's export trie out of its memory, and placing
// arguments where that call can reach them. Nothing here knows what a bundle is or why we want the
// plaintext; runtime.c owns that.
//
// Split out of runtime.c, which had grown to hold both this and the image-acquisition layer.
#include "internal.h"

#include <mach-o/loader.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>


// Return address for a hijacked call. It sits inside __PAGEZERO, which is unmapped in every 64-bit
// process, so returning to it always faults and never collides with real code. The fault is how we
// learn the call finished; a distinctive value makes it obvious in a crash log that it was ours.
#define DECRYPT_SENTINEL_LR UINT64_C(0xDEAD0000)

// Last call's mach_msg result and the PC it stopped at. A failed remote call has three distinct
// causes (never faulted, faulted somewhere else, state unreadable) that are otherwise identical
// from the outside, and guessing between them wastes a device round trip each time.
static struct {
    mach_msg_return_t received;
    uint64_t pc;
} decrypt_runtime_call_detail;

void decrypt_remote_last_call(mach_msg_return_t *received, uint64_t *pc) {
    if (received)
        *received = decrypt_runtime_call_detail.received;
    if (pc)
        *pc = decrypt_runtime_call_detail.pc;
}

static decrypt_status_t ensure_exception_port(decrypt_process_t *process) {
    if (process->exception_port != MACH_PORT_NULL)
        return DECRYPT_OK;
    mach_port_t port = MACH_PORT_NULL;
    if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port) != KERN_SUCCESS)
        return DECRYPT_PLATFORM_ERROR;
    if (mach_port_insert_right(mach_task_self(), port, port,
                               MACH_MSG_TYPE_MAKE_SEND) != KERN_SUCCESS) {
        mach_port_deallocate(mach_task_self(), port);
        return DECRYPT_PLATFORM_ERROR;
    }
    process->exception_port = port;
    return DECRYPT_OK;
}

// EXCEPTION_DEFAULT layout. Hand-rolled rather than pulled in through MIG because we only ever
// read two fields out of it and never generate the server.
typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t thread;
    mach_msg_port_descriptor_t task;
    NDR_record_t ndr;
    int32_t exception;
    uint32_t code_count;
    int64_t code[2];
    char trailer[64];
} decrypt_exception_message_t;

decrypt_status_t decrypt_runtime_call(decrypt_process_t *process,
                                      uint64_t function,
                                      const uint64_t *args,
                                      unsigned argument_count,
                                      uint64_t *result) {
    if (!process || process->task == MACH_PORT_NULL || !function || argument_count > 6 ||
        (argument_count && !args))
        return DECRYPT_INVALID_ARGUMENT;
    decrypt_status_t status = ensure_exception_port(process);
    if (status != DECRYPT_OK)
        return status;

    thread_act_array_t threads = NULL;
    mach_msg_type_number_t thread_count = 0;
    if (task_threads(process->task, &threads, &thread_count) != KERN_SUCCESS || thread_count == 0)
        return DECRYPT_PLATFORM_ERROR;
    thread_act_t thread = threads[0];
    for (mach_msg_type_number_t index = 1; index < thread_count; index++)
        mach_port_deallocate(mach_task_self(), threads[index]);
    vm_deallocate(mach_task_self(), (vm_address_t)threads,
                  thread_count * sizeof(thread_act_t));

    status = DECRYPT_PLATFORM_ERROR;
    arm_thread_state64_t saved;
    mach_msg_type_number_t state_count = ARM_THREAD_STATE64_COUNT;
    if (thread_suspend(thread) != KERN_SUCCESS)
        goto done;
    // thread_abort_safely only unwinds interruptible waits. A thread parked in an uninterruptible
    // one ignores thread_set_state entirely, so fall back to the unsafe abort rather than write a
    // state the kernel will discard.
    if (thread_abort_safely(thread) != KERN_SUCCESS)
        thread_abort(thread);
    if (thread_get_state(thread, ARM_THREAD_STATE64,
                         (thread_state_t)&saved, &state_count) != KERN_SUCCESS)
        goto resume_and_done;

    arm_thread_state64_t call = saved;
    call.__pc = function;
    call.__lr = DECRYPT_SENTINEL_LR;
    // Leave the existing frame well alone: drop below it and realign, so the callee cannot scribble
    // over whatever the thread was in the middle of.
    call.__sp = (saved.__sp - 0x1000) & ~UINT64_C(0xf);
    for (unsigned index = 0; index < argument_count; index++)
        call.__x[index] = args[index];
    if (thread_set_state(thread, ARM_THREAD_STATE64,
                         (thread_state_t)&call, state_count) != KERN_SUCCESS)
        goto resume_and_done;

    // Claim the fault at both levels. Thread ports win, but frameworks in the target install their
    // own per-thread handlers, and a task-level claim is what catches the call if one of those has
    // already taken the thread-level slot.
    const exception_mask_t mask = EXC_MASK_BAD_ACCESS | EXC_MASK_BAD_INSTRUCTION |
                                  EXC_MASK_CRASH | EXC_MASK_BREAKPOINT | EXC_MASK_GUARD;
    thread_set_exception_ports(thread, mask, process->exception_port,
                               EXCEPTION_DEFAULT | MACH_EXCEPTION_CODES, ARM_THREAD_STATE64);
    task_set_exception_ports(process->task, mask, process->exception_port,
                             EXCEPTION_DEFAULT | MACH_EXCEPTION_CODES, ARM_THREAD_STATE64);

    // The suspend count is not 1. SBS targets come out of xpcproxy already held, and every earlier
    // suspend of ours stacks on top, so resume until it refuses rather than once.
    for (int attempt = 0; attempt < 16 && thread_resume(thread) == KERN_SUCCESS; attempt++) {}
    for (int attempt = 0; attempt < 16 && task_resume(process->task) == KERN_SUCCESS; attempt++) {}
    if (process->pid > 0)
        pid_resume(process->pid);

    decrypt_exception_message_t message;
    memset(&message, 0, sizeof(message));
    mach_msg_return_t received = mach_msg(&message.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0,
                                          sizeof(message), process->exception_port,
                                          15000, MACH_PORT_NULL);
    task_suspend(process->task);
    thread_suspend(thread);

    decrypt_runtime_call_detail.received = received;
    decrypt_runtime_call_detail.pc = 0;
    if (received == MACH_MSG_SUCCESS) {
        arm_thread_state64_t finished;
        mach_msg_type_number_t finished_count = ARM_THREAD_STATE64_COUNT;
        if (thread_get_state(thread, ARM_THREAD_STATE64,
                             (thread_state_t)&finished, &finished_count) == KERN_SUCCESS) {
            decrypt_runtime_call_detail.pc = finished.__pc;
            // Anything other than the sentinel means the target faulted inside the callee, and x0
            // is then meaningless rather than a return value.
            if ((finished.__pc & UINT64_C(0xffffffff)) == DECRYPT_SENTINEL_LR) {
                if (result)
                    *result = finished.__x[0];
                status = DECRYPT_OK;
            }
        }
        // Put the thread back before releasing it, so KERN_SUCCESS resumes it on the original PC
        // rather than retrying the sentinel fault.
        thread_set_state(thread, ARM_THREAD_STATE64, (thread_state_t)&saved, state_count);

        // An unanswered exception leaves the thread blocked in the kernel forever. The first call
        // still works, because it hijacks a healthy thread; every call after it finds one parked in
        // the exception wait and fails. That is the whole reason this reply exists.
        struct {
            mach_msg_header_t header;
            NDR_record_t ndr;
            kern_return_t code;
        } reply;
        memset(&reply, 0, sizeof(reply));
        reply.header.msgh_bits = MACH_MSGH_BITS(MACH_MSGH_BITS_REMOTE(message.header.msgh_bits), 0);
        reply.header.msgh_size = sizeof(reply);
        reply.header.msgh_remote_port = message.header.msgh_remote_port;
        reply.header.msgh_local_port = MACH_PORT_NULL;
        reply.header.msgh_id = message.header.msgh_id + 100;
        reply.ndr = NDR_record;
        reply.code = KERN_SUCCESS;
        mach_msg(&reply.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof(reply), 0,
                 MACH_PORT_NULL, 1000, MACH_PORT_NULL);

        if (message.thread.name != MACH_PORT_NULL)
            mach_port_deallocate(mach_task_self(), message.thread.name);
        if (message.task.name != MACH_PORT_NULL)
            mach_port_deallocate(mach_task_self(), message.task.name);
    } else {
        thread_abort(thread);
        thread_set_state(thread, ARM_THREAD_STATE64, (thread_state_t)&saved, state_count);
    }

resume_and_done:
    thread_resume(thread);
done:
    mach_port_deallocate(mach_task_self(), thread);
    return status;
}

bool decrypt_target_read(task_t task, uint64_t address, void *into, size_t size) {
    decrypt_vm_size_t received = 0;
    return mach_vm_read_overwrite(task, address, size,
               (decrypt_vm_address_t)(uintptr_t)into, &received) == KERN_SUCCESS &&
           received == size;
}

static uint64_t read_uleb(const uint8_t *data, size_t size, size_t *cursor) {
    uint64_t value = 0;
    unsigned shift = 0;
    while (*cursor < size && shift < 64) {
        uint8_t byte = data[(*cursor)++];
        value |= (uint64_t)(byte & 0x7f) << shift;
        if ((byte & 0x80) == 0)
            return value;
        shift += 7;
    }
    *cursor = size + 1;   // force the caller's bounds check to fail
    return 0;
}

// Walks the export trie for one exact symbol. Iterative rather than recursive so a malformed trie
// cannot blow the stack, and every offset is bounds-checked against the blob we actually read.
static bool trie_find(const uint8_t *trie, size_t size, const char *symbol, uint64_t *offset) {
    size_t node = 0;
    const char *remaining = symbol;
    for (unsigned depth = 0; depth < 128; depth++) {
        if (node >= size)
            return false;
        size_t cursor = node;
        uint64_t terminal_size = read_uleb(trie, size, &cursor);
        if (cursor > size)
            return false;

        if (*remaining == '\0' && terminal_size) {
            size_t terminal = cursor;
            uint64_t flags = read_uleb(trie, size, &terminal);
            uint64_t value = read_uleb(trie, size, &terminal);
            if (terminal > size)
                return false;
            // Re-exports and interposed stubs do not carry a usable address here.
            if (flags & 0x08)
                return false;
            *offset = value;
            return true;
        }

        size_t children = cursor + (size_t)terminal_size;
        if (children >= size)
            return false;
        uint8_t child_count = trie[children++];
        bool descended = false;
        for (uint8_t index = 0; index < child_count && children < size; index++) {
            const char *label = (const char *)trie + children;
            size_t label_size = strnlen(label, size - children);
            if (children + label_size >= size)
                return false;
            children += label_size + 1;
            size_t after_label = children;
            uint64_t next = read_uleb(trie, size, &after_label);
            if (after_label > size)
                return false;
            children = after_label;
            if (!descended && strncmp(remaining, label, label_size) == 0) {
                remaining += label_size;
                node = (size_t)next;
                descended = true;
                // Keep scanning the remaining labels only to stay in sync; the loop above already
                // advanced `children` past each one.
            }
        }
        if (!descended)
            return false;
    }
    return false;
}

// Set by the selftest so a failed lookup can report what the trie actually held. Left NULL on the
// production path, where nobody is reading it.
static char *decrypt_runtime_export_sample = NULL;
static size_t decrypt_runtime_export_sample_size = 0;

void decrypt_remote_set_export_sample(char *buffer, size_t size) {
    decrypt_runtime_export_sample = buffer;
    decrypt_runtime_export_sample_size = buffer ? size : 0;
}

// Diagnostic only: names the first few exports so a lookup miss can be told apart from a trie we
// are parsing wrongly. An empty list means the parse is broken, not that the symbol is absent.
static void trie_sample(const uint8_t *trie, size_t size, char *out, size_t out_size) {
    struct { size_t node; unsigned prefix; } stack[64];
    char prefix[256];
    unsigned depth = 0, printed = 0;
    size_t used = 0;
    stack[depth].node = 0;
    stack[depth].prefix = 0;
    depth++;
    out[0] = '\0';

    while (depth && printed < 8) {
        depth--;
        size_t node = stack[depth].node;
        unsigned prefix_length = stack[depth].prefix;
        if (node >= size)
            continue;
        size_t cursor = node;
        uint64_t terminal_size = read_uleb(trie, size, &cursor);
        if (cursor > size)
            continue;
        if (terminal_size && prefix_length) {
            prefix[prefix_length] = '\0';
            int written = snprintf(out + used, out_size - used, "%s%s",
                                   used ? "," : "", prefix);
            if (written > 0 && used + (size_t)written < out_size)
                used += (size_t)written;
            printed++;
        }
        size_t children = cursor + (size_t)terminal_size;
        if (children >= size)
            continue;
        uint8_t child_count = trie[children++];
        for (uint8_t index = 0; index < child_count && children < size; index++) {
            const char *label = (const char *)trie + children;
            size_t label_size = strnlen(label, size - children);
            if (children + label_size >= size)
                break;
            children += label_size + 1;
            size_t after = children;
            uint64_t next = read_uleb(trie, size, &after);
            if (after > size)
                break;
            children = after;
            if (depth < 64 && prefix_length + label_size < sizeof(prefix) - 1) {
                memcpy(prefix + prefix_length, label, label_size);
                stack[depth].node = (size_t)next;
                stack[depth].prefix = (unsigned)(prefix_length + label_size);
                depth++;
            }
        }
    }
}

decrypt_status_t decrypt_runtime_lookup_export(decrypt_process_t *process,
                                               uint64_t image_base,
                                               const char *symbol,
                                               uint64_t *address) {
    if (!process || process->task == MACH_PORT_NULL || !image_base || !symbol || !address)
        return DECRYPT_INVALID_ARGUMENT;

    struct mach_header_64 header;
    if (!decrypt_target_read(process->task, image_base, &header, sizeof(header)) ||
        header.magic != MH_MAGIC_64 || header.sizeofcmds > (1u << 22))
        return DECRYPT_PLATFORM_ERROR;

    uint8_t *commands = malloc(header.sizeofcmds);
    if (!commands)
        return DECRYPT_IO_ERROR;
    if (!decrypt_target_read(process->task, image_base + sizeof(header), commands, header.sizeofcmds)) {
        free(commands);
        return DECRYPT_PLATFORM_ERROR;
    }

    uint64_t text_vmaddr = 0, linkedit_vmaddr = 0, linkedit_fileoff = 0;
    uint32_t export_off = 0, export_size = 0;
    bool have_text = false, have_linkedit = false;
    uint32_t cursor = 0;
    for (uint32_t index = 0; index < header.ncmds; index++) {
        if (cursor + sizeof(struct load_command) > header.sizeofcmds)
            break;
        struct load_command command;
        memcpy(&command, commands + cursor, sizeof(command));
        if (command.cmdsize < sizeof(command) || cursor + command.cmdsize > header.sizeofcmds)
            break;

        if (command.cmd == LC_SEGMENT_64 && command.cmdsize >= sizeof(struct segment_command_64)) {
            struct segment_command_64 segment;
            memcpy(&segment, commands + cursor, sizeof(segment));
            if (strcmp(segment.segname, "__TEXT") == 0) {
                text_vmaddr = segment.vmaddr;
                have_text = true;
            } else if (strcmp(segment.segname, "__LINKEDIT") == 0) {
                linkedit_vmaddr = segment.vmaddr;
                linkedit_fileoff = segment.fileoff;
                have_linkedit = true;
            }
        } else if ((command.cmd == LC_DYLD_INFO || command.cmd == LC_DYLD_INFO_ONLY) &&
                   command.cmdsize >= sizeof(struct dyld_info_command)) {
            struct dyld_info_command info;
            memcpy(&info, commands + cursor, sizeof(info));
            export_off = info.export_off;
            export_size = info.export_size;
        } else if (command.cmd == LC_DYLD_EXPORTS_TRIE &&
                   command.cmdsize >= sizeof(struct linkedit_data_command)) {
            struct linkedit_data_command data;
            memcpy(&data, commands + cursor, sizeof(data));
            export_off = data.dataoff;
            export_size = data.datasize;
        }
        cursor += command.cmdsize;
    }
    free(commands);

    if (!have_text || !have_linkedit || export_size == 0 || export_size > (1u << 24))
        return DECRYPT_UNSUPPORTED_FORMAT;

    // The trie is addressed by file offset; map it through __LINKEDIT to where it actually sits in
    // this process's address space, slide included.
    uint64_t slide = image_base - text_vmaddr;
    uint64_t trie_address = slide + linkedit_vmaddr + (export_off - linkedit_fileoff);

    uint8_t *trie = malloc(export_size);
    if (!trie)
        return DECRYPT_IO_ERROR;
    if (!decrypt_target_read(process->task, trie_address, trie, export_size)) {
        free(trie);
        return DECRYPT_PLATFORM_ERROR;
    }

    uint64_t found = 0;
    bool ok = trie_find(trie, export_size, symbol, &found);
    if (!ok && decrypt_runtime_export_sample) {
        trie_sample(trie, export_size, decrypt_runtime_export_sample,
                    decrypt_runtime_export_sample_size);
    }
    free(trie);
    if (!ok)
        return DECRYPT_ARCH_NOT_FOUND;
    *address = image_base + found;
    return DECRYPT_OK;
}

decrypt_status_t decrypt_runtime_resolve_loader(decrypt_process_t *process,
                                                const char *symbol,
                                                uint64_t *address,
                                                char *where,
                                                size_t where_size) {
    // Ordered by where the entry points have actually lived across releases, dyld last because on
    // iOS 16 it vends only debugger hooks.
    static const char *images[] = {
        "/usr/lib/system/libdyld.dylib",
        "/usr/lib/libdyld.dylib",
        "/usr/lib/libSystem.B.dylib",
    };
    for (size_t index = 0; index < sizeof(images) / sizeof(images[0]); index++) {
        uint64_t base = 0;
        if (decrypt_runtime_find_image(process, images[index], &base) != DECRYPT_OK)
            continue;
        if (decrypt_runtime_lookup_export(process, base, symbol, address) != DECRYPT_OK)
            continue;
        if (where)
            snprintf(where, where_size, "%s", images[index]);
        return DECRYPT_OK;
    }
    uint64_t dyld = 0;
    if (decrypt_runtime_dyld_base(process, &dyld) == DECRYPT_OK &&
        decrypt_runtime_lookup_export(process, dyld, symbol, address) == DECRYPT_OK) {
        if (where)
            snprintf(where, where_size, "dyld");
        return DECRYPT_OK;
    }
    return DECRYPT_ARCH_NOT_FOUND;
}

decrypt_status_t decrypt_runtime_write_string(decrypt_process_t *process,
                                              const char *value,
                                              uint64_t *address,
                                              uint64_t *size) {
    if (!process || process->task == MACH_PORT_NULL || !value || !address || !size)
        return DECRYPT_INVALID_ARGUMENT;
    // Data only, never executable, so no code-signing question arises.
    decrypt_vm_size_t length = strlen(value) + 1;
    decrypt_vm_address_t allocated = 0;
    if (mach_vm_allocate(process->task, &allocated, length, VM_FLAGS_ANYWHERE) != KERN_SUCCESS)
        return DECRYPT_PLATFORM_ERROR;
    if (mach_vm_write(process->task, allocated, (vm_offset_t)(uintptr_t)value,
                      (mach_msg_type_number_t)length) != KERN_SUCCESS) {
        mach_vm_deallocate(process->task, allocated, length);
        return DECRYPT_PLATFORM_ERROR;
    }
    *address = allocated;
    *size = length;
    return DECRYPT_OK;
}

void decrypt_runtime_free_target(decrypt_process_t *process, uint64_t address, uint64_t size) {
    if (process && process->task != MACH_PORT_NULL && address)
        mach_vm_deallocate(process->task, address, size);
}
