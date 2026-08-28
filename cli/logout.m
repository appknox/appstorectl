// logout.m — remove an Apple ID from the device.
//
// There is no UI equivalent. Settings > Media & Purchases shows only the *active* store account, so
// an account signed in by `appstorectl login` and left inactive is invisible there and can only be
// removed through this API.
//
// accountsd gates the removal in -[ACDAccountStoreFilter _isClientPermittedToRemoveAccount:]
// (0x1e9d7abd4 in AccountsDaemon). It allows a removal on any of: one type-independent entitlement,
// one of two type-specific ones, or the client owning the account. We do not own an account created
// through SSAuthenticateRequest, so the entitlement is required, and it was bisected on device to
// com.apple.private.accounts.allaccounts. Without it: com.apple.accounts code 7,
// "The application is not permitted to delete iTunes Store accounts".

#import "account.h"
#import "appstorectl.h"
#import "SSAuthPrivate.h"

int cmdLogout(NSString *appleID, BOOL force) {
    id store = accountStore();
    if (!store) return kAccountLoadFailed;

    SSAccount *account = findAccount(appleID);
    if (!account) {
        fprintf(stderr, "[-] no account matches %s\n", appleID.UTF8String);
        return kAccountNotFound;
    }

    // The local pseudo-account is device state, not a sign-in. Removing it is never what anyone
    // means, so this is not overridable.
    if (account.isLocalAccount) {
        fprintf(stderr, "[-] %s is the local pseudo-account, not a signed-in Apple ID\n",
                appleID.UTF8String);
        return kAccountRefused;
    }
    if (account.isActive && !force) {
        fprintf(stderr, "[-] %s is the active account, the one this device buys with.\n"
                        "    Pass --force if that is really what you want.\n", appleID.UTF8String);
        return kAccountRefused;
    }

    note(@"[*] removing %@ ...", account.accountName);

    __block BOOL replied = NO, removed = NO;
    __block NSError *failure = nil;
    [store removeAccount:account completion:^(BOOL ok, NSError *e) {
        removed = ok;
        failure = e;
        replied = YES;
    }];

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:30];
    while (!replied && [deadline timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];

    if (!replied) {
        fprintf(stderr, "[-] timed out after 30s waiting for the removal to complete\n");
        return kAccountTimedOut;
    }
    if (!removed) {
        fprintf(stderr, "[-] removal failed: %s %ld\n",
                failure.domain.UTF8String ?: "unknown", (long)failure.code);
        if (failure.localizedDescription.length)
            fprintf(stderr, "  %s\n", failure.localizedDescription.UTF8String);
        return kAccountRemoveFailed;
    }

    // The completion fires before accountsd's accounts-changed notification is delivered, so a
    // read taken right now still sees the cached account. waitForAccount spins the runloop, which
    // is what delivers it.
    if (waitForAccount(appleID, NO, 5.0)) {
        fprintf(stderr, "[-] removal reported success but %s is still present\n", appleID.UTF8String);
        return kAccountUnverified;
    }

    note(@"[+] removed %@", appleID);
    return kAccountOK;
}
