// storefront.m — see storefront.h.
#import <Foundation/Foundation.h>

#import "AMSPrivate.h"
#import "storefront.h"
#import "../log.h"

/// Accounts.framework plus the AMSCore additions. Declared rather than imported so nothing links
/// Accounts; the classes resolve by name once AppleMediaServices is loaded.
@interface ACAccountType : NSObject
@property (readonly) NSString *identifier;
@end

@interface ACAccount : NSObject
@property (readonly) ACAccountType *accountType;
@property (readonly) NSString *identifier;
@property (readonly) NSString *username;
@property (readonly, getter=isActive) BOOL active;
- (BOOL)ams_isLocalAccount;
- (NSString *)ams_storefront;
- (void)ams_setStorefront:(NSString *)storefront;
@end

@interface ACAccountStore : NSObject
+ (instancetype)ams_sharedAccountStore;
- (NSArray<ACAccount *> *)accounts;
- (AMSPromise *)ams_saveAccount:(ACAccount *)account verifyCredentials:(BOOL)verify;
@end

NSArray<NSString *> *accountStorefronts(void) {
    Class storeClass = NSClassFromString(@"ACAccountStore");
    if (!storeClass) return @[];

    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (ACAccount *account in ((ACAccountStore *)[(id)storeClass ams_sharedAccountStore]).accounts) {
        if (![account.accountType.identifier isEqualToString:@"com.apple.account.iTunesStore"])
            continue;
        [out addObject:[NSString stringWithFormat:@"%@ = %@%@%@",
            account.username ?: @"(local)",
            account.ams_storefront ?: @"(unset)",
            account.isActive ? @"  active" : @"",
            account.ams_isLocalAccount ? @"  local" : @""]];
    }
    return out;
}

BOOL setAccountStorefront(NSString *storefront, NSError **outError) {
    Class storeClass = NSClassFromString(@"ACAccountStore");
    if (!storeClass) {
        if (outError) *outError = [NSError errorWithDomain:@"appstorectl" code:1 userInfo:@{
            NSLocalizedDescriptionKey: @"Accounts / AppleMediaServices unavailable"}];
        return NO;
    }

    ACAccountStore *store = [(id)storeClass ams_sharedAccountStore];
    NSUInteger changed = 0;

    // asclient's filter, verbatim: iTunes store accounts only, and only ones that are the active
    // account or a local one. A signed-in but inactive account is deliberately left alone.
    for (ACAccount *account in store.accounts) {
        if (![account.accountType.identifier isEqualToString:@"com.apple.account.iTunesStore"])
            continue;
        if (!(account.ams_isLocalAccount || account.isActive)) continue;

        NSString *before = account.ams_storefront;

        // Compare the front only. A stored value reads "143441-1,29" — the front plus a platform
        // suffix the system appends on the next store call, not something we write. Setting
        // "143441" over "143441-1,29" is a no-op in effect, and doing it anyway makes the value
        // briefly suffixless and the report claim a change that is not one.
        if (before.intValue && before.intValue == storefront.intValue) {
            note(@"[=] %@: already on storefront %d", account.username ?: @"(local)", before.intValue);
            continue;
        }

        [account ams_setStorefront:storefront];

        NSError *saveError = nil;
        // resultWithError: rather than addSuccessBlock:/addErrorBlock: — same promise, and it
        // avoids declaring two more private block signatures for no gain. See ASDPrivate.h on why
        // guessing one is a SIGBUS rather than an error.
        [[store ams_saveAccount:account verifyCredentials:NO] resultWithError:&saveError];
        if (saveError) {
            if (outError) *outError = saveError;
            return NO;
        }

        // Re-read from a FRESH account object, not the one just mutated. The mutated instance
        // reports the value it was handed whether or not the save persisted it, which is how the
        // first version of this reported a change that never happened.
        // Match on identifier, not username: the local account has no username, and matching on a
        // nil username matched every other account without one, so the value reported for it was
        // whichever came last.
        NSString *after = nil;
        for (ACAccount *fresh in ((ACAccountStore *)[(id)storeClass ams_sharedAccountStore]).accounts)
            if ([fresh.identifier isEqualToString:account.identifier])
                after = fresh.ams_storefront;

        if ([after isEqualToString:before]) {
            note(@"[=] %@: unchanged, still %@", account.username ?: @"(local)", before ?: @"(unset)");
            continue;
        }
        note(@"[+] %@: %@ -> %@", account.username ?: @"(local)",
             before ?: @"(unset)", after ?: @"(unset)");
        changed++;
    }

    if (!changed) {
        if (outError) *outError = [NSError errorWithDomain:@"appstorectl" code:5 userInfo:@{
            NSLocalizedDescriptionKey: @"no active or local iTunes account to change"}];
        return NO;
    }
    return YES;
}
