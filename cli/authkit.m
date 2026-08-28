// authkit.m — the one-off interactive step that gives a device two-factor trust for an Apple ID.
//
// Run automatically by `login` when the store answers -5000 and there is a terminal to type on.
// See AKPrivate.h for why the store path cannot do this itself.

#import <dlfcn.h>
#import <unistd.h>
#import "account.h"
#import "appstorectl.h"
#import "AKPrivate.h"

int authkitBootstrap(NSString *appleID, NSString *password) {
    // AuthKit reads the code from stdin. With no terminal the run would block until the 300s
    // timeout and look like a hang, so refuse up front.
    if (!isatty(STDIN_FILENO)) {
        fprintf(stderr,
            "[-] two-factor bootstrap needs a terminal: AuthKit reads the code from stdin.\n"
            "    Run this once interactively for %s, then unattended logins work.\n",
            appleID.UTF8String);
        return kAccountNeedsTerminal;
    }

    if (!dlopen("/System/Library/PrivateFrameworks/AuthKit.framework/AuthKit", RTLD_NOW)) {
        fprintf(stderr, "[-] dlopen AuthKit failed: %s\n", dlerror());
        return kAccountLoadFailed;
    }
    Class contextClass    = NSClassFromString(@"AKAppleIDAuthenticationCommandLineContext");
    Class controllerClass = NSClassFromString(@"AKAppleIDAuthenticationController");
    if (!contextClass || !controllerClass) {
        fprintf(stderr, "[-] AuthKit command-line classes unavailable\n");
        return kAccountLoadFailed;
    }

    AKAppleIDAuthenticationCommandLineContext *ctx = [[contextClass alloc] init];
    [ctx setUsername:appleID];
    [ctx _setPassword:password];
    if ([ctx respondsToSelector:@selector(setReason:)])
        [ctx setReason:@"appstorectl sign-in"];

    // Conditional wording on purpose: with a wrong password Apple rejects it and no code is sent.
    fprintf(stderr, "[*] %s is not trusted on this device yet.\n"
                    "    If the password is correct, Apple will send a verification code to the\n"
                    "    account's trusted devices and ask for it below.\n",
            appleID.UTF8String);

    AKAppleIDAuthenticationController *controller = [[controllerClass alloc] init];
    __block BOOL replied = NO, challenged = NO, succeeded = NO;
    __block NSError *failure = nil;
    __block NSString *dsid = nil;

    // Read everything inside the block. The results dictionary is autoreleased and examining the
    // captured pointer after the runloop returns gives freed memory.
    [controller authenticateWithContext:ctx completion:^(NSDictionary *results, NSError *error) {
        succeeded  = (results != nil && error == nil);
        challenged = [results[kAKDidShowServerUI] boolValue];
        dsid       = [results[kAKDSID] description];
        failure    = error;
        replied    = YES;
    }];

    // Long timeout on purpose: a human has to read a code off another device and type it.
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:300];
    while (!replied && [deadline timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];

    if (!replied) {
        fprintf(stderr, "[-] timed out after 300s waiting for the two-factor flow\n");
        return kAccountTimedOut;
    }
    if (!succeeded) {
        fprintf(stderr, "[-] two-factor sign-in failed\n");
        printErrorChain(failure, 0);
        // -7006 is AuthKit's wrong-password error. Classified only so the caller can suppress the
        // store's redundant -5000; it never changes what is printed.
        BOOL badPassword = [failure.domain isEqualToString:@"AKAuthenticationError"] &&
                           failure.code == -7006;
        return badPassword ? kAccountBadPassword : kAccountAuthFailed;
    }

    // AuthKit answers from cached device identity for an Apple ID the device already knows: real
    // credentials, no challenge, no store trust. Calling that success loops the caller forever.
    if (!challenged) {
        fprintf(stderr, "[-] AuthKit signed in (DSID %s) but was NOT challenged for a code.\n"
                        "    That answers from identity this device already had, and establishes\n"
                        "    no store trust.\n", dsid.UTF8String ?: "?");
        return kAccountNotChallenged;
    }

    note(@"[+] two-factor trust established for %@ (DSID %@)", appleID, dsid ?: @"?");
    return kAccountOK;
}
