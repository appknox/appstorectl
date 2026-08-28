// Clear a biometric purchase opt-in only when the account has no valid enrolled identity.
// `setBiometricState:` changes `BiometricState`, while the effective gate also reads
// `BiometricStateEnabled`, so both keys must be cleared. The preference domain belongs to mobile;
// root sees a different view, which is why the operation re-execs as uid 501. A valid identity is
// left untouched. Verified on iOS 16.7.12; see docs/GATES.md.
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <errno.h>
#import <mach-o/dyld.h>
#import <spawn.h>
#import <string.h>
#import <sys/wait.h>
#import <unistd.h>

#import "appstorectl.h"
#import "log.h"
#import "biometric.h"

static const uid_t kMobileUID = 501;
static NSString *const kStoreDomain = @"com.apple.itunesstored";

@interface ISBiometricStore : NSObject
+ (instancetype)sharedInstance;
- (long long)biometricState;
- (BOOL)isBiometricStateEnabled;
- (void)setBiometricState:(long long)state;
- (unsigned long long)identityMapCount;
- (BOOL)isIdentityMapValidForAccountIdentifier:(NSString *)accountID;
@end

@interface SSAccount : NSObject
// id, not NSString: this is an NSNumber on 16.7 and -length on it is an immediate crash.
@property (readonly) id uniqueIdentifier;
@end

@interface SSAccountStore : NSObject
+ (instancetype)defaultStore;
- (SSAccount *)activeAccount;
@end

#pragma mark - mobile side

static void writeBiometricKeys(long long value) {
    ISBiometricStore *bio = [NSClassFromString(@"ISBiometricStore") sharedInstance];
    [bio setBiometricState:value];   // writes BiometricState only
    CFPreferencesSetValue(CFSTR("BiometricStateEnabled"),
                          (__bridge CFNumberRef)@(value),
                          (__bridge CFStringRef)kStoreDomain,
                          kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kStoreDomain);
}

// NOTE ON LOGGING HERE: this half runs as mobile (uid 501) and the log is root-owned 0600, so
// logLine() from this process is silently dropped. That is deliberate -- the file holds DSIDs and
// buyParameters and should not be mobile-readable. The parent logs the spawn and the exit status
// instead, and these lines are kept because the same function also runs in-process when appstorectl
// itself is invoked as mobile.
//
// Every early return below is a "nothing to do" that is indistinguishable from the others at the
// call site, which is why each one says which check stopped it.
int cmdBiometricPreflight(void) {
    logLine(@"preflight: begin uid=%d", getuid());

    if (getuid() != kMobileUID) {
        warnf(@"_biometric-preflight must run as mobile (uid %d), not %d", kMobileUID, getuid());
        return 1;
    }
    if (!dlopen("/System/Library/PrivateFrameworks/iTunesStore.framework/iTunesStore", RTLD_NOW)) {
        logLine(@"preflight: skip, iTunesStore will not load: %s", dlerror());
        return 0;   // nothing to repair if the framework will not load
    }
    dlopen("/System/Library/PrivateFrameworks/StoreServices.framework/StoreServices", RTLD_NOW);

    ISBiometricStore *bio = [NSClassFromString(@"ISBiometricStore") sharedInstance];
    if (!bio) { logLine(@"preflight: skip, no ISBiometricStore"); return 0; }

    BOOL enabled = [bio isBiometricStateEnabled];
    logLine(@"preflight: biometricState=%lld enabled=%d identityMapCount=%llu",
            [bio biometricState], enabled, (unsigned long long)[bio identityMapCount]);
    if (!enabled) { logLine(@"preflight: skip, biometric not enabled"); return 0; }

    id rawID = [[NSClassFromString(@"SSAccountStore") defaultStore] activeAccount].uniqueIdentifier;
    NSString *accountID = [rawID isKindOfClass:NSString.class] ? rawID : [rawID description];
    if (!accountID.length) {
        logLine(@"preflight: skip, no active account identifier");
        return 0;
    }

    // Enabled AND satisfiable is a normal device. Leave it alone — the user gets a biometric prompt,
    // which is what they asked for by enrolling.
    BOOL valid = [bio isIdentityMapValidForAccountIdentifier:accountID];
    logLine(@"preflight: account=%@ identityMapValid=%d", accountID, valid);
    if (valid) { logLine(@"preflight: skip, opt-in is satisfiable"); return 0; }

    note(@"[!] biometric auth is enabled but has no enrolled identity "
         @"(identityMapCount %llu) — every purchase would fall back to a password prompt",
         (unsigned long long)[bio identityMapCount]);

    logLine(@"preflight: clearing BiometricState and BiometricStateEnabled");
    writeBiometricKeys(0);

    ISBiometricStore *after = [NSClassFromString(@"ISBiometricStore") sharedInstance];
    BOOL stillOn = [after isBiometricStateEnabled];
    logLine(@"preflight: after write, biometricState=%lld enabled=%d",
            [after biometricState], stillOn);
    if (stillOn) {
        note(@"[-] could not clear it; the password prompt will probably still appear");
        return 1;
    }
    note(@"[+] cleared the unsatisfiable biometric opt-in");
    return 0;
}

#pragma mark - root side

void biometricPreflight(void) {
    if (getuid() == kMobileUID) { (void)cmdBiometricPreflight(); return; }
    if (getuid() != 0) {
        logLine(@"preflight: skip, uid %d can neither read mobile's prefs nor drop to them",
                getuid());
        return;   // cannot drop to mobile from an unprivileged uid
    }

    char path[PATH_MAX] = {0};
    uint32_t size = sizeof path;
    if (_NSGetExecutablePath(path, &size) != 0) {
        logLine(@"preflight: skip, _NSGetExecutablePath failed");
        return;
    }

    // fork+exec rather than fork+setuid alone: this process has already touched ObjC, XPC and
    // CoreFoundation, none of which survive a bare fork intact. Between fork and execv only
    // async-signal-safe calls happen.
    logLine(@"preflight: re-exec as uid %d: %s _biometric-preflight", kMobileUID, path);

    pid_t pid = fork();
    if (pid < 0) { logLine(@"preflight: fork failed: %s", strerror(errno)); return; }
    if (pid == 0) {
        if (setgid(kMobileUID) != 0 || setuid(kMobileUID) != 0) _exit(127);
        char *const args[] = { path, (char *)"_biometric-preflight", NULL };
        execv(path, args);
        _exit(127);
    }
    int status = 0;
    waitpid(pid, &status, 0);

    // The child cannot write this log (root-owned 0600), so its outcome is only on the record here.
    if (WIFSIGNALED(status))
        logLine(@"preflight: child pid %d killed by signal %d", pid, WTERMSIG(status));
    else
        logLine(@"preflight: child pid %d exited %d%s", pid, WEXITSTATUS(status),
                WEXITSTATUS(status) == 127 ? "  (setuid or execv failed)" : "");
}
