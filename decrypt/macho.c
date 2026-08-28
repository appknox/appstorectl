#include "internal.h"

#include <limits.h>
#include <string.h>

static const uint32_t kMhMagic = UINT32_C(0xfeedface);
static const uint32_t kMhMagic64 = UINT32_C(0xfeedfacf);
static const uint32_t kFatMagic = UINT32_C(0xcafebabe);
static const uint32_t kFatMagic64 = UINT32_C(0xcafebabf);
static const int32_t kCpuSubtypeMask = (int32_t)UINT32_C(0xff000000);

enum {
    LC_ENCRYPTION_INFO = 0x21,
    LC_ENCRYPTION_INFO_64 = 0x2c,
    LC_VERSION_MIN_IPHONEOS = 0x25,
    LC_BUILD_VERSION = 0x32,
};

static uint32_t read_le32(const uint8_t *p) {
    return (uint32_t)p[0] |
           (uint32_t)p[1] << 8 |
           (uint32_t)p[2] << 16 |
           (uint32_t)p[3] << 24;
}

static uint32_t read_be32(const uint8_t *p) {
    return (uint32_t)p[0] << 24 |
           (uint32_t)p[1] << 16 |
           (uint32_t)p[2] << 8 |
           (uint32_t)p[3];
}

static uint64_t read_be64(const uint8_t *p) {
    return (uint64_t)read_be32(p) << 32 | read_be32(p + 4);
}

static void write_le32(uint8_t *p, uint32_t value) {
    p[0] = (uint8_t)value;
    p[1] = (uint8_t)(value >> 8);
    p[2] = (uint8_t)(value >> 16);
    p[3] = (uint8_t)(value >> 24);
}

static bool range_valid(size_t size, uint64_t offset, uint64_t length) {
    return offset <= size && length <= (uint64_t)size - offset;
}

static int32_t subtype_base(int32_t subtype) {
    return subtype & ~kCpuSubtypeMask;
}

static bool architecture_matches(int32_t cpu_type,
                                 int32_t cpu_subtype,
                                 int32_t runtime_cpu_type,
                                 int32_t runtime_cpu_subtype) {
    return cpu_type == runtime_cpu_type &&
           subtype_base(cpu_subtype) == subtype_base(runtime_cpu_subtype);
}

static decrypt_status_t inspect_thin(const uint8_t *data,
                                     size_t file_size,
                                     uint64_t slice_offset,
                                     uint64_t slice_size,
                                     int32_t runtime_cpu_type,
                                     int32_t runtime_cpu_subtype,
                                     decrypt_macho_image_t *image) {
    if (!range_valid(file_size, slice_offset, slice_size) || slice_size < 4)
        return DECRYPT_TRUNCATED_INPUT;

    const uint8_t *slice = data + slice_offset;
    uint32_t magic = read_le32(slice);
    bool is_64 = magic == kMhMagic64;
    size_t header_size = is_64 ? 32 : 28;

    if (magic != kMhMagic && magic != kMhMagic64)
        return DECRYPT_UNSUPPORTED_FORMAT;
    if (slice_size < header_size)
        return DECRYPT_TRUNCATED_INPUT;

    int32_t cpu_type = (int32_t)read_le32(slice + 4);
    int32_t cpu_subtype = (int32_t)read_le32(slice + 8);
    if (!architecture_matches(cpu_type, cpu_subtype,
                              runtime_cpu_type, runtime_cpu_subtype))
        return DECRYPT_ARCH_NOT_FOUND;

    uint32_t command_count = read_le32(slice + 16);
    uint32_t command_bytes = read_le32(slice + 20);
    if (!range_valid((size_t)slice_size, header_size, command_bytes))
        return DECRYPT_TRUNCATED_INPUT;

    uint64_t cursor = header_size;
    uint64_t command_end = header_size + (uint64_t)command_bytes;
    bool found = false;
    // Collected separately because the version command may sit either side of the encryption one.
    uint32_t min_os = 0;

    for (uint32_t index = 0; index < command_count; index++) {
        if (cursor > command_end || command_end - cursor < 8)
            return DECRYPT_TRUNCATED_INPUT;

        const uint8_t *command = slice + cursor;
        uint32_t kind = read_le32(command);
        uint32_t command_size = read_le32(command + 4);
        if (command_size < 8 || command_size > command_end - cursor)
            return DECRYPT_MALFORMED_INPUT;

        if (kind == LC_BUILD_VERSION && command_size >= 16)
            min_os = read_le32(command + 12);
        else if (kind == LC_VERSION_MIN_IPHONEOS && command_size >= 12 && min_os == 0)
            min_os = read_le32(command + 8);

        bool encryption_command = kind == LC_ENCRYPTION_INFO ||
                                  kind == LC_ENCRYPTION_INFO_64;
        if (encryption_command) {
            size_t minimum_size = kind == LC_ENCRYPTION_INFO_64 ? 24 : 20;
            if (found || command_size < minimum_size)
                return DECRYPT_MALFORMED_INPUT;
            if ((is_64 && kind != LC_ENCRYPTION_INFO_64) ||
                (!is_64 && kind != LC_ENCRYPTION_INFO))
                return DECRYPT_MALFORMED_INPUT;

            uint32_t crypt_offset = read_le32(command + 8);
            uint32_t crypt_size = read_le32(command + 12);
            uint32_t cryptid = read_le32(command + 16);
            if (!range_valid((size_t)slice_size, crypt_offset, crypt_size) ||
                (cryptid != 0 && crypt_size == 0))
                return DECRYPT_MALFORMED_INPUT;

            image->slice_offset = slice_offset;
            image->slice_size = slice_size;
            image->runtime_offset = crypt_offset;
            image->encrypted_offset = slice_offset + crypt_offset;
            image->encrypted_size = crypt_size;
            image->cryptid_offset = slice_offset + cursor + 16;
            image->cpu_type = cpu_type;
            image->cpu_subtype = cpu_subtype;
            image->cryptid = cryptid;
            image->is_64 = is_64;
            found = true;
        }

        cursor += command_size;
    }

    if (cursor != command_end)
        return DECRYPT_MALFORMED_INPUT;
    image->min_os = min_os;
    return found ? DECRYPT_OK : DECRYPT_NO_ENCRYPTION_INFO;
}

decrypt_status_t decrypt_macho_inspect(const void *file_data,
                                       size_t file_size,
                                       int32_t runtime_cpu_type,
                                       int32_t runtime_cpu_subtype,
                                       decrypt_macho_image_t *image) {
    if (!file_data || !image || runtime_cpu_type == 0)
        return DECRYPT_INVALID_ARGUMENT;
    memset(image, 0, sizeof(*image));
    if (file_size < 4)
        return DECRYPT_TRUNCATED_INPUT;

    const uint8_t *data = file_data;
    uint32_t thin_magic = read_le32(data);
    if (thin_magic == kMhMagic || thin_magic == kMhMagic64)
        return inspect_thin(data, file_size, 0, file_size,
                            runtime_cpu_type, runtime_cpu_subtype, image);

    uint32_t fat_magic = read_be32(data);
    if (fat_magic != kFatMagic && fat_magic != kFatMagic64)
        return DECRYPT_UNSUPPORTED_FORMAT;
    if (file_size < 8)
        return DECRYPT_TRUNCATED_INPUT;

    uint32_t architecture_count = read_be32(data + 4);
    size_t entry_size = fat_magic == kFatMagic64 ? 32 : 20;
    if (architecture_count == 0 ||
        architecture_count > (file_size - 8) / entry_size)
        return DECRYPT_TRUNCATED_INPUT;

    uint64_t selected_offset = 0;
    uint64_t selected_size = 0;
    bool selected = false;
    bool exact = false;

    for (uint32_t index = 0; index < architecture_count; index++) {
        const uint8_t *entry = data + 8 + (size_t)index * entry_size;
        int32_t cpu_type = (int32_t)read_be32(entry);
        int32_t cpu_subtype = (int32_t)read_be32(entry + 4);
        if (!architecture_matches(cpu_type, cpu_subtype,
                                  runtime_cpu_type, runtime_cpu_subtype))
            continue;

        uint64_t offset = fat_magic == kFatMagic64
                            ? read_be64(entry + 8)
                            : read_be32(entry + 8);
        uint64_t size = fat_magic == kFatMagic64
                            ? read_be64(entry + 16)
                            : read_be32(entry + 12);
        if (!range_valid(file_size, offset, size))
            return DECRYPT_MALFORMED_INPUT;

        bool entry_exact = cpu_subtype == runtime_cpu_subtype;
        if (!selected || (entry_exact && !exact)) {
            selected_offset = offset;
            selected_size = size;
            selected = true;
            exact = entry_exact;
        }
    }

    if (!selected)
        return DECRYPT_ARCH_NOT_FOUND;
    return inspect_thin(data, file_size, selected_offset, selected_size,
                        runtime_cpu_type, runtime_cpu_subtype, image);
}

decrypt_status_t decrypt_macho_replace(void *file_data,
                                       size_t file_size,
                                       const decrypt_macho_image_t *image,
                                       const void *plaintext,
                                       size_t plaintext_size) {
    if (!file_data || !image || !plaintext)
        return DECRYPT_INVALID_ARGUMENT;
    if (image->cryptid == 0)
        return DECRYPT_ALREADY_PLAIN;
    if (plaintext_size != image->encrypted_size)
        return DECRYPT_RANGE_MISMATCH;
    if (!range_valid(file_size, image->encrypted_offset, image->encrypted_size) ||
        !range_valid(file_size, image->cryptid_offset, sizeof(uint32_t)))
        return DECRYPT_RANGE_MISMATCH;

    uint8_t *data = file_data;
    if (read_le32(data + image->cryptid_offset) != image->cryptid)
        return DECRYPT_RANGE_MISMATCH;

    const uint8_t *bytes = plaintext;
    bool all_zero = true;
    for (size_t index = 0; index < plaintext_size; index++) {
        if (bytes[index] != 0) {
            all_zero = false;
            break;
        }
    }
    if (all_zero)
        return DECRYPT_ZERO_DATA;
    if (memcmp(data + image->encrypted_offset, bytes, plaintext_size) == 0)
        return DECRYPT_UNCHANGED_DATA;

    memmove(data + image->encrypted_offset, bytes, plaintext_size);
    write_le32(data + image->cryptid_offset, 0);
    return DECRYPT_OK;
}

decrypt_status_t decrypt_macho_inspect_any(const void *file_data,
                                           size_t file_size,
                                           decrypt_macho_image_t *image) {
    if (!file_data || !image)
        return DECRYPT_INVALID_ARGUMENT;
    if (file_size < 12)
        return DECRYPT_TRUNCATED_INPUT;
    const uint8_t *data = file_data;
    uint32_t thin_magic = read_le32(data);
    if (thin_magic == kMhMagic || thin_magic == kMhMagic64)
        return decrypt_macho_inspect(data, file_size,
            (int32_t)read_le32(data + 4), (int32_t)read_le32(data + 8), image);

    uint32_t fat_magic = read_be32(data);
    if (fat_magic != kFatMagic && fat_magic != kFatMagic64)
        return DECRYPT_UNSUPPORTED_FORMAT;
    size_t entry_size = fat_magic == kFatMagic64 ? 32 : 20;
    if (file_size < 8 + entry_size || read_be32(data + 4) == 0)
        return DECRYPT_TRUNCATED_INPUT;
    return decrypt_macho_inspect(data, file_size,
        (int32_t)read_be32(data + 8), (int32_t)read_be32(data + 12), image);
}
