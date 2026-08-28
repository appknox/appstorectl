// biometric — clear a biometric opt-in the device cannot honour.
//
// The failure this repairs
// ------------------------
// An account can be opted into biometric purchase authorization (`BiometricStateEnabled = 2`) while
// the device holds no enrolled identity for it — `identityMapCount 0`, `keyCount 0`,
// `isIdentityMapValidForAccountIdentifier:` NO. That happens when the passcode is removed, which
// wipes Secure Enclave enrolment, and then `+[ISBiometricStore shouldUseAutoEnrollment]` (URL-bag
// driven, server rollout) silently re-opts the account in on the next sign-in with nothing behind it.
//
// In that state the store expects an X-Apple-TID-* signature the device cannot produce, so
// `SSBiometricAuthenticationContext` sets `didFallbackToPassword` and the purchase comes back as
// `MZCommerce.ConfirmPaymentSheet.Auth`. Dismissing that sheet yields no credential, so the replay
// is rejected and `install` fails. Verified on 16.7.12; see the research archive
// docs/11-auth-expiry.md.
//
// Two things make this awkward, and both are load-bearing below
// -------------------------------------------------------------
// 1. There are TWO preference keys. `-[ISBiometricStore setBiometricState:]` writes `BiometricState`,
//    but `-isBiometricStateEnabled` reads `BiometricStateEnabled`, and nothing public writes that
//    one. Clearing only the first leaves the biometric branch armed — measured, not assumed.
//
// 2. They live in **mobile's** preferences domain. appstorectl runs as root, and as root the same
//    reads report `BiometricState 0` / `isBiometricStateEnabled NO` — a confident false clean bill
//    of health for a domain no daemon consults. So the work re-execs as uid 501.
//
// Scope: this only ever clears an opt-in that is already impossible to satisfy. It never enables
// biometric auth, and it does nothing at all when the identity map is valid.
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>

#import "appstorectl.h"
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

int cmdBiometricPreflight(void) {
    if (getuid() != kMobileUID) {
        fprintf(stderr, "_biometric-preflight must run as mobile (uid %d), not %d\n",
                kMobileUID, getuid());
        return 1;
    }
    if (!dlopen("/System/Library/PrivateFrameworks/iTunesStore.framework/iTunesStore", RTLD_NOW)) {
        return 0;   // nothing to repair if the framework will not load
    }
    dlopen("/System/Library/PrivateFrameworks/StoreServices.framework/StoreServices", RTLD_NOW);

    ISBiometricStore *bio = [NSClassFromString(@"ISBiometricStore") sharedInstance];
    if (!bio || ![bio isBiometricStateEnabled]) return 0;

    id rawID = [[NSClassFromString(@"SSAccountStore") defaultStore] activeAccount].uniqueIdentifier;
    NSString *accountID = [rawID isKindOfClass:NSString.class] ? rawID : [rawID description];
    if (!accountID.length) return 0;

    // Enabled AND satisfiable is a normal device. Leave it alone — the user gets a biometric prompt,
    // which is what they asked for by enrolling.
    if ([bio isIdentityMapValidForAccountIdentifier:accountID]) return 0;

    note(@"[!] biometric auth is enabled but has no enrolled identity "
         @"(identityMapCount %llu) — every purchase would fall back to a password prompt",
         (unsigned long long)[bio identityMapCount]);
    writeBiometricKeys(0);

    ISBiometricStore *after = [NSClassFromString(@"ISBiometricStore") sharedInstance];
    if ([after isBiometricStateEnabled]) {
        note(@"[-] could not clear it; the password prompt will probably still appear");
        return 1;
    }
    note(@"[+] cleared the unsatisfiable biometric opt-in");
    return 0;
}

#pragma mark - root side

void biometricPreflight(void) {
    if (getuid() == kMobileUID) { (void)cmdBiometricPreflight(); return; }
    if (getuid() != 0) return;   // cannot drop to mobile from an unprivileged uid

    char path[PATH_MAX] = {0};
    uint32_t size = sizeof path;
    if (_NSGetExecutablePath(path, &size) != 0) return;

    // fork+exec rather than fork+setuid alone: this process has already touched ObjC, XPC and
    // CoreFoundation, none of which survive a bare fork intact. Between fork and execv only
    // async-signal-safe calls happen.
    pid_t pid = fork();
    if (pid < 0) return;
    if (pid == 0) {
        if (setgid(kMobileUID) != 0 || setuid(kMobileUID) != 0) _exit(127);
        char *const args[] = { path, (char *)"_biometric-preflight", NULL };
        execv(path, args);
        _exit(127);
    }
    int status = 0;
    waitpid(pid, &status, 0);
}
