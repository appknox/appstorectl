#ifndef APPSTORECTL_DECRYPT_INTERNAL_H
#define APPSTORECTL_DECRYPT_INTERNAL_H

#include "decrypt.h"

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <mach/mach.h>
#include <sys/types.h>

typedef struct {
    uint64_t slice_offset;
    uint64_t slice_size;
    uint64_t runtime_offset;
    uint64_t encrypted_offset;
    uint64_t encrypted_size;
    uint64_t cryptid_offset;
    int32_t cpu_type;
    int32_t cpu_subtype;
    uint32_t cryptid;
    /// Packed xxxx.yy.zz from LC_BUILD_VERSION or LC_VERSION_MIN_IPHONEOS, 0 when absent. This is
    /// diagnostic context only; it does not determine whether the image can be mapped.
    uint32_t min_os;
    bool is_64;
} decrypt_macho_image_t;

/// mach_vm_* take 64-bit addresses regardless of the caller's word size, and are not declared in
/// any SDK header available here.
typedef uint64_t decrypt_vm_address_t;
typedef uint64_t decrypt_vm_size_t;

extern kern_return_t mach_vm_read_overwrite(vm_map_t task, decrypt_vm_address_t address,
                                            decrypt_vm_size_t size, decrypt_vm_address_t data,
                                            decrypt_vm_size_t *data_size);
extern kern_return_t mach_vm_allocate(vm_map_t task, decrypt_vm_address_t *address,
                                      decrypt_vm_size_t size, int flags);
extern kern_return_t mach_vm_deallocate(vm_map_t task, decrypt_vm_address_t address,
                                        decrypt_vm_size_t size);
extern kern_return_t mach_vm_write(vm_map_t task, decrypt_vm_address_t address,
                                   vm_offset_t data, mach_msg_type_number_t count);
extern kern_return_t mach_vm_region(vm_map_t task, decrypt_vm_address_t *address,
                                    decrypt_vm_size_t *size, vm_region_flavor_t flavor,
                                    vm_region_info_t info, mach_msg_type_number_t *info_count,
                                    mach_port_t *object_name);
/// Private, and the only way to clear the hold xpcproxy leaves on an SBS-launched target. Draining
/// task_resume is not enough: that hold lives at the proc layer, not the task layer.
extern int pid_resume(pid_t pid);

/// Fixed-size read out of the target. False unless every requested byte arrived.
bool decrypt_target_read(task_t task, uint64_t address, void *into, size_t size);

/// Why the last remote call ended: the mach_msg result, and the PC the thread stopped at. A failed
/// call has three causes (never faulted, faulted elsewhere, state unreadable) that look identical
/// from outside, and guessing between them costs a device round trip each time.
void decrypt_remote_last_call(mach_msg_return_t *received, uint64_t *pc);

/// Arms a buffer that a failed export lookup fills with the first few symbols it *did* find, so a
/// genuine miss can be told apart from a trie being parsed wrongly. NULL disarms it.
void decrypt_remote_set_export_sample(char *buffer, size_t size);

/// Running OS as the same packed xxxx.yy.zz, 0 when it cannot be determined.
uint32_t decrypt_running_os_version(void);
/// Formats a packed version into "16.7.12". Returns buffer.
const char *decrypt_format_os_version(uint32_t version, char *buffer, size_t size);

decrypt_status_t decrypt_macho_inspect(const void *file_data,
                                       size_t file_size,
                                       int32_t runtime_cpu_type,
                                       int32_t runtime_cpu_subtype,
                                       decrypt_macho_image_t *image);

decrypt_status_t decrypt_macho_inspect_any(const void *file_data,
                                           size_t file_size,
                                           decrypt_macho_image_t *image);

decrypt_status_t decrypt_macho_replace(void *file_data,
                                       size_t file_size,
                                       const decrypt_macho_image_t *image,
                                       const void *plaintext,
                                       size_t plaintext_size);

decrypt_status_t decrypt_macho_inspect_file(const char *path,
                                            int32_t runtime_cpu_type,
                                            int32_t runtime_cpu_subtype,
                                            decrypt_macho_image_t *image);

decrypt_status_t decrypt_macho_inspect_file_any(const char *path,
                                                decrypt_macho_image_t *image);

decrypt_status_t decrypt_output_replace_image(const char *source_path,
                                              const char *destination_path,
                                              const decrypt_macho_image_t *image,
                                              const void *plaintext,
                                              size_t plaintext_size);


typedef enum {
    DECRYPT_LOG_DEBUG = 0,
    DECRYPT_LOG_INFO,
    DECRYPT_LOG_WARNING,
    DECRYPT_LOG_ERROR,
} decrypt_log_level_t;

typedef struct {
    FILE *stream;
    bool verbose;
} decrypt_logger_t;

typedef struct {
    char data[2048];
    size_t length;
    bool truncated;
} decrypt_event_attrs_t;

typedef enum {
    DECRYPT_LAUNCH_NONE = 0,
    DECRYPT_LAUNCH_SBS,
    DECRYPT_LAUNCH_PTRACE,
} decrypt_launch_method_t;

typedef struct {
    pid_t pid;
    task_t task;
    /// Receive right the hijacked thread's faults are routed to, so a remote call can tell "the
    /// function returned" from "the target crashed". MACH_PORT_NULL until the first remote call.
    mach_port_t exception_port;
    decrypt_launch_method_t method;
    /// Exit status of the ptrace child when it died instead of stopping, else -1. 127 means execve
    /// never ran the image, which is the only way to tell a rejected binary from a crashed one.
    int exec_status;
    /// True once dyld has mapped the bundle's images. Gates every pass that needs the loader,
    /// which is not the same question as which launch method was used.
    bool loader_ready;
    /// Set when +x had to be added to spawn the target, so close() can put the mode back. Apple
    /// ships some appex binaries mode 644; execve refuses those with EACCES and the child exits
    /// 127, which is indistinguishable from any other spawn failure without this.
    bool mode_restore_pending;
    mode_t original_mode;
    char original_mode_path[1024];
    bool alive;
} decrypt_process_t;

void decrypt_logger_init(decrypt_logger_t *logger, FILE *stream, bool verbose);
void decrypt_attrs_init(decrypt_event_attrs_t *attrs);
void decrypt_attrs_string(decrypt_event_attrs_t *attrs,
                          const char *key,
                          const char *value);
void decrypt_attrs_int(decrypt_event_attrs_t *attrs,
                       const char *key,
                       int64_t value);
void decrypt_attrs_uint(decrypt_event_attrs_t *attrs,
                        const char *key,
                        uint64_t value);
void decrypt_attrs_hex(decrypt_event_attrs_t *attrs,
                       const char *key,
                       uint64_t value);
void decrypt_event(decrypt_logger_t *logger,
                   decrypt_log_level_t level,
                   const char *name,
                   const decrypt_event_attrs_t *attrs,
                   const char *format, ...)
    __attribute__((format(printf, 5, 6)));

decrypt_status_t decrypt_process_open(decrypt_process_t *process,
                                      const char *bundle_id,
                                      const char *executable_path,
                                      decrypt_logger_t *logger);
/// Lets a ptrace-stopped child run past execve so dyld maps the bundle's frameworks, then freezes
/// it again. Returns whether the loader is usable afterwards. A no-op for SBS targets, which have
/// already run to a settled state. Call it after the main image is dumped, not before.
bool decrypt_process_start_loader(decrypt_process_t *process, decrypt_logger_t *logger);
void decrypt_process_close(decrypt_process_t *process);

decrypt_status_t decrypt_runtime_dump_main(decrypt_process_t *process,
                                           const char *source_path,
                                           const char *destination_path,
                                           const char *display_name,
                                           decrypt_logger_t *logger);

int decrypt_runtime_dump_loaded_bundle_images(decrypt_process_t *process,
                                              const char *source_bundle,
                                              const char *destination_bundle,
                                              const char *main_name,
                                              decrypt_logger_t *logger);

/// Runs `function(args...)` on a target thread and returns x0. The register state is restored and
/// the target is left suspended. Supports up to six arguments.
decrypt_status_t decrypt_runtime_call(decrypt_process_t *process,
                                      uint64_t function,
                                      const uint64_t *args,
                                      unsigned argument_count,
                                      uint64_t *result);

/// Resolves a symbol exported by an image already mapped in the target, by walking that image's
/// export trie out of target memory. `image_base` is the mapped header address.
decrypt_status_t decrypt_runtime_lookup_export(decrypt_process_t *process,
                                               uint64_t image_base,
                                               const char *symbol,
                                               uint64_t *address);

/// Target-memory address of dyld, used as the final loader-symbol lookup fallback.
decrypt_status_t decrypt_runtime_dyld_base(decrypt_process_t *process, uint64_t *base);

/// Second acquisition pass: finds bundle images the natural load never mapped, dlopens them into
/// the target, and dumps them. Nested .appex roots are skipped, being separate targets.
int decrypt_runtime_dump_missing_bundle_images(decrypt_process_t *process,
                                               const char *source_bundle,
                                               const char *destination_bundle,
                                               const char *main_name,
                                               decrypt_logger_t *logger);

/// Blocks until dyld's image count stops changing, and returns it. Zero never counts as settled.
uint32_t decrypt_runtime_wait_for_images(task_t task, pid_t pid);

/// Current count of images dyld has mapped in the target, 0 when it cannot be read.
uint32_t decrypt_runtime_image_count(task_t task);

/// Finds a loaded image whose path ends with `path_suffix`.
decrypt_status_t decrypt_runtime_find_image(decrypt_process_t *process,
                                            const char *path_suffix,
                                            uint64_t *base);

/// Resolves a loader entry point (dlopen and friends) from whichever image vends it on this OS.
decrypt_status_t decrypt_runtime_resolve_loader(decrypt_process_t *process,
                                                const char *symbol,
                                                uint64_t *address,
                                                char *where,
                                                size_t where_size);

/// Copies a C string into freshly allocated, non-executable target memory.
decrypt_status_t decrypt_runtime_write_string(decrypt_process_t *process,
                                              const char *value,
                                              uint64_t *address,
                                              uint64_t *size);
void decrypt_runtime_free_target(decrypt_process_t *process, uint64_t address, uint64_t size);

/// Exercises resolve-then-call against a target using dlopen(RTLD_NOLOAD), which loads nothing.
decrypt_status_t decrypt_runtime_selftest(decrypt_process_t *process,
                                          const char *source_bundle,
                                          decrypt_logger_t *logger);

#endif
