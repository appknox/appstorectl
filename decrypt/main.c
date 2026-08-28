// main.c — argv parsing and subcommand dispatch, and nothing else.
//
// One production entry point and two diagnostics. `into` is what cli/export.m invokes; it decrypts
// in place over a tree the caller has already staged, and never stages or packages anything itself.
// That division exists because export owns sinf validation, iTunesMetadata and the archive naming,
// and a helper that packaged its own output would silently drop all three.
#include "internal.h"

#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

static void usage(FILE *stream, const char *program) {
    fprintf(stream,
        "usage: %s [-v] into <bundle-id> <bundle-src> <bundle-dst>\n"
        "       %s selftest <bundle-id> <bundle-src>\n"
        "       %s inspect <bundle-src>\n"
        "       %s version\n"
        "\n"
        "  into      decrypt a staged bundle in place. What appstorectl export runs.\n"
        "  selftest  exercise the remote-call path against a target, changing nothing.\n"
        "  inspect   report cryptid and minimum OS per image, launching nothing.\n",
        program, program, program, program);
}

static int run_status(decrypt_status_t status) {
    if (status == DECRYPT_OK || status == DECRYPT_ALREADY_PLAIN ||
        status == DECRYPT_PLATFORM_ERROR || status == DECRYPT_UNCHANGED_DATA ||
        status == DECRYPT_ZERO_DATA)
        return 0;
    fprintf(stderr, "decrypt failed: %s\n", decrypt_status_name(status));
    return 1;
}

int main(int argc, char **argv) {
    signal(SIGPIPE, SIG_IGN);

    decrypt_options_t options = {0};
    const char *positionals[3] = {0};
    int positional_count = 0;
    const char *subcommand = NULL;

    for (int index = 1; index < argc; index++) {
        const char *argument = argv[index];
        if (strcmp(argument, "-h") == 0 || strcmp(argument, "--help") == 0) {
            usage(stdout, argv[0]);
            return 0;
        }
        if (strcmp(argument, "-v") == 0 || strcmp(argument, "--verbose") == 0) {
            options.verbose = true;
            continue;
        }
        if (strcmp(argument, "-q") == 0 || strcmp(argument, "--quiet") == 0)
            continue;
        if (!subcommand && positional_count == 0 &&
            (strcmp(argument, "into") == 0 || strcmp(argument, "selftest") == 0 ||
             strcmp(argument, "inspect") == 0 || strcmp(argument, "version") == 0)) {
            subcommand = argument;
            continue;
        }
        if (positional_count >= 3) {
            usage(stderr, argv[0]);
            return 2;
        }
        positionals[positional_count++] = argument;
    }

    if (!subcommand) {
        usage(stderr, argv[0]);
        return 2;
    }

    if (strcmp(subcommand, "version") == 0) {
        if (positional_count != 0) {
            usage(stderr, argv[0]);
            return 2;
        }
        puts("appstorectl-decrypt 0.1");
        return 0;
    }

    if (strcmp(subcommand, "inspect") == 0) {
        if (positional_count != 1) {
            usage(stderr, argv[0]);
            return 2;
        }
        options.source_path = positionals[0];
        return run_status(decrypt_inspect(&options));
    }

    if (strcmp(subcommand, "selftest") == 0) {
        if (positional_count != 2) {
            usage(stderr, argv[0]);
            return 2;
        }
        options.bundle_id = positionals[0];
        options.source_path = positionals[1];
        return run_status(decrypt_selftest(&options));
    }

    if (positional_count != 3) {
        usage(stderr, argv[0]);
        return 2;
    }
    options.bundle_id = positionals[0];
    options.source_path = positionals[1];
    options.destination_path = positionals[2];
    return run_status(decrypt_run(&options));
}
