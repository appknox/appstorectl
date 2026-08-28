#ifndef APPSTORECTL_DECRYPT_H
#define APPSTORECTL_DECRYPT_H

#include <stdbool.h>

typedef enum {
    DECRYPT_OK = 0,
    DECRYPT_INVALID_ARGUMENT,
    DECRYPT_TRUNCATED_INPUT,
    DECRYPT_MALFORMED_INPUT,
    DECRYPT_UNSUPPORTED_FORMAT,
    DECRYPT_ARCH_NOT_FOUND,
    DECRYPT_NO_ENCRYPTION_INFO,
    DECRYPT_ALREADY_PLAIN,
    DECRYPT_RANGE_MISMATCH,
    DECRYPT_UNCHANGED_DATA,
    DECRYPT_ZERO_DATA,
    DECRYPT_IO_ERROR,
    DECRYPT_PLATFORM_ERROR,
} decrypt_status_t;

typedef struct {
    const char *bundle_id;
    const char *source_path;
    const char *destination_path;
    bool verbose;
} decrypt_options_t;

decrypt_status_t decrypt_run(const decrypt_options_t *options);
/// Launches the app and exercises the remote-call primitive against it without modifying anything.
decrypt_status_t decrypt_selftest(const decrypt_options_t *options);
/// Reports cryptid and minimum OS for every Mach-O in a bundle. Launches nothing.
decrypt_status_t decrypt_inspect(const decrypt_options_t *options);
const char *decrypt_status_name(decrypt_status_t status);

#endif
