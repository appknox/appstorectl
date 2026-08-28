// authpref — read (and optionally change) the Apple ID's purchase password settings.
//
//   authpref                 show current settings
//   authpref free never      stop requiring a password for FREE downloads
//   authpref free always
//
// This is the same account-level setting as Settings -> Media & Purchases -> Password Settings.
// It lives on the Apple ID, not the device, so changing it syncs to Apple.
// Values: 1 = always, 2 = sometimes, 3 = never  (0 = unset)
#import <Foundation/Foundation.h>
#import <dlfcn.h>

#import "ASDPrivate.h"

static const char *name(long long v) {
    switch (v) { case 1: return "always"; case 2: return "sometimes"; case 3: return "never"; }
    return "unset";
}
static long long value(const char *s) {
    if (!strcmp(s, "always"))    return 1;
    if (!strcmp(s, "sometimes")) return 2;
    if (!strcmp(s, "never"))     return 3;
    return -1;
}

int main(int argc, char **argv) {
    setbuf(stdout, NULL);
    @autoreleasepool {
        dlopen("/System/Library/PrivateFrameworks/StoreServices.framework/StoreServices", RTLD_NOW);

        id store = [NSClassFromString(@"SSAccountStore") defaultStore];
        SSAccount *acct = [store activeAccount];
        if (!acct) { fprintf(stderr, "no active iTunes account\n"); return 3; }

        printf("account        : %s (dsid %s)\n",
               acct.accountName.UTF8String ?: "?",
               acct.uniqueIdentifier.stringValue.UTF8String ?: "?");
        printf("free downloads : %s (%lld)\n", name(acct.freeDownloadsPasswordSetting),
               acct.freeDownloadsPasswordSetting);
        printf("paid purchases : %s (%lld)\n", name(acct.paidPurchasesPasswordSetting),
               acct.paidPurchasesPasswordSetting);

        if (argc < 3) return 0;

        BOOL isFree = !strcmp(argv[1], "free");
        BOOL isPaid = !strcmp(argv[1], "paid");
        long long v  = value(argv[2]);
        if ((!isFree && !isPaid) || v < 0) {
            fprintf(stderr, "usage: authpref [free|paid] [always|sometimes|never]\n");
            return 64;
        }

        if (isFree) acct.freeDownloadsPasswordSetting = v;
        else        acct.paidPurchasesPasswordSetting = v;
        printf("\n[+] setting %s -> %s, pushing to the account...\n", argv[1], argv[2]);

        // The reply block's arity is undocumented, and probing unknown argument slots can fault.
        // Ignore the arguments and verify the result by re-reading the account store.
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [acct updateAccountPasswordSettingsWithRequestProperties:nil completionBlock:^{
            dispatch_semaphore_signal(sem);
        }];
        if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 60ull*NSEC_PER_SEC))) {
            printf("[-] timed out waiting for the store\n");
            return 4;
        }

        // Verify by re-reading, because the reply block cannot be safely parsed. Two traps here:
        //
        //   1. `activeAccount` hands back a CACHED SSAccount. Reading it after the write reports
        //      the OLD value even though the write succeeded — a separate process sees the new one.
        //      accountWithUniqueIdentifier:reloadIfNecessary:YES forces a refresh.
        //   2. The write is a round trip to Apple, so the refreshed value can lag the reply by a
        //      moment. Poll briefly rather than judging on the first read.
        NSNumber *dsid = acct.uniqueIdentifier;

        long long now = -1;
        BOOL ok = NO;
        for (int attempt = 0; attempt < 10 && !ok; attempt++) {
            // Must be runUntilDate:, NOT [NSThread sleepForTimeInterval:]. itunesstored invalidates
            // the account cache by posting com.apple.itunesstored.accountschanged, and Darwin
            // notification callbacks are only delivered on a runloop turn. Sleeping blocks the
            // thread without servicing the runloop, so the invalidation never arrives and every
            // re-read — reloadIfNecessary: included — hands back the same stale object forever.
            if (attempt) {
                [[NSRunLoop currentRunLoop]
                    runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
            }

            SSAccount *fresh = [store accountWithUniqueIdentifier:dsid reloadIfNecessary:YES];
            if (!fresh) fresh = [store activeAccount];

            now = isFree ? fresh.freeDownloadsPasswordSetting
                         : fresh.paidPurchasesPasswordSetting;
            ok = (now == v);
        }

        if (ok) {
            printf("[+] %s is now %s (%lld)\n", argv[1], name(now), now);
            return 0;
        }
        // The store refuses some transitions outright — `paid never` is rejected and the setting
        // stays put. Say what it actually is rather than implying the tool failed.
        printf("[-] %s is still %s (%lld) — the store did not accept %s\n",
               argv[1], name(now), now, argv[2]);
        return 1;
    }
}
