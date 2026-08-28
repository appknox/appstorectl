#include "internal.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static bool has_suffix(const char *value, const char *suffix) {
    size_t value_size = strlen(value);
    size_t suffix_size = strlen(suffix);
    return value_size >= suffix_size &&
           strcmp(value + value_size - suffix_size, suffix) == 0;
}

static bool looks_like_macho(const char *path) {
    uint8_t magic[4];
    int fd = open(path, O_RDONLY);
    if (fd < 0)
        return false;
    ssize_t received = read(fd, magic, sizeof(magic));
    close(fd);
    if (received != sizeof(magic))
        return false;
    uint32_t little = (uint32_t)magic[0] | (uint32_t)magic[1] << 8 |
                      (uint32_t)magic[2] << 16 | (uint32_t)magic[3] << 24;
    uint32_t big = (uint32_t)magic[0] << 24 | (uint32_t)magic[1] << 16 |
                   (uint32_t)magic[2] << 8 | (uint32_t)magic[3];
    return little == UINT32_C(0xfeedface) || little == UINT32_C(0xfeedfacf) ||
           big == UINT32_C(0xcafebabe) || big == UINT32_C(0xcafebabf);
}

static decrypt_status_t find_executable(const char *bundle,
                                        char *name,
                                        size_t name_size) {
    const char *base = strrchr(bundle, '/');
    base = base ? base + 1 : bundle;
    size_t base_size = strlen(base);
    if (base_size > 4 &&
        (has_suffix(base, ".app") || has_suffix(base, ".appex")))
        base_size -= has_suffix(base, ".appex") ? 6 : 4;

    if (base_size > 0 && base_size < name_size) {
        memcpy(name, base, base_size);
        name[base_size] = '\0';
        char candidate[PATH_MAX];
        int length = snprintf(candidate, sizeof(candidate), "%s/%s", bundle, name);
        if (length > 0 && (size_t)length < sizeof(candidate) && looks_like_macho(candidate))
            return DECRYPT_OK;
    }

    DIR *directory = opendir(bundle);
    if (!directory)
        return DECRYPT_IO_ERROR;
    decrypt_status_t status = DECRYPT_NO_ENCRYPTION_INFO;
    struct dirent *entry;
    while ((entry = readdir(directory))) {
        if (entry->d_name[0] == '.')
            continue;
        char candidate[PATH_MAX];
        int length = snprintf(candidate, sizeof(candidate), "%s/%s",
                              bundle, entry->d_name);
        struct stat st;
        if (length <= 0 || (size_t)length >= sizeof(candidate) ||
            lstat(candidate, &st) != 0 || !S_ISREG(st.st_mode) ||
            !looks_like_macho(candidate))
            continue;
        if (strlen(entry->d_name) >= name_size) {
            status = DECRYPT_INVALID_ARGUMENT;
            break;
        }
        strcpy(name, entry->d_name);
        status = DECRYPT_OK;
        break;
    }
    closedir(directory);
    return status;
}

// Report min_os as context only. Images declaring a newer OS have still mapped far enough to dump;
// transient exec failures are handled by the launch retry.
static void report_launch_failure(const char *source_path,
                                  const char *executable_name,
                                  const decrypt_process_t *process,
                                  decrypt_logger_t *logger) {
    decrypt_macho_image_t image;
    uint32_t min_os = decrypt_macho_inspect_file_any(source_path, &image) == DECRYPT_OK
                          ? image.min_os : 0;
    uint32_t running = decrypt_running_os_version();

    char min_text[32];
    char running_text[32];
    decrypt_event_attrs_t attrs;
    decrypt_attrs_init(&attrs);
    decrypt_attrs_string(&attrs, "main", executable_name);
    decrypt_attrs_string(&attrs, "reason", "spawn_failed");
    if (min_os)
        decrypt_attrs_string(&attrs, "min_os",
                             decrypt_format_os_version(min_os, min_text, sizeof(min_text)));
    if (running)
        decrypt_attrs_string(&attrs, "running_os",
                             decrypt_format_os_version(running, running_text,
                                                       sizeof(running_text)));
    decrypt_attrs_int(&attrs, "exec_status", process->exec_status);
    decrypt_event(logger, DECRYPT_LOG_ERROR, "target.failed", &attrs,
                  "%s did not launch after retries (exit status %d)",
                  executable_name, process->exec_status);
}

// Reports every Mach-O in a bundle with its cryptid and declared minimum OS, launching nothing.
// Exists because "does this app have an encrypted framework" was otherwise only answerable by
// running a full decrypt, and most apps turn out to ship their frameworks plain.
static void inspect_tree(const char *directory, const char *prefix, unsigned *encrypted) {
    DIR *handle = opendir(directory);
    if (!handle)
        return;
    struct dirent *entry;
    while ((entry = readdir(handle))) {
        if (entry->d_name[0] == '.')
            continue;
        char child[PATH_MAX], relative[PATH_MAX];
        if (snprintf(child, sizeof(child), "%s/%s", directory, entry->d_name) >=
                (int)sizeof(child) ||
            snprintf(relative, sizeof(relative), "%s%s%s", prefix, *prefix ? "/" : "",
                     entry->d_name) >= (int)sizeof(relative))
            continue;
        struct stat st;
        if (stat(child, &st) != 0)
            continue;
        if (S_ISDIR(st.st_mode)) {
            inspect_tree(child, relative, encrypted);
            continue;
        }
        if (!S_ISREG(st.st_mode) || !looks_like_macho(child))
            continue;
        decrypt_macho_image_t image;
        decrypt_status_t status = decrypt_macho_inspect_file_any(child, &image);
        if (status != DECRYPT_OK && status != DECRYPT_NO_ENCRYPTION_INFO)
            continue;
        char version[32] = "-";
        if (image.min_os)
            decrypt_format_os_version(image.min_os, version, sizeof(version));
        unsigned id = status == DECRYPT_OK ? image.cryptid : 0;
        if (id)
            (*encrypted)++;
        printf("  cryptid=%u  minos=%-8s %s\n", id, version, relative);
    }
    closedir(handle);
}

decrypt_status_t decrypt_inspect(const decrypt_options_t *options) {
    if (!options || !options->source_path)
        return DECRYPT_INVALID_ARGUMENT;
    struct stat st;
    if (stat(options->source_path, &st) != 0 || !S_ISDIR(st.st_mode))
        return DECRYPT_IO_ERROR;
    unsigned encrypted = 0;
    printf("%s\n", options->source_path);
    inspect_tree(options->source_path, "", &encrypted);
    char running[32];
    printf("  %u encrypted image(s), device runs %s\n", encrypted,
           decrypt_format_os_version(decrypt_running_os_version(), running, sizeof(running)));
    return DECRYPT_OK;
}

decrypt_status_t decrypt_selftest(const decrypt_options_t *options) {
    if (!options || !options->source_path || !options->bundle_id)
        return DECRYPT_INVALID_ARGUMENT;

    decrypt_logger_t logger;
    decrypt_logger_init(&logger, stdout, true);

    char executable_name[NAME_MAX + 1];
    decrypt_status_t status = find_executable(options->source_path, executable_name,
                                              sizeof(executable_name));
    if (status != DECRYPT_OK)
        return status;
    char source_path[PATH_MAX];
    if (snprintf(source_path, sizeof(source_path), "%s/%s",
                 options->source_path, executable_name) >= (int)sizeof(source_path))
        return DECRYPT_INVALID_ARGUMENT;

    decrypt_process_t process;
    memset(&process, 0, sizeof(process));
    process.pid = -1;
    status = decrypt_process_open(&process, options->bundle_id, source_path, &logger);
    if (status != DECRYPT_OK) {
        report_launch_failure(source_path, executable_name, &process, &logger);
        return status;
    }
    status = decrypt_runtime_selftest(&process, options->source_path, &logger);
    decrypt_process_close(&process);
    return status;
}

static decrypt_status_t decrypt_bundle(const char *source_bundle,
                                       const char *destination_bundle,
                                       const char *bundle_id,
                                       decrypt_logger_t *logger) {
    char executable_name[NAME_MAX + 1];
    decrypt_status_t status = find_executable(source_bundle, executable_name,
                                              sizeof(executable_name));
    if (status != DECRYPT_OK)
        return status;

    char source_path[PATH_MAX];
    char destination_path[PATH_MAX];
    if (snprintf(source_path, sizeof(source_path), "%s/%s",
                 source_bundle, executable_name) >= (int)sizeof(source_path) ||
        snprintf(destination_path, sizeof(destination_path), "%s/%s",
                 destination_bundle, executable_name) >= (int)sizeof(destination_path))
        return DECRYPT_INVALID_ARGUMENT;

    decrypt_event_attrs_t attrs;
    decrypt_attrs_init(&attrs);
    decrypt_attrs_string(&attrs, "src", source_bundle);
    decrypt_attrs_string(&attrs, "main", executable_name);
    decrypt_event(logger, DECRYPT_LOG_INFO, "bundle.begin", &attrs,
                  "decrypting bundle %s", source_bundle);

    decrypt_process_t process;
    memset(&process, 0, sizeof(process));
    process.pid = -1;
    status = decrypt_process_open(&process, bundle_id, source_path, logger);
    if (status == DECRYPT_OK)
        status = decrypt_runtime_dump_main(&process, source_path, destination_path,
                                           executable_name, logger);
    else
        report_launch_failure(source_path, executable_name, &process, logger);
    // Only now let a traced target run on. The main image is already captured from the execve stop,
    // so if running it forward goes badly nothing already recovered is lost.
    decrypt_process_start_loader(&process, logger);
    int extras = decrypt_runtime_dump_loaded_bundle_images(
        &process, source_bundle, destination_bundle, executable_name, logger);
    // Second pass for images the app never referenced, which dyld therefore never mapped. Only
    // worth attempting once the natural load has had its turn.
    extras += decrypt_runtime_dump_missing_bundle_images(
        &process, source_bundle, destination_bundle, executable_name, logger);
    // Read before closing: decrypt_process_close zeroes the struct, so anything wanted for the
    // summary has to be taken off it first.
    decrypt_launch_method_t used = process.method;
    decrypt_process_close(&process);

    // Report the method actually used, not the one requested. Reading it off bundle_id made a
    // ptrace fallback log itself as SBS, which is exactly backwards when the fallback is the thing
    // you are trying to notice.
    const char *method = used == DECRYPT_LAUNCH_SBS ? "SBS"
                       : used == DECRYPT_LAUNCH_PTRACE ? "ptrace" : "none";
    decrypt_attrs_init(&attrs);
    decrypt_attrs_string(&attrs, "src", source_bundle);
    decrypt_attrs_int(&attrs, "extras", extras);
    decrypt_attrs_string(&attrs, "method", method);
    decrypt_event(logger, status == DECRYPT_OK || status == DECRYPT_ALREADY_PLAIN
                              ? DECRYPT_LOG_INFO : DECRYPT_LOG_WARNING,
                  "bundle.done", &attrs,
                  "bundle done: %d framework(s) decrypted (%s)", extras, method);
    return status;
}

static void decrypt_extensions(const decrypt_options_t *options,
                               decrypt_logger_t *logger) {
    static const char *directories[] = {"PlugIns", "Extensions"};
    for (size_t index = 0; index < sizeof(directories) / sizeof(directories[0]); index++) {
        char source_root[PATH_MAX];
        char destination_root[PATH_MAX];
        if (snprintf(source_root, sizeof(source_root), "%s/%s",
                     options->source_path, directories[index]) >= (int)sizeof(source_root) ||
            snprintf(destination_root, sizeof(destination_root), "%s/%s",
                     options->destination_path, directories[index]) >=
                (int)sizeof(destination_root))
            continue;
        DIR *directory = opendir(source_root);
        if (!directory)
            continue;
        struct dirent *entry;
        while ((entry = readdir(directory))) {
            if (entry->d_name[0] == '.' || !has_suffix(entry->d_name, ".appex"))
                continue;
            char source[PATH_MAX];
            char destination[PATH_MAX];
            if (snprintf(source, sizeof(source), "%s/%s", source_root, entry->d_name) >=
                    (int)sizeof(source) ||
                snprintf(destination, sizeof(destination), "%s/%s",
                         destination_root, entry->d_name) >= (int)sizeof(destination))
                continue;
            decrypt_bundle(source, destination, "", logger);
        }
        closedir(directory);
    }
}

decrypt_status_t decrypt_run(const decrypt_options_t *options) {
    if (!options || !options->source_path || !options->destination_path ||
        !options->bundle_id)
        return DECRYPT_INVALID_ARGUMENT;

    struct stat source_stat;
    struct stat destination_stat;
    if (stat(options->source_path, &source_stat) != 0 ||
        stat(options->destination_path, &destination_stat) != 0 ||
        !S_ISDIR(source_stat.st_mode) || !S_ISDIR(destination_stat.st_mode))
        return DECRYPT_IO_ERROR;

    decrypt_logger_t logger;
    decrypt_logger_init(&logger, stdout, options->verbose);
    decrypt_status_t status = decrypt_bundle(options->source_path,
                                             options->destination_path,
                                             options->bundle_id, &logger);
    decrypt_extensions(options, &logger);
    decrypt_event(&logger, DECRYPT_LOG_INFO, "done", NULL, "done");
    return status;
}

const char *decrypt_status_name(decrypt_status_t status) {
    switch (status) {
    case DECRYPT_OK:                 return "ok";
    case DECRYPT_INVALID_ARGUMENT:   return "invalid_argument";
    case DECRYPT_TRUNCATED_INPUT:    return "truncated_input";
    case DECRYPT_MALFORMED_INPUT:    return "malformed_input";
    case DECRYPT_UNSUPPORTED_FORMAT: return "unsupported_format";
    case DECRYPT_ARCH_NOT_FOUND:     return "architecture_not_found";
    case DECRYPT_NO_ENCRYPTION_INFO: return "no_encryption_info";
    case DECRYPT_ALREADY_PLAIN:      return "already_plain";
    case DECRYPT_RANGE_MISMATCH:     return "range_mismatch";
    case DECRYPT_UNCHANGED_DATA:     return "unchanged_data";
    case DECRYPT_ZERO_DATA:          return "zero_data";
    case DECRYPT_IO_ERROR:           return "io_error";
    case DECRYPT_PLATFORM_ERROR:     return "platform_error";
    }
    return "unknown";
}
