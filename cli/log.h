// log.h — terminal output and the persistent log. Everything that writes for a human lives here.
//
// Two separate channels, deliberately:
//
//   note()      what someone watching the run should see. Suppressed by -q.
//   logLine()   what someone debugging it six months later needs. Never suppressed.
//
// note() writes to both. logLine() writes only to the file, so detail that would be noise on a
// terminal (raw buyParameters, error chains, argv) can be recorded without cluttering the run.
#import <Foundation/Foundation.h>

#pragma mark - Terminal

/// Set by -q. Suppresses note()'s terminal output only; the log file is written either way.
extern BOOL gQuiet;

/// Print to stdout unless -q, and always append to the log.
void note(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

/// Print to stderr, always, and always append to the log tagged `error:`.
///
/// Use this instead of a bare fprintf(stderr, ...) for anything that reports a failure. A failure
/// that only ever reached the terminal is exactly the thing missing when someone asks why an
/// install six months ago did not work. Unlike note() it ignores -q: quiet means "no progress
/// chatter", not "hide errors".
///
/// Takes an NSString format, so `%@` works and `%s` needs a C string as usual.
void warnf(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

#pragma mark - Persistent log

/// `/var/jb/var/log/appstorectl.log`, appended, never truncated, stamped in device local time.
///
/// Under /var/jb/var/log rather than /var/jb/tmp because tmp is cleared and the point is that an
/// install from months ago is still explainable. Mode 0600: it carries DSIDs, purchase ids and raw
/// buyParameters.
///
/// Writes only to the file. Never fails a command: if the log cannot be opened it is skipped.
void logLine(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

/// Session banner: argv and uid, so concurrent or successive runs can be told apart in one file.
/// Call once from main, before anything else.
void logBeginSession(int argc, char **argv);

/// Record the exit status and return it, so call sites can write `return logEndSession(rc);`.
int logEndSession(int code);
