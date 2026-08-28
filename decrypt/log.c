#include "internal.h"

#include <ctype.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

static const char *level_name(decrypt_log_level_t level) {
    switch (level) {
    case DECRYPT_LOG_DEBUG:   return "debug";
    case DECRYPT_LOG_INFO:    return "info";
    case DECRYPT_LOG_WARNING: return "warn";
    case DECRYPT_LOG_ERROR:   return "error";
    }
    return "unknown";
}

static bool key_valid(const char *key) {
    if (!key || !*key)
        return false;
    for (const unsigned char *p = (const unsigned char *)key; *p; p++) {
        if (!isalnum(*p) && *p != '_' && *p != '.' && *p != '-')
            return false;
    }
    return true;
}

static void append_char(decrypt_event_attrs_t *attrs, char value) {
    if (attrs->length + 1 >= sizeof(attrs->data)) {
        attrs->truncated = true;
        return;
    }
    attrs->data[attrs->length++] = value;
    attrs->data[attrs->length] = '\0';
}

static void append_text(decrypt_event_attrs_t *attrs, const char *text) {
    if (!text)
        text = "";
    while (*text)
        append_char(attrs, *text++);
}

static void append_escaped(decrypt_event_attrs_t *attrs, const char *value) {
    if (!value)
        value = "";
    append_char(attrs, '"');
    for (const unsigned char *p = (const unsigned char *)value; *p; p++) {
        switch (*p) {
        case '\\': append_text(attrs, "\\\\"); break;
        case '"':  append_text(attrs, "\\\""); break;
        case '\n': append_text(attrs, "\\n"); break;
        case '\r': append_text(attrs, "\\r"); break;
        case '\t': append_text(attrs, "\\t"); break;
        default:
            if (isprint(*p))
                append_char(attrs, (char)*p);
            else
                append_char(attrs, '?');
            break;
        }
    }
    append_char(attrs, '"');
}

static void append_key(decrypt_event_attrs_t *attrs, const char *key) {
    if (!attrs || attrs->truncated || !key_valid(key))
        return;
    if (attrs->length)
        append_char(attrs, ' ');
    append_text(attrs, key);
    append_char(attrs, '=');
}

void decrypt_logger_init(decrypt_logger_t *logger, FILE *stream, bool verbose) {
    if (!logger)
        return;
    logger->stream = stream ? stream : stdout;
    logger->verbose = verbose;
}

void decrypt_attrs_init(decrypt_event_attrs_t *attrs) {
    if (!attrs)
        return;
    memset(attrs, 0, sizeof(*attrs));
}

void decrypt_attrs_string(decrypt_event_attrs_t *attrs,
                          const char *key,
                          const char *value) {
    if (!attrs || !key_valid(key))
        return;
    append_key(attrs, key);
    append_escaped(attrs, value);
}

static void append_number(decrypt_event_attrs_t *attrs,
                          const char *key,
                          const char *number) {
    if (!attrs || !key_valid(key))
        return;
    append_key(attrs, key);
    append_text(attrs, number);
}

void decrypt_attrs_int(decrypt_event_attrs_t *attrs,
                       const char *key,
                       int64_t value) {
    char number[32];
    snprintf(number, sizeof(number), "%lld", (long long)value);
    append_number(attrs, key, number);
}

void decrypt_attrs_uint(decrypt_event_attrs_t *attrs,
                        const char *key,
                        uint64_t value) {
    char number[32];
    snprintf(number, sizeof(number), "%llu", (unsigned long long)value);
    append_number(attrs, key, number);
}

void decrypt_attrs_hex(decrypt_event_attrs_t *attrs,
                       const char *key,
                       uint64_t value) {
    char number[32];
    snprintf(number, sizeof(number), "0x%llx", (unsigned long long)value);
    append_number(attrs, key, number);
}

void decrypt_event(decrypt_logger_t *logger,
                   decrypt_log_level_t level,
                   const char *name,
                   const decrypt_event_attrs_t *attrs,
                   const char *format, ...) {
    if (!logger || !logger->stream || !key_valid(name) ||
        (level == DECRYPT_LOG_DEBUG && !logger->verbose))
        return;

    char message[2048];
    if (format) {
        va_list arguments;
        va_start(arguments, format);
        vsnprintf(message, sizeof(message), format, arguments);
        va_end(arguments);
    } else {
        message[0] = '\0';
    }

    decrypt_event_attrs_t escaped;
    decrypt_attrs_init(&escaped);
    append_escaped(&escaped, message);

    fprintf(logger->stream, "@evt event=%s level=%s msg=%s",
            name, level_name(level), escaped.data);
    if (attrs && attrs->length)
        fprintf(logger->stream, " %s", attrs->data);
    if ((attrs && attrs->truncated) || escaped.truncated)
        fputs(" attrs_truncated=1", logger->stream);
    fputc('\n', logger->stream);
    fflush(logger->stream);
}
