// login.m — sign an Apple ID in to the iTunes Store, headlessly.
//
// The store consumes exactly two credential types, from
// +[SSAuthenticateRequest _accountToAuthenticateWithAuthenticationContext:] at 0x1a1a328d0:
//
//     context.password                -> [account setRawPassword:]
//     context.passwordEquivalentToken -> [account setPasswordEquivalentToken:]
//
// and nothing else crosses over. A password is the only one a caller can supply: a store PET is an
// ACAccountCredential item on the account, and the alternate-account lookup that would fetch one
// (_passwordEquivalentTokenFromAlternateAccountWithAltDSID:DSID:username:) is `MOV X0,#0 ; RET` on
// iOS. Handing it anything else, a GrandSlam token included, gets SSServerErrorDomain -5000.

#import <unistd.h>
#import <pwd.h>          // _PASSWORD_LEN, the size of getpass()'s static buffer
#import <string.h>
#import "account.h"
#import "appstorectl.h"
#import "SSAuthPrivate.h"

/// Read a line from the terminal with echo left ON, so the typist can see exactly what went in.
/// Only reachable via --show-password. Worth having: a wrong credential and a mis-read one produce
/// the same server error, and with a hidden prompt there is no way to tell them apart.
static NSString *readVisibleLine(void) {
    fprintf(stderr, "Apple ID password (visible): ");
    char buf[512];
    if (!fgets(buf, sizeof buf, stdin)) return nil;
    buf[strcspn(buf, "\r\n")] = '\0';
    return buf[0] ? @(buf) : nil;
}

/// In order: an explicit file, the environment, then a terminal prompt. Never argv, which ps shows
/// to every process on the device.
static NSString *readPassword(NSString *passwordFile, BOOL visible) {
    if (passwordFile.length) {
        NSError *err = nil;
        NSString *pw = [NSString stringWithContentsOfFile:passwordFile
                                                 encoding:NSUTF8StringEncoding
                                                    error:&err];
        pw = [pw stringByTrimmingCharactersInSet:
                  [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!pw.length) {
            fprintf(stderr, "[-] password file %s unreadable or empty: %s\n",
                    passwordFile.UTF8String,
                    err ? err.localizedDescription.UTF8String : "no content");
            return nil;
        }
        return pw;
    }

    const char *env = getenv("APPSTORECTL_PASSWORD");
    if (env && *env) return @(env);

    if (!isatty(STDIN_FILENO)) return nil;
    if (visible) return readVisibleLine();
    // getpass() truncates silently at _PASSWORD_LEN, so a long password can be read wrong with no
    // sign it happened.
    const char *typed = getpass("Apple ID password: ");
    if (!typed || !*typed) return nil;
    if (strlen(typed) >= _PASSWORD_LEN - 1)
        fprintf(stderr, "[-] password is %zu chars, at getpass()'s limit of %d. "
                        "It may have been truncated; use --password-file instead.\n",
                strlen(typed), _PASSWORD_LEN);
    return @(typed);
}

static const char *responseTypeName(SSAuthenticateResponseType t) {
    switch (t) {
        case SSAuthenticateResponseTypeFailed:      return "authentication failed";
        case SSAuthenticateResponseTypeRejected:    return "the server rejected the credentials";
        case SSAuthenticateResponseTypeCancelled:   return "cancelled";
        case SSAuthenticateResponseTypeNeedsReview: return "this account needs review by Apple";
        case SSAuthenticateResponseTypeSucceeded:   return "succeeded";
    }
    return "unknown";
}

static SSMutableAuthenticationContext *buildContext(NSString *appleID, NSString *password) {
    Class mutableCtx = NSClassFromString(@"SSMutableAuthenticationContext");
    Class baseCtx    = NSClassFromString(@"SSAuthenticationContext");
    if (!mutableCtx) return nil;

    SSMutableAuthenticationContext *ctx = nil;
    if ([baseCtx respondsToSelector:@selector(contextForSignIn)])
        ctx = [[baseCtx contextForSignIn] mutableCopy];
    if (!ctx) ctx = [[mutableCtx alloc] init];

    ctx.accountName     = appleID;
    ctx.password        = password;
    ctx.initialPassword = password;
    // 1 = authenticate unconditionally. At the default of 0 the request can report success without
    // contacting anyone. See the promptStyle table in SSAuthPrivate.h.
    ctx.promptStyle                = 1;
    ctx.canSetActiveAccount        = YES;
    ctx.canCreateNewAccount        = YES;
    ctx.allowsSilentAuthentication = YES;
    ctx.allowsRetry                = NO;
    ctx.shouldSuppressDialogs      = NO;
    ctx.shouldCreateNewSession     = YES;
    // altDSID stays nil on purpose. See cmdLogin() in account.h.
    return ctx;
}

/// One attempt at the store path, so cmdLogin can run it again after a two-factor bootstrap.
///
/// Pass `printFailure` NO when a bootstrap will follow: a -5000 there is expected rather than a
/// failure to report. The error comes back through `outError` for the case where it turns out to be
/// the real answer after all.
static int attemptStoreLogin(NSString *appleID, NSString *password, Class requestClass,
                             BOOL printFailure, NSError **outError) {
    SSMutableAuthenticationContext *ctx = buildContext(appleID, password);
    if (!ctx) { fprintf(stderr, "[-] could not build an authentication context\n"); return kAccountLoadFailed; }

    SSAuthenticateRequest *request = [[requestClass alloc] initWithAuthenticationContext:ctx];
    if (!request) { fprintf(stderr, "[-] could not build an authenticate request\n"); return kAccountLoadFailed; }

    __block BOOL replied = NO;
    __block SSAuthenticateResponseType type = SSAuthenticateResponseTypeFailed;
    __block NSError *failure = nil;
    // Read inside the block. The response is autoreleased, so a captured pointer examined after the
    // runloop returns is freed memory that reads back with a zero isa.
    [request startWithAuthenticateResponseBlock:^(SSAuthenticateResponse *r, NSError *e) {
        type    = r.authenticateResponseType;
        failure = r.error ?: e;
        replied = YES;
    }];

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:300];
    while (!replied && [deadline timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];

    if (!replied) {
        fprintf(stderr, "[-] timed out after 300s waiting for the store to reply\n");
        return kAccountTimedOut;
    }
    if (type != SSAuthenticateResponseTypeSucceeded) {
        if (outError) *outError = failure;
        if (printFailure) {
            fprintf(stderr, "[-] login failed: %s\n", responseTypeName(type));
            printErrorChain(failure, 0);
        }
        return (type == SSAuthenticateResponseTypeRejected) ? kAccountRejected : kAccountAuthFailed;
    }

    // A reported success is not enough. When the promptStyle gate declines,
    // startWithAuthenticateResponseBlock: still returns "succeeded" having contacted nobody, so
    // confirm against the store itself.
    SSAccount *account = waitForAccount(appleID, YES, 5.0);
    if (!account || !account.isAuthenticated) {
        fprintf(stderr, "[-] login reported success but %s is %s\n", appleID.UTF8String,
                account ? "not authenticated" : "absent from the account store");
        return kAccountUnverified;
    }

    note(@"[+] signed in %@  storefront %@", account.accountName, account.storeFrontIdentifier);
    return kAccountOK;
}

int cmdLogin(NSString *appleID, NSString *passwordFile, BOOL showPassword, BOOL allowBootstrap) {
    if (!accountStore()) return kAccountLoadFailed;

    Class requestClass = NSClassFromString(@"SSAuthenticateRequest");
    if (!requestClass) {
        fprintf(stderr, "[-] SSAuthenticateRequest unavailable\n");
        return kAccountLoadFailed;
    }
    // Without this the request is shipped to itunesstored instead of running in process. Read
    // rather than assumed: a stale cached code signature silently ships the old entitlement set.
    if ([requestClass respondsToSelector:@selector(_isAuthkitEntitled)] &&
        ![requestClass _isAuthkitEntitled])
        fprintf(stderr, "[-] not AuthKit-entitled; the two-factor bootstrap will not work\n");

    NSString *source = passwordFile.length ? @"file"
                     : (getenv("APPSTORECTL_PASSWORD") ? @"environment" : @"prompt");
    NSString *password = readPassword(passwordFile, showPassword);
    if (!password) {
        fprintf(stderr, "[-] no password: pass --password-file, set $APPSTORECTL_PASSWORD, "
                        "or run on a terminal\n");
        return kAccountNoPassword;
    }
    // Length only, never the password. Tells a bad credential apart from a mis-read one.
    note(@"[*] password: %lu characters, from %@", (unsigned long)password.length, source);

    // Nothing exposes whether this device already trusts this Apple ID; asking the store is the
    // test. So try it first and treat -5000 as "not trusted yet" rather than as an error.
    BOOL canBootstrap = allowBootstrap && isatty(STDIN_FILENO);

    note(@"[*] signing in %@ ...", appleID);
    NSError *firstFailure = nil;
    int rc = attemptStoreLogin(appleID, password, requestClass, !canBootstrap, &firstFailure);
    if (rc != kAccountRejected || !canBootstrap) {
        // "The server rejected the credentials" reads as a wrong password and usually is not one.
        if (rc == kAccountRejected && allowBootstrap && !isatty(STDIN_FILENO))
            fprintf(stderr, "[-] this device has no two-factor trust for %s yet, and there is no\n"
                            "    terminal to type a verification code on. Run this once interactively.\n",
                    appleID.UTF8String);
        return rc;
    }

    // -5000 does not mean the password is wrong. It means this device holds no two-factor-
    // established trust for this Apple ID, and the store will keep saying it until an interactive
    // verification code fixes it. See AKPrivate.h for the measurements.
    int bootstrap = authkitBootstrap(appleID, password);
    if (bootstrap != kAccountOK) {
        // A wrong password, or a sign-in that was never challenged, already explain the rejection.
        // Replaying the -5000 underneath them makes one failure look like two.
        if (bootstrap != kAccountBadPassword && bootstrap != kAccountNotChallenged) {
            fprintf(stderr, "[-] the store also rejected the credentials:\n");
            printErrorChain(firstFailure, 2);
        }
        if (bootstrap == kAccountNotChallenged)
            fprintf(stderr, "[-] so this device still has no trust for %s, and the store will\n"
                            "    keep refusing it.\n", appleID.UTF8String);
        return bootstrap;
    }

    note(@"[*] retrying the store sign-in ...");
    return attemptStoreLogin(appleID, password, requestClass, YES, NULL);
}
