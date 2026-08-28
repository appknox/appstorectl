// runtime.c — getting plaintext images out of a running target.
//
// This is the acquisition layer: what dyld has mapped, when it has finished mapping it, which of
// those images belong to the bundle, and reading each one back out. Where an image has to be
// forced into the target first, the mechanics of doing that live in remote.c.
#include "internal.h"

#include <dirent.h>
#include <errno.h>
#include <signal.h>
#include <limits.h>
#include <mach-o/dyld_images.h>
#include <mach-o/loader.h>
#include <mach/vm_region.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>



static bool read_target_path(task_t task, decrypt_vm_address_t address,
                             char *path, size_t capacity);

static uint32_t loaded_image_count(task_t task) {
    struct task_dyld_info info;
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
    if (task_info(task, TASK_DYLD_INFO, (task_info_t)&info, &count) != KERN_SUCCESS)
        return 0;
    struct dyld_all_image_infos all;
    if (!decrypt_target_read(task, info.all_image_info_addr, &all, sizeof(all)))
        return 0;
    return all.infoArrayCount;
}

uint32_t decrypt_runtime_image_count(task_t task) {
    return loaded_image_count(task);
}

uint32_t decrypt_runtime_wait_for_images(task_t task, pid_t pid) {
    // Suspending the instant the pid appears freezes the target mid-bootstrap: dyld has not
    // finished mapping dependencies, and calling into it then faults inside a half-initialised
    // libdyld. Wait for the image count to stop moving instead of guessing a fixed delay.
    uint32_t last = 0;
    unsigned stable = 0;
    unsigned blank = 0;
    for (unsigned attempt = 0; attempt < 80; attempt++) {
        uint32_t current = loaded_image_count(task);
        // Zero means the enumeration failed, not that the target settled with nothing loaded.
        // Counting it as stable is how you suspend early and lose every framework.
        if (current != 0 && current == last) {
            if (++stable >= 4)
                return current;
        } else {
            stable = 0;
        }
        // A target that never reports an image is not slow, it is gone or unreadable. Waiting the
        // full ceiling on it costs 20s and still ends in a dead task port, so stop early and let
        // the caller fall back while the failure is still cheap.
        blank = current == 0 ? blank + 1 : 0;
        if (blank >= 8 || (pid > 0 && kill(pid, 0) != 0 && errno == ESRCH))
            return 0;
        last = current;
        usleep(250000);
    }
    return last;
}

// dyld itself exports almost nothing on iOS 16 (only the lldb notification hooks), so the loader
// entry points have to be found in whichever cache image actually vends them.
decrypt_status_t decrypt_runtime_find_image(decrypt_process_t *process,
                                            const char *path_suffix,
                                            uint64_t *base) {
    if (!process || process->task == MACH_PORT_NULL || !path_suffix || !base)
        return DECRYPT_INVALID_ARGUMENT;
    struct task_dyld_info info;
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
    if (task_info(process->task, TASK_DYLD_INFO, (task_info_t)&info, &count) != KERN_SUCCESS)
        return DECRYPT_PLATFORM_ERROR;
    struct dyld_all_image_infos all;
    if (!decrypt_target_read(process->task, info.all_image_info_addr, &all, sizeof(all)) ||
        all.infoArrayCount == 0 || all.infoArrayCount > 8192 || !all.infoArray)
        return DECRYPT_PLATFORM_ERROR;

    size_t images_size = (size_t)all.infoArrayCount * sizeof(struct dyld_image_info);
    struct dyld_image_info *images = malloc(images_size);
    if (!images)
        return DECRYPT_IO_ERROR;
    if (!decrypt_target_read(process->task, (uint64_t)(uintptr_t)all.infoArray, images, images_size)) {
        free(images);
        return DECRYPT_PLATFORM_ERROR;
    }

    size_t suffix_size = strlen(path_suffix);
    decrypt_status_t status = DECRYPT_ARCH_NOT_FOUND;
    for (uint32_t index = 0; index < all.infoArrayCount; index++) {
        char path[PATH_MAX];
        if (!images[index].imageFilePath ||
            !read_target_path(process->task,
                (decrypt_vm_address_t)(uintptr_t)images[index].imageFilePath,
                path, sizeof(path)))
            continue;
        size_t path_size = strlen(path);
        if (path_size < suffix_size ||
            strcmp(path + path_size - suffix_size, path_suffix) != 0)
            continue;
        *base = (uint64_t)(uintptr_t)images[index].imageLoadAddress;
        status = DECRYPT_OK;
        break;
    }
    free(images);
    return status;
}


// ----- images dyld never loaded -------------------------------------------------------------

static decrypt_status_t dump_image_at(decrypt_process_t *process,
                                      decrypt_vm_address_t image_base,
                                      const char *source_path,
                                      const char *destination_path,
                                      const char *display_name,
                                      const char *kind,
                                      decrypt_logger_t *logger);

typedef struct {
    char relative[PATH_MAX];
} decrypt_candidate_t;

typedef struct {
    decrypt_candidate_t *items;
    size_t count;
    size_t capacity;
} decrypt_candidate_list_t;

static bool candidates_add(decrypt_candidate_list_t *list, const char *relative) {
    if (list->count == list->capacity) {
        size_t capacity = list->capacity ? list->capacity * 2 : 16;
        if (capacity > 4096)
            return false;
        decrypt_candidate_t *grown = realloc(list->items, capacity * sizeof(*grown));
        if (!grown)
            return false;
        list->items = grown;
        list->capacity = capacity;
    }
    if (strlen(relative) >= PATH_MAX)
        return false;
    snprintf(list->items[list->count].relative, PATH_MAX, "%s", relative);
    list->count++;
    return true;
}

static bool has_extension(const char *name, const char *extension) {
    size_t name_size = strlen(name);
    size_t extension_size = strlen(extension);
    return name_size > extension_size &&
           strcmp(name + name_size - extension_size, extension) == 0;
}

// Collects every encrypted Mach-O under the bundle except the main executable, not descending into
// nested .appex roots because those are separate targets with their own launch.
static void collect_images(const char *bundle_root,
                           const char *directory,
                           const char *prefix,
                           const char *main_name,
                           bool encrypted_only,
                           decrypt_candidate_list_t *list) {
    DIR *handle = opendir(directory);
    if (!handle)
        return;
    struct dirent *entry;
    while ((entry = readdir(handle))) {
        if (entry->d_name[0] == '.')
            continue;
        char child[PATH_MAX];
        char relative[PATH_MAX];
        if (snprintf(child, sizeof(child), "%s/%s", directory, entry->d_name) >=
                (int)sizeof(child) ||
            snprintf(relative, sizeof(relative), "%s%s%s", prefix, *prefix ? "/" : "",
                     entry->d_name) >= (int)sizeof(relative))
            continue;

        struct stat st;
        if (stat(child, &st) != 0)
            continue;
        if (S_ISDIR(st.st_mode)) {
            if (has_extension(entry->d_name, ".appex") || has_extension(entry->d_name, ".app"))
                continue;
            collect_images(bundle_root, child, relative, main_name, encrypted_only, list);
            continue;
        }
        if (!S_ISREG(st.st_mode) || strcmp(relative, main_name) == 0)
            continue;

        decrypt_macho_image_t image;
        decrypt_status_t inspected = decrypt_macho_inspect_file_any(child, &image);
        if (encrypted_only) {
            if (inspected != DECRYPT_OK || image.cryptid == 0)
                continue;
        } else if (inspected != DECRYPT_OK && inspected != DECRYPT_NO_ENCRYPTION_INFO) {
            continue;
        }
        candidates_add(list, relative);
    }
    closedir(handle);
}

static bool destination_is_plain(const char *destination_bundle, const char *relative) {
    char path[PATH_MAX];
    if (snprintf(path, sizeof(path), "%s/%s", destination_bundle, relative) >= (int)sizeof(path))
        return false;
    decrypt_macho_image_t image;
    decrypt_status_t status = decrypt_macho_inspect_file_any(path, &image);
    return status == DECRYPT_OK && image.cryptid == 0;
}

int decrypt_runtime_dump_missing_bundle_images(decrypt_process_t *process,
                                               const char *source_bundle,
                                               const char *destination_bundle,
                                               const char *main_name,
                                               decrypt_logger_t *logger) {
    if (!process || process->task == MACH_PORT_NULL || !source_bundle || !destination_bundle)
        return 0;
    if (!process->loader_ready) {
        // Silent until now, and it is the whole explanation for a bundle whose frameworks were
        // never touched: without a loader that has actually mapped something, there is nothing to
        // enumerate and nothing that can be asked to load more.
        decrypt_event_attrs_t skipped;
        decrypt_attrs_init(&skipped);
        decrypt_attrs_string(&skipped, "reason", "loader_not_ready");
        decrypt_event(logger, DECRYPT_LOG_WARNING, "inventory.skipped", &skipped,
                      "dyld never mapped anything in this target, so no framework pass runs for %s",
                      source_bundle);
        return 0;
    }

    decrypt_candidate_list_t list = {0};
    collect_images(source_bundle, source_bundle, "", main_name, true, &list);
    size_t found = list.count;

    // Anything the natural load already handled is done; only what is still encrypted in the
    // staged copy needs forcing.
    size_t pending = 0;
    for (size_t index = 0; index < list.count; index++) {
        if (destination_is_plain(destination_bundle, list.items[index].relative))
            continue;
        list.items[pending++] = list.items[index];
    }
    list.count = pending;

    // Always reported, including the nothing-to-do case, so a bundle whose images were all reached
    // is distinguishable from one where this pass never ran. Raised to info when there is real work,
    // because that is the case someone will want to find later.
    decrypt_event_attrs_t attrs;
    decrypt_attrs_init(&attrs);
    decrypt_attrs_int(&attrs, "encrypted", (int64_t)found);
    decrypt_attrs_int(&attrs, "pending", (int64_t)list.count);
    decrypt_event(logger, list.count ? DECRYPT_LOG_INFO : DECRYPT_LOG_DEBUG, "inventory", &attrs,
                  "%zu encrypted image(s) in bundle, %zu not reached by the natural load",
                  found, list.count);
    if (list.count == 0) {
        free(list.items);
        return 0;
    }

    uint64_t dlopen_address = 0;
    char where[128] = {0};
    decrypt_status_t status = decrypt_runtime_resolve_loader(process, "_dlopen",
                                                             &dlopen_address, where, sizeof(where));
    if (status != DECRYPT_OK) {
        decrypt_attrs_init(&attrs);
        decrypt_attrs_string(&attrs, "reason", decrypt_status_name(status));
        decrypt_event(logger, DECRYPT_LOG_WARNING, "inventory.blocked", &attrs,
                      "cannot resolve dlopen in the target, %zu image(s) left encrypted",
                      list.count);
        free(list.items);
        return 0;
    }

    int dumped = 0;
    // Passes rather than one sweep: loading one image can pull its dependencies in with it, so a
    // later candidate may already be mapped by the time we reach it.
    for (unsigned pass = 0; pass < 3 && list.count; pass++) {
        size_t remaining = 0;
        for (size_t index = 0; index < list.count; index++) {
            const char *relative = list.items[index].relative;
            char source_path[PATH_MAX];
            char destination_path[PATH_MAX];
            if (snprintf(source_path, sizeof(source_path), "%s/%s", source_bundle, relative) >=
                    (int)sizeof(source_path) ||
                snprintf(destination_path, sizeof(destination_path), "%s/%s",
                         destination_bundle, relative) >= (int)sizeof(destination_path))
                continue;

            uint64_t base = 0;
            if (decrypt_runtime_find_image(process, relative, &base) != DECRYPT_OK) {
                uint64_t path_address = 0, path_size = 0;
                if (decrypt_runtime_write_string(process, source_path,
                                                 &path_address, &path_size) != DECRYPT_OK) {
                    list.items[remaining++] = list.items[index];
                    continue;
                }
                // RTLD_LAZY: mapping the image is all that is needed, since the plaintext arrives
                // on page fault. Binding eagerly would run more of the image's own code for no gain.
                uint64_t args[2] = {path_address, 0x1};
                uint64_t handle = 0;
                decrypt_status_t called = decrypt_runtime_call(process, dlopen_address, args, 2,
                                                               &handle);
                decrypt_runtime_free_target(process, path_address, path_size);
                if (called != DECRYPT_OK || handle == 0 ||
                    decrypt_runtime_find_image(process, relative, &base) != DECRYPT_OK) {
                    decrypt_attrs_init(&attrs);
                    decrypt_attrs_string(&attrs, "name", relative);
                    decrypt_attrs_string(&attrs, "reason",
                                         called == DECRYPT_OK ? "dlopen_returned_null"
                                                              : decrypt_status_name(called));
                    decrypt_event(logger, DECRYPT_LOG_DEBUG, "image.load_failed", &attrs,
                                  "could not load %s into the target", relative);
                    list.items[remaining++] = list.items[index];
                    continue;
                }
                decrypt_attrs_init(&attrs);
                decrypt_attrs_string(&attrs, "name", relative);
                decrypt_attrs_hex(&attrs, "base", base);
                decrypt_event(logger, DECRYPT_LOG_INFO, "image.loaded", &attrs,
                              "loaded %s at 0x%llx", relative, (unsigned long long)base);
            }

            decrypt_status_t dump = dump_image_at(process, base, source_path, destination_path,
                                                  relative, "forced", logger);
            if (dump == DECRYPT_OK) {
                dumped++;
            } else if (dump != DECRYPT_ALREADY_PLAIN && dump != DECRYPT_NO_ENCRYPTION_INFO) {
                decrypt_attrs_init(&attrs);
                decrypt_attrs_string(&attrs, "name", relative);
                decrypt_attrs_string(&attrs, "reason", decrypt_status_name(dump));
                decrypt_event(logger, DECRYPT_LOG_WARNING, "image.failed", &attrs,
                              "failed to dump %s (%s)", relative, decrypt_status_name(dump));
            }
        }
        if (remaining == list.count)
            break;      // a pass that loaded nothing new will not do better next time
        list.count = remaining;
    }

    free(list.items);
    return dumped;
}

decrypt_status_t decrypt_runtime_selftest(decrypt_process_t *process,
                                          const char *source_bundle,
                                          decrypt_logger_t *logger) {
    uint64_t dyld_base = 0;
    decrypt_status_t status = decrypt_runtime_dyld_base(process, &dyld_base);
    if (status != DECRYPT_OK)
        return status;

    char sample[512] = {0};
    char where[128] = {0};
    decrypt_remote_set_export_sample(sample, sizeof(sample));
    uint64_t dlopen_address = 0;
    status = decrypt_runtime_resolve_loader(process, "_dlopen", &dlopen_address,
                                            where, sizeof(where));
    decrypt_remote_set_export_sample(NULL, 0);

    decrypt_event_attrs_t attrs;
    decrypt_attrs_init(&attrs);
    decrypt_attrs_hex(&attrs, "dyld", dyld_base);
    decrypt_attrs_hex(&attrs, "dlopen", dlopen_address);
    if (status == DECRYPT_OK)
        decrypt_attrs_string(&attrs, "from", where);
    else
        decrypt_attrs_string(&attrs, "sample", sample[0] ? sample : "(trie parsed to nothing)");
    decrypt_event(logger, DECRYPT_LOG_INFO, "selftest.resolve", &attrs,
                  "dyld at 0x%llx, _dlopen %s",
                  (unsigned long long)dyld_base,
                  status == DECRYPT_OK ? where : decrypt_status_name(status));
    if (status != DECRYPT_OK)
        return status;

    // RTLD_NOLOAD means this only ever reports whether libSystem is already mapped. It loads
    // nothing and changes nothing, which is the point: it exercises the call path without letting
    // a broken primitive alter the target.
    const char *path = "/usr/lib/libSystem.B.dylib";
    uint64_t path_address = 0, path_size = 0;
    status = decrypt_runtime_write_string(process, path, &path_address, &path_size);
    if (status != DECRYPT_OK)
        return status;

    uint64_t args[2] = {path_address, 0x2 | 0x10};   // RTLD_NOW | RTLD_NOLOAD
    uint64_t handle = 0;
    status = decrypt_runtime_call(process, dlopen_address, args, 2, &handle);
    decrypt_runtime_free_target(process, path_address, path_size);

    decrypt_attrs_init(&attrs);
    decrypt_attrs_string(&attrs, "call", "dlopen(RTLD_NOLOAD)");
    decrypt_attrs_hex(&attrs, "handle", handle);
    decrypt_attrs_string(&attrs, "status", decrypt_status_name(status));
    mach_msg_return_t received = 0;
    uint64_t stopped_pc = 0;
    decrypt_remote_last_call(&received, &stopped_pc);
    decrypt_attrs_hex(&attrs, "mach_msg", (uint64_t)received);
    decrypt_attrs_hex(&attrs, "stopped_pc", stopped_pc);
    bool passed = status == DECRYPT_OK && handle != 0;
    decrypt_event(logger, passed ? DECRYPT_LOG_INFO : DECRYPT_LOG_ERROR, "selftest.call", &attrs,
                  passed ? "remote call returned handle 0x%llx"
                         : "remote call did not produce a handle (0x%llx)",
                  (unsigned long long)handle);
    if (status != DECRYPT_OK)
        return status;
    if (!handle)
        return DECRYPT_PLATFORM_ERROR;
    if (!source_bundle)
        return DECRYPT_OK;

    // Second half: the case the production pass exists for. Find a bundle image dyld did not load
    // on its own, force it in, and confirm it becomes locatable. Without this the only thing proven
    // is that dlopen works on an image that was already mapped.
    decrypt_candidate_list_t list = {0};
    collect_images(source_bundle, source_bundle, "", "", false, &list);
    for (size_t index = 0; index < list.count; index++) {
        const char *relative = list.items[index].relative;
        uint64_t base = 0;
        if (decrypt_runtime_find_image(process, relative, &base) == DECRYPT_OK)
            continue;   // already mapped, proves nothing

        char full[PATH_MAX];
        if (snprintf(full, sizeof(full), "%s/%s", source_bundle, relative) >= (int)sizeof(full))
            continue;
        uint64_t path_address = 0, path_size = 0;
        if (decrypt_runtime_write_string(process, full, &path_address, &path_size) != DECRYPT_OK)
            continue;
        uint64_t load_args[2] = {path_address, 0x1};   // RTLD_LAZY
        uint64_t loaded = 0;
        decrypt_status_t called = decrypt_runtime_call(process, dlopen_address, load_args, 2,
                                                       &loaded);
        decrypt_runtime_free_target(process, path_address, path_size);
        bool locatable = called == DECRYPT_OK && loaded != 0 &&
                         decrypt_runtime_find_image(process, relative, &base) == DECRYPT_OK;

        decrypt_attrs_init(&attrs);
        decrypt_attrs_string(&attrs, "name", relative);
        decrypt_attrs_hex(&attrs, "handle", loaded);
        decrypt_attrs_hex(&attrs, "base", base);
        decrypt_attrs_string(&attrs, "status", decrypt_status_name(called));
        decrypt_event(logger, locatable ? DECRYPT_LOG_INFO : DECRYPT_LOG_ERROR,
                      "selftest.load", &attrs,
                      locatable ? "forced %s into the target at 0x%llx"
                                : "could not force %s into the target",
                      relative, (unsigned long long)base);
        free(list.items);
        return locatable ? DECRYPT_OK : DECRYPT_PLATFORM_ERROR;
    }

    decrypt_attrs_init(&attrs);
    decrypt_attrs_int(&attrs, "candidates", (int64_t)list.count);
    decrypt_event(logger, DECRYPT_LOG_WARNING, "selftest.load", &attrs,
                  "every bundle image was already mapped; the forced-load path was not exercised");
    free(list.items);
    return DECRYPT_OK;
}

decrypt_status_t decrypt_runtime_dyld_base(decrypt_process_t *process, uint64_t *base) {
    if (!process || process->task == MACH_PORT_NULL || !base)
        return DECRYPT_INVALID_ARGUMENT;
    struct task_dyld_info info;
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
    if (task_info(process->task, TASK_DYLD_INFO, (task_info_t)&info, &count) != KERN_SUCCESS)
        return DECRYPT_PLATFORM_ERROR;
    struct dyld_all_image_infos all;
    if (!decrypt_target_read(process->task, info.all_image_info_addr, &all, sizeof(all)) ||
        !all.dyldImageLoadAddress)
        return DECRYPT_PLATFORM_ERROR;
    *base = (uint64_t)(uintptr_t)all.dyldImageLoadAddress;
    return DECRYPT_OK;
}

static decrypt_status_t find_main_image(task_t task,
                                        decrypt_vm_address_t *base_out,
                                        int32_t *cpu_type_out,
                                        int32_t *cpu_subtype_out) {
    decrypt_vm_address_t address = 0;
    while (address < UINT64_MAX) {
        decrypt_vm_size_t size = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object = MACH_PORT_NULL;
        kern_return_t result = mach_vm_region(task, &address, &size,
            VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object);
        if (object != MACH_PORT_NULL)
            mach_port_deallocate(mach_task_self(), object);
        if (result != KERN_SUCCESS)
            break;

        if ((info.protection & VM_PROT_READ) && size >= sizeof(struct mach_header_64)) {
            struct mach_header_64 header;
            decrypt_vm_size_t received = 0;
            if (mach_vm_read_overwrite(task, address, sizeof(header),
                    (decrypt_vm_address_t)(uintptr_t)&header, &received) == KERN_SUCCESS &&
                received == sizeof(header) && header.magic == MH_MAGIC_64 &&
                header.filetype == MH_EXECUTE) {
                *base_out = address;
                *cpu_type_out = header.cputype;
                *cpu_subtype_out = header.cpusubtype;
                return DECRYPT_OK;
            }
        }

        if (size == 0 || address > UINT64_MAX - size)
            break;
        address += size;
    }
    return DECRYPT_PLATFORM_ERROR;
}

static decrypt_status_t dump_image_at(decrypt_process_t *process,
                                      decrypt_vm_address_t image_base,
                                      const char *source_path,
                                      const char *destination_path,
                                      const char *display_name,
                                      const char *kind,
                                      decrypt_logger_t *logger) {
    struct mach_header_64 header;
    decrypt_vm_size_t header_size = 0;
    if (mach_vm_read_overwrite(process->task, image_base, sizeof(header),
            (decrypt_vm_address_t)(uintptr_t)&header, &header_size) != KERN_SUCCESS ||
        header_size != sizeof(header) || header.magic != MH_MAGIC_64)
        return DECRYPT_PLATFORM_ERROR;

    decrypt_macho_image_t image;
    decrypt_status_t status = decrypt_macho_inspect_file(
        source_path, header.cputype, header.cpusubtype, &image);
    if (status != DECRYPT_OK)
        return status;
    if (image.cryptid == 0)
        return DECRYPT_ALREADY_PLAIN;
    if (image.encrypted_size == 0 || image.encrypted_size > SIZE_MAX ||
        image_base > UINT64_MAX - image.runtime_offset)
        return DECRYPT_MALFORMED_INPUT;

    size_t plaintext_size = (size_t)image.encrypted_size;
    uint8_t *plaintext = malloc(plaintext_size);
    if (!plaintext)
        return DECRYPT_IO_ERROR;

    decrypt_vm_size_t received = 0;
    kern_return_t result = mach_vm_read_overwrite(
        process->task, image_base + image.runtime_offset, image.encrypted_size,
        (decrypt_vm_address_t)(uintptr_t)plaintext, &received);
    if (result != KERN_SUCCESS || received != image.encrypted_size) {
        free(plaintext);
        return DECRYPT_PLATFORM_ERROR;
    }

    status = decrypt_output_replace_image(source_path, destination_path, &image,
                                          plaintext, plaintext_size);
    free(plaintext);
    if (status != DECRYPT_OK)
        return status;

    decrypt_event_attrs_t attrs;
    decrypt_attrs_init(&attrs);
    decrypt_attrs_string(&attrs, "name", display_name);
    decrypt_attrs_string(&attrs, "kind", kind);
    decrypt_attrs_string(&attrs, "source", "vm_read");
    decrypt_attrs_uint(&attrs, "size", image.encrypted_size);
    decrypt_event(logger, DECRYPT_LOG_INFO, "image.done", &attrs,
                  "decrypted %s %s (%llu bytes)", kind, display_name,
                  (unsigned long long)image.encrypted_size);
    return DECRYPT_OK;
}

decrypt_status_t decrypt_runtime_dump_main(decrypt_process_t *process,
                                           const char *source_path,
                                           const char *destination_path,
                                           const char *display_name,
                                           decrypt_logger_t *logger) {
    if (!process || process->task == MACH_PORT_NULL || !source_path ||
        !destination_path || !display_name)
        return DECRYPT_INVALID_ARGUMENT;

    decrypt_vm_address_t image_base = 0;
    int32_t cpu_type = 0;
    int32_t cpu_subtype = 0;
    decrypt_status_t status = find_main_image(process->task, &image_base,
                                              &cpu_type, &cpu_subtype);
    if (status != DECRYPT_OK)
        return status;

    (void)cpu_type;
    (void)cpu_subtype;
    return dump_image_at(process, image_base, source_path, destination_path,
                         display_name, "main", logger);
}

static bool read_target_path(task_t task, decrypt_vm_address_t address,
                             char *path, size_t capacity) {
    size_t offset = 0;
    while (offset + 1 < capacity) {
        decrypt_vm_size_t wanted = capacity - 1 - offset;
        if (wanted > 256)
            wanted = 256;
        decrypt_vm_size_t received = 0;
        if (mach_vm_read_overwrite(task, address + offset, wanted,
                (decrypt_vm_address_t)(uintptr_t)(path + offset), &received) != KERN_SUCCESS ||
            received == 0)
            return false;
        void *end = memchr(path + offset, '\0', (size_t)received);
        if (end)
            return true;
        offset += (size_t)received;
    }
    path[capacity - 1] = '\0';
    return false;
}

static const char *bundle_relative_path(const char *image_path,
                                        const char *bundle_path) {
    size_t bundle_size = strlen(bundle_path);
    if (strncmp(image_path, bundle_path, bundle_size) == 0 &&
        (image_path[bundle_size] == '/' || image_path[bundle_size] == '\0'))
        return image_path + bundle_size + (image_path[bundle_size] == '/');
    if (strncmp(image_path, "/private", 8) == 0 &&
        strncmp(image_path + 8, bundle_path, bundle_size) == 0 &&
        (image_path[8 + bundle_size] == '/' || image_path[8 + bundle_size] == '\0'))
        return image_path + 8 + bundle_size + (image_path[8 + bundle_size] == '/');
    return NULL;
}

int decrypt_runtime_dump_loaded_bundle_images(decrypt_process_t *process,
                                              const char *source_bundle,
                                              const char *destination_bundle,
                                              const char *main_name,
                                              decrypt_logger_t *logger) {
    if (!process || process->task == MACH_PORT_NULL)
        return 0;
    if (!process->loader_ready)
        return 0;   // reported once by the inventory pass; no need to say it twice per bundle

    struct task_dyld_info task_info_data;
    mach_msg_type_number_t task_info_count = TASK_DYLD_INFO_COUNT;
    kern_return_t info_result = task_info(process->task, TASK_DYLD_INFO,
                                          (task_info_t)&task_info_data, &task_info_count);
    if (info_result != KERN_SUCCESS) {
        decrypt_event_attrs_t failed;
        decrypt_attrs_init(&failed);
        decrypt_attrs_int(&failed, "kr", info_result);
        decrypt_event(logger, DECRYPT_LOG_WARNING, "enumerate.failed", &failed,
                      "TASK_DYLD_INFO unavailable, no image list to enumerate");
        return 0;
    }

    struct dyld_all_image_infos all_images;
    decrypt_vm_size_t received = 0;
    if (mach_vm_read_overwrite(process->task, task_info_data.all_image_info_addr,
            sizeof(all_images), (decrypt_vm_address_t)(uintptr_t)&all_images,
            &received) != KERN_SUCCESS || received != sizeof(all_images) ||
        all_images.infoArrayCount == 0 || all_images.infoArrayCount > 4096 ||
        !all_images.infoArray)
        return 0;

    size_t images_size = (size_t)all_images.infoArrayCount *
                         sizeof(struct dyld_image_info);
    struct dyld_image_info *images = malloc(images_size);
    if (!images)
        return 0;
    received = 0;
    if (mach_vm_read_overwrite(process->task,
            (decrypt_vm_address_t)(uintptr_t)all_images.infoArray, images_size,
            (decrypt_vm_address_t)(uintptr_t)images, &received) != KERN_SUCCESS ||
        received != images_size) {
        free(images);
        return 0;
    }

    int dumped = 0;
    int matched = 0;
    for (uint32_t index = 0; index < all_images.infoArrayCount; index++) {
        char image_path[PATH_MAX];
        if (!images[index].imageFilePath ||
            !read_target_path(process->task,
                (decrypt_vm_address_t)(uintptr_t)images[index].imageFilePath,
                image_path, sizeof(image_path)))
            continue;
        const char *relative = bundle_relative_path(image_path, source_bundle);
        if (!relative || !*relative || strcmp(relative, main_name) == 0)
            continue;
        matched++;

        char destination_path[PATH_MAX];
        if (snprintf(destination_path, sizeof(destination_path), "%s/%s",
                destination_bundle, relative) >= (int)sizeof(destination_path))
            continue;
        struct stat st;
        if (stat(image_path, &st) != 0 || !S_ISREG(st.st_mode))
            continue;

        decrypt_status_t status = dump_image_at(process,
            (decrypt_vm_address_t)(uintptr_t)images[index].imageLoadAddress,
            image_path, destination_path, relative, "framework", logger);
        if (status == DECRYPT_OK) {
            dumped++;
        } else if (status != DECRYPT_ALREADY_PLAIN &&
                   status != DECRYPT_NO_ENCRYPTION_INFO) {
            decrypt_event_attrs_t attrs;
            decrypt_attrs_init(&attrs);
            decrypt_attrs_string(&attrs, "name", relative);
            decrypt_attrs_string(&attrs, "reason", decrypt_status_name(status));
            decrypt_event(logger, DECRYPT_LOG_WARNING, "image.failed", &attrs,
                          "failed to dump %s (%s)", relative,
                          decrypt_status_name(status));
        }
    }
    free(images);

    decrypt_event_attrs_t attrs;
    decrypt_attrs_init(&attrs);
    decrypt_attrs_int(&attrs, "img_count", all_images.infoArrayCount);
    decrypt_attrs_int(&attrs, "bundle_matched", matched);
    decrypt_attrs_int(&attrs, "dumped", dumped);
    decrypt_event(logger, DECRYPT_LOG_DEBUG, "enumerate", &attrs,
                  "%u image(s) loaded, %d in this bundle",
                  all_images.infoArrayCount, matched);
    return dumped;
}
