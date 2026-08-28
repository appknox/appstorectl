#include "internal.h"

#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static const uint32_t kMhMagic64 = UINT32_C(0xfeedfacf);
static const uint32_t kFatMagic = UINT32_C(0xcafebabe);

enum {
    LC_ENCRYPTION_INFO_64 = 0x2c,
};

static void put_le32(uint8_t *p, uint32_t value) {
    p[0] = (uint8_t)value;
    p[1] = (uint8_t)(value >> 8);
    p[2] = (uint8_t)(value >> 16);
    p[3] = (uint8_t)(value >> 24);
}

static void put_be32(uint8_t *p, uint32_t value) {
    p[0] = (uint8_t)(value >> 24);
    p[1] = (uint8_t)(value >> 16);
    p[2] = (uint8_t)(value >> 8);
    p[3] = (uint8_t)value;
}

static void make_thin(uint8_t *file, size_t size, int32_t subtype, uint8_t fill) {
    assert(size >= 0x140);
    memset(file, 0, size);
    put_le32(file, kMhMagic64);
    put_le32(file + 4, CPU_TYPE_ARM64);
    put_le32(file + 8, (uint32_t)subtype);
    put_le32(file + 12, 2);
    put_le32(file + 16, 1);
    put_le32(file + 20, 24);
    put_le32(file + 32, LC_ENCRYPTION_INFO_64);
    put_le32(file + 36, 24);
    put_le32(file + 40, 0x100);
    put_le32(file + 44, 0x20);
    put_le32(file + 48, 1);
    memset(file + 0x100, fill, 0x20);
}

static void test_thin_inspect_and_replace(void) {
    uint8_t file[0x200];
    uint8_t original[sizeof(file)];
    uint8_t plaintext[0x20];
    make_thin(file, sizeof(file), CPU_SUBTYPE_ARM64_ALL, 0xa5);
    memcpy(original, file, sizeof(file));
    for (size_t i = 0; i < sizeof(plaintext); i++)
        plaintext[i] = (uint8_t)(i + 1);

    decrypt_macho_image_t image;
    decrypt_macho_image_t any_image;
    assert(decrypt_macho_inspect(file, sizeof(file), CPU_TYPE_ARM64,
                                 CPU_SUBTYPE_ARM64_ALL, &image) == DECRYPT_OK);
    assert(decrypt_macho_inspect_any(file, sizeof(file), &any_image) == DECRYPT_OK);
    assert(any_image.encrypted_offset == image.encrypted_offset);
    assert(image.slice_offset == 0);
    assert(image.runtime_offset == 0x100);
    assert(image.encrypted_offset == 0x100);
    assert(image.encrypted_size == sizeof(plaintext));
    assert(image.cryptid_offset == 48);
    assert(image.cryptid == 1);
    assert(image.is_64);

    assert(decrypt_macho_replace(file, sizeof(file), &image,
                                 plaintext, sizeof(plaintext)) == DECRYPT_OK);
    assert(memcmp(file + 0x100, plaintext, sizeof(plaintext)) == 0);
    assert(file[48] == 0 && file[49] == 0 && file[50] == 0 && file[51] == 0);
    for (size_t i = 0; i < sizeof(file); i++) {
        bool replaced = i >= 0x100 && i < 0x120;
        bool cryptid = i >= 48 && i < 52;
        if (!replaced && !cryptid)
            assert(file[i] == original[i]);
    }
}

static void test_rejects_bad_plaintext(void) {
    uint8_t file[0x200];
    uint8_t snapshot[sizeof(file)];
    uint8_t zero[0x20] = {0};
    make_thin(file, sizeof(file), CPU_SUBTYPE_ARM64_ALL, 0xa5);

    decrypt_macho_image_t image;
    assert(decrypt_macho_inspect(file, sizeof(file), CPU_TYPE_ARM64,
                                 CPU_SUBTYPE_ARM64_ALL, &image) == DECRYPT_OK);
    memcpy(snapshot, file, sizeof(file));
    assert(decrypt_macho_replace(file, sizeof(file), &image,
                                 file + 0x100, 0x20) == DECRYPT_UNCHANGED_DATA);
    assert(memcmp(file, snapshot, sizeof(file)) == 0);
    assert(decrypt_macho_replace(file, sizeof(file), &image,
                                 zero, sizeof(zero)) == DECRYPT_ZERO_DATA);
    assert(memcmp(file, snapshot, sizeof(file)) == 0);
    assert(decrypt_macho_replace(file, sizeof(file), &image,
                                 zero, sizeof(zero) - 1) == DECRYPT_RANGE_MISMATCH);
    assert(memcmp(file, snapshot, sizeof(file)) == 0);
}

static void test_fat_selects_runtime_architecture(void) {
    uint8_t file[0x800] = {0};
    put_be32(file, kFatMagic);
    put_be32(file + 4, 2);

    put_be32(file + 8, CPU_TYPE_ARM64);
    put_be32(file + 12, CPU_SUBTYPE_ARM64_ALL);
    put_be32(file + 16, 0x100);
    put_be32(file + 20, 0x200);

    put_be32(file + 28, CPU_TYPE_ARM64);
    put_be32(file + 32, CPU_SUBTYPE_ARM64E);
    put_be32(file + 36, 0x400);
    put_be32(file + 40, 0x200);

    make_thin(file + 0x100, 0x200, CPU_SUBTYPE_ARM64_ALL, 0x11);
    make_thin(file + 0x400, 0x200, CPU_SUBTYPE_ARM64E, 0x22);

    decrypt_macho_image_t image;
    assert(decrypt_macho_inspect(file, sizeof(file), CPU_TYPE_ARM64,
                                 CPU_SUBTYPE_ARM64E, &image) == DECRYPT_OK);
    assert(image.slice_offset == 0x400);
    assert(image.runtime_offset == 0x100);
    assert(image.encrypted_offset == 0x500);
    assert(image.cpu_subtype == CPU_SUBTYPE_ARM64E);
}

static void test_atomic_output_replaces_hardlink(void) {
    char directory[] = "/tmp/appstorectl-output-test.XXXXXX";
    assert(mkdtemp(directory));

    char source[512];
    char destination[512];
    assert(snprintf(source, sizeof(source), "%s/source", directory) > 0);
    assert(snprintf(destination, sizeof(destination), "%s/destination", directory) > 0);

    uint8_t file[0x200];
    uint8_t plaintext[0x20];
    make_thin(file, sizeof(file), CPU_SUBTYPE_ARM64_ALL, 0x5a);
    for (size_t i = 0; i < sizeof(plaintext); i++)
        plaintext[i] = (uint8_t)(0xf0 - i);

    int fd = open(source, O_CREAT | O_EXCL | O_WRONLY, 0751);
    assert(fd >= 0);
    assert(write(fd, file, sizeof(file)) == sizeof(file));
    assert(close(fd) == 0);
    assert(link(source, destination) == 0);

    decrypt_macho_image_t image;
    assert(decrypt_macho_inspect_file(source, CPU_TYPE_ARM64,
                                      CPU_SUBTYPE_ARM64_ALL, &image) == DECRYPT_OK);
    assert(decrypt_output_replace_image(source, source, &image,
                                        plaintext, sizeof(plaintext)) ==
           DECRYPT_INVALID_ARGUMENT);

    struct stat before_source;
    struct stat before_destination;
    assert(stat(source, &before_source) == 0);
    assert(stat(destination, &before_destination) == 0);
    assert(before_source.st_ino == before_destination.st_ino);

    assert(decrypt_output_replace_image(source, destination, &image,
                                        plaintext, sizeof(plaintext)) == DECRYPT_OK);

    uint8_t source_after[sizeof(file)];
    uint8_t destination_after[sizeof(file)];
    fd = open(source, O_RDONLY);
    assert(fd >= 0);
    assert(read(fd, source_after, sizeof(source_after)) == sizeof(source_after));
    assert(close(fd) == 0);
    fd = open(destination, O_RDONLY);
    assert(fd >= 0);
    assert(read(fd, destination_after, sizeof(destination_after)) == sizeof(destination_after));
    assert(close(fd) == 0);

    assert(memcmp(source_after, file, sizeof(file)) == 0);
    assert(memcmp(destination_after + 0x100, plaintext, sizeof(plaintext)) == 0);
    assert(destination_after[48] == 0);

    struct stat after_source;
    struct stat after_destination;
    assert(stat(source, &after_source) == 0);
    assert(stat(destination, &after_destination) == 0);
    assert(after_source.st_ino != after_destination.st_ino);
    assert((after_destination.st_mode & 07777) == (before_source.st_mode & 07777));

    assert(unlink(destination) == 0);
    assert(unlink(source) == 0);
    assert(rmdir(directory) == 0);
}

static void test_structured_logging(void) {
    FILE *stream = tmpfile();
    assert(stream);

    decrypt_logger_t logger;
    decrypt_logger_init(&logger, stream, false);
    decrypt_event(&logger, DECRYPT_LOG_DEBUG, "hidden", NULL, "not emitted");

    decrypt_event_attrs_t attrs;
    decrypt_attrs_init(&attrs);
    decrypt_attrs_string(&attrs, "path", "/tmp/a b\\c");
    decrypt_attrs_int(&attrs, "pid", -7);
    decrypt_attrs_hex(&attrs, "base", 0x1234);
    decrypt_event(&logger, DECRYPT_LOG_INFO, "image.done", &attrs,
                  "wrote \"main\"\nimage");

    assert(fseek(stream, 0, SEEK_SET) == 0);
    char line[4096] = {0};
    assert(fgets(line, sizeof(line), stream));
    assert(strcmp(line,
        "@evt event=image.done level=info msg=\"wrote \\\"main\\\"\\nimage\" "
        "path=\"/tmp/a b\\\\c\" pid=-7 base=0x1234\n") == 0);
    assert(!fgets(line, sizeof(line), stream));
    fclose(stream);
}

static void test_malformed_inputs(void) {
    uint8_t file[0x200];
    decrypt_macho_image_t image;

    memset(file, 0, sizeof(file));
    assert(decrypt_macho_inspect(file, 3, CPU_TYPE_ARM64,
                                 CPU_SUBTYPE_ARM64_ALL, &image) == DECRYPT_TRUNCATED_INPUT);
    assert(decrypt_macho_inspect(file, sizeof(file), CPU_TYPE_ARM64,
                                 CPU_SUBTYPE_ARM64_ALL, &image) == DECRYPT_UNSUPPORTED_FORMAT);

    make_thin(file, sizeof(file), CPU_SUBTYPE_ARM64_ALL, 0x33);
    put_le32(file + 36, 4);
    assert(decrypt_macho_inspect(file, sizeof(file), CPU_TYPE_ARM64,
                                 CPU_SUBTYPE_ARM64_ALL, &image) == DECRYPT_MALFORMED_INPUT);

    make_thin(file, sizeof(file), CPU_SUBTYPE_ARM64_ALL, 0x33);
    put_le32(file + 40, 0x1f0);
    put_le32(file + 44, 0x40);
    assert(decrypt_macho_inspect(file, sizeof(file), CPU_TYPE_ARM64,
                                 CPU_SUBTYPE_ARM64_ALL, &image) == DECRYPT_MALFORMED_INPUT);

    make_thin(file, sizeof(file), CPU_SUBTYPE_ARM64_ALL, 0x33);
    assert(decrypt_macho_inspect(file, sizeof(file), CPU_TYPE_ARM64,
                                 CPU_SUBTYPE_ARM64E, &image) == DECRYPT_ARCH_NOT_FOUND);

    make_thin(file, sizeof(file), CPU_SUBTYPE_ARM64_ALL, 0x33);
    put_le32(file + 48, 0);
    assert(decrypt_macho_inspect(file, sizeof(file), CPU_TYPE_ARM64,
                                 CPU_SUBTYPE_ARM64_ALL, &image) == DECRYPT_OK);
    assert(decrypt_macho_replace(file, sizeof(file), &image,
                                 file + 0x100, 0x20) == DECRYPT_ALREADY_PLAIN);

    memset(file, 0, sizeof(file));
    put_be32(file, kFatMagic);
    put_be32(file + 4, UINT32_MAX);
    assert(decrypt_macho_inspect(file, sizeof(file), CPU_TYPE_ARM64,
                                 CPU_SUBTYPE_ARM64_ALL, &image) == DECRYPT_TRUNCATED_INPUT);
}

int main(void) {
    test_thin_inspect_and_replace();
    test_rejects_bad_plaintext();
    test_fat_selects_runtime_architecture();
    test_malformed_inputs();
    test_atomic_output_replaces_hardlink();
    test_structured_logging();
    puts("macho tests: ok");
    return 0;
}
