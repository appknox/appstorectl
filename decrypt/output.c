#include "internal.h"

#include <errno.h>
#include <dirent.h>
#include <fcntl.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static decrypt_status_t map_source(const char *path,
                                   int *fd_out,
                                   uint8_t **data_out,
                                   size_t *size_out,
                                   struct stat *stat_out) {
    int fd = open(path, O_RDONLY);
    if (fd < 0)
        return DECRYPT_IO_ERROR;

    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size <= 0 ||
        (uintmax_t)st.st_size > SIZE_MAX) {
        close(fd);
        return DECRYPT_IO_ERROR;
    }

    size_t size = (size_t)st.st_size;
    void *mapping = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, 0);
    if (mapping == MAP_FAILED) {
        close(fd);
        return DECRYPT_IO_ERROR;
    }

    *fd_out = fd;
    *data_out = mapping;
    *size_out = size;
    if (stat_out)
        *stat_out = st;
    return DECRYPT_OK;
}
static void unmap_source(int fd, uint8_t *data, size_t size) {
    if (data)
        munmap(data, size);
    if (fd >= 0)
        close(fd);
}

static int write_all(int fd, const uint8_t *data, size_t size) {
    while (size) {
        ssize_t written = write(fd, data, size);
        if (written < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        if (written == 0)
            return -1;
        data += (size_t)written;
        size -= (size_t)written;
    }
    return 0;
}

static int pread_equals(int fd, off_t offset, const uint8_t *expected, size_t size) {
    uint8_t buffer[64 * 1024];
    while (size) {
        size_t amount = size < sizeof(buffer) ? size : sizeof(buffer);
        ssize_t received = pread(fd, buffer, amount, offset);
        if (received < 0 && errno == EINTR)
            continue;
        if (received <= 0 || memcmp(buffer, expected, (size_t)received) != 0)
            return -1;
        expected += (size_t)received;
        offset += received;
        size -= (size_t)received;
    }
    return 0;
}

decrypt_status_t decrypt_macho_inspect_file(const char *path,
                                            int32_t runtime_cpu_type,
                                            int32_t runtime_cpu_subtype,
                                            decrypt_macho_image_t *image) {
    if (!path || !image)
        return DECRYPT_INVALID_ARGUMENT;

    int fd = -1;
    uint8_t *data = NULL;
    size_t size = 0;
    decrypt_status_t status = map_source(path, &fd, &data, &size, NULL);
    if (status == DECRYPT_OK)
        status = decrypt_macho_inspect(data, size, runtime_cpu_type,
                                       runtime_cpu_subtype, image);
    unmap_source(fd, data, size);
    return status;
}

decrypt_status_t decrypt_macho_inspect_file_any(const char *path,
                                                decrypt_macho_image_t *image) {
    if (!path || !image)
        return DECRYPT_INVALID_ARGUMENT;
    int fd = -1;
    uint8_t *data = NULL;
    size_t size = 0;
    decrypt_status_t status = map_source(path, &fd, &data, &size, NULL);
    if (status == DECRYPT_OK)
        status = decrypt_macho_inspect_any(data, size, image);
    unmap_source(fd, data, size);
    return status;
}

decrypt_status_t decrypt_output_replace_image(const char *source_path,
                                              const char *destination_path,
                                              const decrypt_macho_image_t *image,
                                              const void *plaintext,
                                              size_t plaintext_size) {
    if (!source_path || !destination_path || !image || !plaintext ||
        strcmp(source_path, destination_path) == 0)
        return DECRYPT_INVALID_ARGUMENT;

    char source_real[PATH_MAX];
    char destination_real[PATH_MAX];
    if (!realpath(source_path, source_real) ||
        !realpath(destination_path, destination_real))
        return DECRYPT_IO_ERROR;
    if (strcmp(source_real, destination_real) == 0)
        return DECRYPT_INVALID_ARGUMENT;

    int source_fd = -1;
    uint8_t *source_data = NULL;
    size_t source_size = 0;
    struct stat source_stat;
    decrypt_status_t status = map_source(source_path, &source_fd, &source_data,
                                         &source_size, &source_stat);
    if (status != DECRYPT_OK)
        return status;

    decrypt_macho_image_t current;
    status = decrypt_macho_inspect(source_data, source_size,
                                   image->cpu_type, image->cpu_subtype, &current);
    if (status != DECRYPT_OK || memcmp(&current, image, sizeof(current)) != 0) {
        unmap_source(source_fd, source_data, source_size);
        return status == DECRYPT_OK ? DECRYPT_RANGE_MISMATCH : status;
    }

    status = decrypt_macho_replace(source_data, source_size, image,
                                   plaintext, plaintext_size);
    if (status != DECRYPT_OK) {
        unmap_source(source_fd, source_data, source_size);
        return status;
    }

    char temporary[PATH_MAX];
    int length = snprintf(temporary, sizeof(temporary), "%s.XXXXXX", destination_path);
    if (length < 0 || (size_t)length >= sizeof(temporary)) {
        unmap_source(source_fd, source_data, source_size);
        return DECRYPT_INVALID_ARGUMENT;
    }

    int output_fd = mkstemp(temporary);
    if (output_fd < 0) {
        unmap_source(source_fd, source_data, source_size);
        return DECRYPT_IO_ERROR;
    }

    bool committed = false;
    struct stat output_stat;
    struct timespec times[2] = {source_stat.st_atimespec, source_stat.st_mtimespec};
    if (fstat(output_fd, &output_stat) != 0 ||
        write_all(output_fd, source_data, source_size) != 0 ||
        ((output_stat.st_uid != source_stat.st_uid || output_stat.st_gid != source_stat.st_gid) &&
         fchown(output_fd, source_stat.st_uid, source_stat.st_gid) != 0) ||
        fchmod(output_fd, source_stat.st_mode & 07777) != 0 ||
        futimens(output_fd, times) != 0 ||
        fsync(output_fd) != 0) {
        status = DECRYPT_IO_ERROR;
        goto cleanup;
    }

    uint32_t written_cryptid = UINT32_MAX;
    if (pread(output_fd, &written_cryptid, sizeof(written_cryptid),
              (off_t)image->cryptid_offset) != sizeof(written_cryptid) ||
        written_cryptid != 0 ||
        pread_equals(output_fd, (off_t)image->encrypted_offset,
                     plaintext, plaintext_size) != 0) {
        status = DECRYPT_IO_ERROR;
        goto cleanup;
    }

    if (close(output_fd) != 0) {
        output_fd = -1;
        status = DECRYPT_IO_ERROR;
        goto cleanup;
    }
    output_fd = -1;
    if (rename(temporary, destination_path) != 0) {
        status = DECRYPT_IO_ERROR;
        goto cleanup;
    }
    committed = true;
    status = DECRYPT_OK;

cleanup:
    if (output_fd >= 0)
        close(output_fd);
    if (!committed)
        unlink(temporary);
    unmap_source(source_fd, source_data, source_size);
    return status;
}
