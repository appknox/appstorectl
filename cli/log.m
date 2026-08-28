// log.m — see log.h for why there are two channels.

#import <fcntl.h>
#import <unistd.h>

#import "log.h"

BOOL gQuiet = NO;

static const char *kLogPath = "/var/jb/var/log/appstorectl.log";

// Use device-local time so entries align with other on-device logs.
static void logStamp(char *out, size_t n) {
    time_t now = time(NULL);
    struct tm tmv;
    localtime_r(&now, &tmv);
    strftime(out, n, "%Y-%m-%d %H:%M:%S", &tmv);
}

// Each append reopens the file so completed records survive a later process crash. Escape control
// bytes and backslashes because app names, server payloads, and buyParameters are untrusted record
// data. Printable UTF-8 is preserved.
static NSString *escapeForLog(NSString *s) {
    if (!s.length) return s ?: @"";

    NSMutableString *out = [NSMutableString stringWithCapacity:s.length + 8];
    // Iterate UTF-8 bytes rather than characters: this is about what lands in the file.
    const char *utf8 = s.UTF8String;
    if (!utf8) return @"(unrepresentable)";   // invalid UTF-16 makes UTF8String return NULL

    for (const unsigned char *p = (const unsigned char *)utf8; *p; p++) {
        switch (*p) {
            case '\\': [out appendString:@"\\\\"]; break;
            case '\n': [out appendString:@"\\n"];  break;
            case '\r': [out appendString:@"\\r"];  break;
            case '\t': [out appendString:@"\\t"];  break;
            default:
                if (*p < 0x20 || *p == 0x7f) [out appendFormat:@"\\x%02x", *p];
                else                         [out appendFormat:@"%c", *p];
                break;
        }
    }
    return out;
}

static void logAppend(NSString *s) {
    if (!s) return;

    int fd = open(kLogPath, O_WRONLY | O_APPEND | O_CREAT, 0600);
    if (fd < 0) return;                 // logging must never fail a command

    char ts[32];
    logStamp(ts, sizeof ts);
    // s goes in as a %@ argument, never as part of the format, so a '%' in the data cannot be
    // reinterpreted as a conversion. The trailing newline is ours and is the only one in the line.
    NSString *line = [NSString stringWithFormat:@"%s [%d] %@\n", ts, getpid(), escapeForLog(s)];

    const char *bytes = line.UTF8String;
    if (bytes) {
        size_t left = strlen(bytes);
        // O_APPEND makes each write atomic against other writers, but a short write is still
        // possible, so finish the line rather than leaving it truncated mid-record.
        while (left) {
            ssize_t w = write(fd, bytes, left);
            if (w <= 0) break;
            bytes += w;
            left  -= (size_t)w;
        }
    }
    close(fd);
}

void logLine(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    logAppend(s);
}

void note(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    // Log first, and regardless of -q. Quiet suppresses the terminal, not the record: an
    // unattended run is the one whose history matters most.
    logAppend(s);
    if (!gQuiet) printf("%s\n", s.UTF8String);
}

void warnf(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    // Tagged so failures can be pulled out of a long file with one grep.
    logAppend([@"error: " stringByAppendingString:s]);
    fprintf(stderr, "%s\n", s.UTF8String ?: "(unrepresentable)");
}

void logBeginSession(int argc, char **argv) {
    NSMutableArray<NSString *> *args = [NSMutableArray array];
    for (int i = 0; i < argc; i++) [args addObject:@(argv[i] ?: "?")];

    logAppend(@"---- session start ----");
    logLine(@"argv: %@", [args componentsJoinedByString:@" "]);
    logLine(@"uid %d euid %d", getuid(), geteuid());
}

int logEndSession(int code) {
    logLine(@"exit %d", code);
    return code;
}
