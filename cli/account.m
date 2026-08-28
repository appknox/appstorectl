// account.m — shared account plumbing and the read-only `accounts` command. Sign-in lives in
// login.m, removal in logout.m.

#import <dlfcn.h>
#import "account.h"
#import "appstorectl.h"
#import "SSAuthPrivate.h"

id accountStore(void) {
    // StoreServices is not linked, and is not the framework appstorectl.m already loads. Loading
    // it here keeps the purchase path free of a dependency it never uses.
    if (!dlopen("/System/Library/PrivateFrameworks/StoreServices.framework/StoreServices",
                RTLD_NOW)) {
        fprintf(stderr, "[-] dlopen StoreServices failed: %s\n", dlerror());
        return nil;
    }
    Class store = NSClassFromString(@"SSAccountStore");
    if (!store) {
        fprintf(stderr, "[-] SSAccountStore unavailable\n");
        return nil;
    }
    return [store defaultStore];
}

static NSArray<SSAccount *> *liveAccounts(void) {
    id store = accountStore();
    if (!store) return nil;
    [store reloadAccounts];
    return [store accounts];
}

SSAccount *findAccount(NSString *appleID) {
    for (SSAccount *a in liveAccounts()) {
        NSString *name = a.accountName;
        if ([name isKindOfClass:[NSString class]] &&
            [name caseInsensitiveCompare:appleID] == NSOrderedSame) return a;
    }
    return nil;
}

SSAccount *waitForAccount(NSString *appleID, BOOL wantPresent, NSTimeInterval timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    SSAccount *found = nil;
    do {
        found = findAccount(appleID);
        if ((found != nil) == wantPresent) return found;
        // runUntilDate:, never sleep. Sleeping blocks the thread the accounts-changed Darwin
        // notification needs to be delivered on, so the cache never invalidates and every re-read
        // returns the same stale answer forever.
        [[NSRunLoop currentRunLoop]
            runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
    } while ([deadline timeIntervalSinceNow] > 0);
    return findAccount(appleID);
}

void printAccountTable(NSString *heading) {
    NSArray<SSAccount *> *accounts = liveAccounts();
    if (!accounts) return;
    if (heading.length) note(@"%@", heading);
    for (SSAccount *a in accounts)
        note(@"  %-34s %-14s %-6s %s",
             a.accountName.UTF8String,
             a.storeFrontIdentifier.UTF8String ?: "-",
             a.isAuthenticated ? "signed" : "out",
             a.isActive ? "active" : "");
}

void printErrorChain(NSError *e, int depth) {
    if (!e) return;
    NSString *pad = [@"" stringByPaddingToLength:(NSUInteger)(depth * 2)
                                      withString:@" " startingAtIndex:0];
    fprintf(stderr, "    %s%s %ld\n", pad.UTF8String, e.domain.UTF8String, (long)e.code);
    for (NSString *k in e.userInfo) {
        if ([k isEqualToString:NSUnderlyingErrorKey]) continue;
        fprintf(stderr, "      %s%s = %s\n", pad.UTF8String, k.UTF8String,
                [[e.userInfo[k] description] UTF8String]);
    }
    id under = e.userInfo[NSUnderlyingErrorKey];
    if ([under isKindOfClass:[NSError class]]) printErrorChain(under, depth + 2);
}

int cmdAccounts(void) {
    NSArray<SSAccount *> *accounts = liveAccounts();
    if (!accounts) return kAccountLoadFailed;

    note(@"%-34s %-14s %-6s %s", "APPLE ID", "STOREFRONT", "STATE", "");
    for (SSAccount *a in accounts)
        note(@"%-34s %-14s %-6s %s",
             a.accountName.UTF8String,
             a.storeFrontIdentifier.UTF8String ?: "-",
             a.isAuthenticated ? "signed" : "out",
             a.isActive ? "active" : "");
    return kAccountOK;
}
