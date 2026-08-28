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
#import "log.h"
#import "SSAuthPrivate.h"

int cmdLogout(NSString *appleID, BOOL force) {
    logLine(@"logout: begin target=%@ force=%d", appleID, force);

    id store = accountStore();
    if (!store) return kAccountLoadFailed;

    SSAccount *account = findAccount(appleID);
    if (!account) {
        warnf(@"[-] no account matches %@", appleID);
        return kAccountNotFound;
    }
    // findAccount matches case-insensitively while Apple's own lookup does not, so record what was
    // asked for next to what was found. They are not always the same string.
    logLine(@"logout: matched %@ dsid=%@ active=%d local=%d",
            account.accountName, account.uniqueIdentifier,
            account.isActive, account.isLocalAccount);

    // The local pseudo-account is device state, not a sign-in. Removing it is never what anyone
    // means, so this is not overridable.
    if (account.isLocalAccount) {
        warnf(@"[-] %@ is the local pseudo-account, not a signed-in Apple ID", appleID);
        return kAccountRefused;
    }
    if (account.isActive && !force) {
        warnf(@"[-] %@ is the active account, the one this device buys with.\n"
               "    Pass --force if that is really what you want.", appleID);
        return kAccountRefused;
    }
    if (account.isActive)
        logLine(@"logout: removing the ACTIVE account, --force given");

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
        warnf(@"[-] timed out after 30s waiting for the removal to complete");
        return kAccountTimedOut;
    }

    logLine(@"logout: removeAccount replied ok=%d error=%@ %ld",
            removed, failure.domain ?: @"(none)", (long)failure.code);

    if (!removed) {
        // code 7 here is ACErrorPermissionDenied, i.e. the allaccounts entitlement did not apply.
        warnf(@"[-] removal failed: %@ %ld", failure.domain ?: @"unknown", (long)failure.code);
        if (failure.localizedDescription.length)
            warnf(@"  %@", failure.localizedDescription);
        printErrorChain(failure, 1);
        return kAccountRemoveFailed;
    }

    // The completion fires before accountsd's accounts-changed notification is delivered, so a
    // read taken right now still sees the cached account. waitForAccount spins the runloop, which
    // is what delivers it.
    if (waitForAccount(appleID, NO, 5.0)) {
        warnf(@"[-] removal reported success but %@ is still present", appleID);
        return kAccountUnverified;
    }
    logLine(@"logout: verified absent from the account store");

    note(@"[+] removed %@", appleID);
    return kAccountOK;
}
