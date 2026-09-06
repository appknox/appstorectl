// versions.m — the store's version list, via AppleMediaServices rather than appstored.
//
// See versions.h for why this route and not the appstored one, and AMSPrivate.h for where the
// class shapes came from.
#import <Foundation/Foundation.h>

#import "AMSPrivate.h"
#import "buyparams.h"
#import "versions.h"
#import "../log.h"

/// Accounts.framework's store, plus the two AMSCore additions to it. Declared rather than imported
/// so nothing has to link Accounts: the class is resolved by name at runtime, after
/// AppleMediaServices is dlopened, and messaged through id.
@interface ACAccountStore : NSObject
+ (instancetype)ams_sharedAccountStore;
- (id)ams_activeiTunesAccount;
@end

/// asclient builds its own bag rather than using the queue's — -[ASCBag init] (0x1000a0e80) is
/// [AMSBag bagForProfile:@"appstored" profileVersion:@"1"] with storefront-header-suffix overridden
/// to "t:apps3" (+[ASCBag _setDefaultValuesForBag:] 0x1000a103c). That suffix goes on
/// X-Apple-Store-Front and is how MZBuy tells clients apart.
///
/// Reproducing it exactly here makes buyProduct hang until NSURLErrorTimedOut instead of answering,
/// twice in a row. The queue's own sub-profile bag answers every time. Whatever t:apps3 grants
/// asclient is not available to this process, so use the one that works.
static id purchaseBag(void) {
    return [NSClassFromString(@"AMSPurchaseQueue") createBagForSubProfile];
}

NSDictionary *storeLookupForBundleID(NSString *bundleID, NSError **outError) {
    Class taskClass  = NSClassFromString(@"AMSMediaTask");
    Class storeClass = NSClassFromString(@"ACAccountStore");
    if (!taskClass || !storeClass) {
        if (outError) *outError = [NSError errorWithDomain:@"appstorectl" code:1 userInfo:@{
            NSLocalizedDescriptionKey: @"AppleMediaServices classes unavailable"}];
        return nil;
    }

    AMSMediaTask *task = [[taskClass alloc] initWithType:0
                                       clientIdentifier:@"appstore"
                                          clientVersion:@"1"
                                                    bag:[taskClass createBagForSubProfile]];
    task.account             = [[(id)storeClass ams_sharedAccountStore] ams_activeiTunesAccount];
    task.additionalPlatforms = @[@"iphone"];
    task.bundleIdentifiers   = @[bundleID];

    NSError *err = nil;
    id result = [[task perform] resultWithError:&err];
    if (err) {
        if (outError) *outError = err;
        return nil;
    }
    NSArray *items = [result respondsToSelector:@selector(responseDataItems)]
                   ? [(AMSMediaResult *)result responseDataItems] : nil;
    id first = items.firstObject;
    if (![first isKindOfClass:NSDictionary.class]) {
        if (outError) *outError = [NSError errorWithDomain:@"appstorectl" code:4 userInfo:@{
            NSLocalizedDescriptionKey: @"the store returned no item for this bundle id"}];
        return nil;
    }
    return first;
}

NSArray<NSNumber *> *storeEvidsForAdamID(NSNumber *adamID, NSString *bundleID,
                                         NSString *buyParamsOverride, long long purchaseType,
                                         id dialogDelegate, NSDictionary **outResponse,
                                         NSError **outError) {
    Class queueClass  = NSClassFromString(@"AMSPurchaseQueue");
    Class configClass = NSClassFromString(@"AMSPurchaseQueueConfiguration");
    Class buyClass    = NSClassFromString(@"AMSBuyParams");
    Class purchClass  = NSClassFromString(@"AMSPurchase");
    Class storeClass  = NSClassFromString(@"ACAccountStore");
    if (!queueClass || !configClass || !buyClass || !purchClass || !storeClass) {
        if (outError) *outError = [NSError errorWithDomain:@"appstorectl" code:1 userInfo:@{
            NSLocalizedDescriptionKey: @"AppleMediaServices classes unavailable"}];
        return nil;
    }

    // KNOWN WALL, and the reason this function currently fails on 16.7.12. MZBuy answers HTTP 500
    // to any purchase from this process that claims hasConfirmedPaymentSheet, and refuses to
    // fulfil one that does not. Without fulfilment there is no songList, and songList is the only
    // place the version list exists. Measured against, in order:
    //
    //   STDQ / STDRDL, with and without hasBeenAuthedForBuy + hasConfirmedPaymentSheet   500
    //   the store's own offers[0].buyParams, pg=default and appExtVrsId included         sheet, then 500
    //   the okButtonAction.buyParams the sheet hands back, resent in-session             500
    //   clientId and callerBundleId set to com.apple.AppStore                            500
    //   asclient's own bag (appstored profile, storefront-header-suffix t:apps3)         request hangs
    //
    // appstored makes the identical claim and is fulfilled, so the difference is client trust, not
    // the string. asclient is com.apple.asclient on an AppleInternal rootfs carrying ~180
    // entitlements; adi-client and keychain-access-groups were enough to get anisette working here
    // but not enough to be fulfilled. Do not add more buy params hoping to fix this.
    //
    // Ask plainly, take the ConfirmPaymentSheet refusal, resend what the store hands back. That is
    // the shape asclient uses and it is correct; it is only the last step that is refused.
    NSString *params = buyParamsOverride ?: [NSString stringWithFormat:
        @"salableAdamId=%@&productType=C&price=0&pricingParameters=STDQ", adamID];

    id account = [[(id)storeClass ams_sharedAccountStore] ams_activeiTunesAccount];
    AMSPurchaseQueueConfiguration *config = [[configClass alloc] initWithBag:purchaseBag()];
    config.delegate = dialogDelegate;
    AMSPurchaseQueue *queue = [[queueClass alloc] initWithConfiguration:config];

    __block NSDictionary *response = nil;
    __block NSError *failure = nil;

    // One resend, not a loop: the store either hands back a usable string or it has refused for a
    // reason no replay fixes, and a loop on a purchase endpoint is not something to get wrong.
    for (int round = 0; round < 2 && params; round++) {
        logLine(@"versions: round %d buyParams = %@", round, params);
        AMSPurchase *purchase =
            [[purchClass alloc] initWithPurchaseType:purchaseType
                                           buyParams:[buyClass buyParamsWithString:params]];
        purchase.account       = account;
        purchase.logUUID       = [NSString stringWithFormat:@"versions:%@:%@", bundleID ?: @"?", adamID];
        purchase.userInitiated = NO;
        // asclient does this immediately before enqueuing, every time
        // (-[Lookup _getPurchaseResponse:error:] 0x10014a9d8). It changes nothing here, but it is
        // free and it matches the reference implementation.
        [[NSClassFromString(@"AMSKeybag") sharedInstance] resetContext];

        __block BOOL done = NO;
        response = nil;
        failure  = nil;
        [[queue enquePurchases:@[purchase]] addFinishBlock:^(id result, NSError *error) {
            id first = [result isKindOfClass:NSArray.class] ? [result firstObject] : result;
            if ([first respondsToSelector:@selector(responseDictionary)])
                response = [(AMSPurchaseResult *)first responseDictionary];
            if (!error && [first respondsToSelector:@selector(error)])
                error = [(AMSPurchaseResult *)first error];
            failure = error;
            done    = YES;
        }];

        // asclient spins the runloop here rather than blocking on a semaphore
        // (-[Lookup _getPurchaseResponse:error:] 0x10014a9d8). The promise resolves on this
        // thread's runloop, so a semaphore wait deadlocks.
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:120.0];
        while (!done && deadline.timeIntervalSinceNow > 0)
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];

        if (!done) {
            if (outError) *outError = [NSError errorWithDomain:@"appstorectl" code:2 userInfo:@{
                NSLocalizedDescriptionKey: @"timed out waiting for the store"}];
            return nil;
        }
        logLine(@"versions: round %d keys = %@ error = %@", round,
                [response.allKeys componentsJoinedByString:@", "] ?: @"(none)",
                failure.localizedDescription ?: @"(none)");

        if (!failure) break;
        NSString *resend = serverBuyParamsFromError(failure);
        if (!resend) break;
        note(@"[+] store asked to confirm; resending its own buy params");
        params = resend;
    }

    if (outResponse) *outResponse = response;

    // songList is the normal shape; asclient falls back to `items`, so do the same.
    id list = response[@"songList"] ?: response[@"items"];
    id song = [list isKindOfClass:NSArray.class] ? [list firstObject] : nil;
    id metadata = [song isKindOfClass:NSDictionary.class] ? song[@"metadata"] : nil;
    id evids = [metadata isKindOfClass:NSDictionary.class]
             ? metadata[@"softwareVersionExternalIdentifiers"] : nil;

    if (![evids isKindOfClass:NSArray.class] || ![evids count]) {
        NSString *message = response[@"customerMessage"];
        if (outError) *outError = failure ?: [NSError errorWithDomain:@"appstorectl" code:3 userInfo:@{
            NSLocalizedDescriptionKey: message ?: @"the store returned no version list"}];
        // Only worth a log line when the store did not explain itself; a customerMessage is the
        // answer, a full dump of the response is what you need when there isn't one.
        if (!message && response) logLine(@"versions: full response = %@", response);
        return nil;
    }
    return evids;
}
