// library.m — see library.h.
#import <Foundation/Foundation.h>

#import "library.h"
#import "../log.h"

@implementation LibraryApp
@end

/// The AppStoreDaemon classes this needs. Declared rather than imported; resolved by name after
/// AppStoreDaemon is dlopened. Selector lists read out of the framework binary.
@interface ASDPurchaseHistoryQuery : NSObject
@property (assign) long long accountID;
@property (copy) NSArray *bundleIDs;
@property (copy) NSArray *storeIDs;
@end

@interface ASDPurchaseHistoryApp : NSObject
@property (readonly) NSString *bundleID;
@property (readonly) long long storeItemID;
@property (readonly) NSString *title;
@property (readonly) NSDate *datePurchased;
@property (readonly) NSString *redownloadParams;
@property (readonly, getter=isHidden) BOOL hidden;
@property (readonly) NSString *preflightPackageURL;
@end

/// Both signatures are read out of the protocol method-type table in AppStoreDaemon, not guessed.
/// Getting either wrong is a SIGBUS, not an error — ARC retains whatever was in the argument
/// register. The first cost one before it was looked up:
///
///   v40@0:8q16Q24@?<v@?@"NSError">32
///     updateForAccountID:  q   long long
///     withContext:         Q   unsigned long long — NOT an object; asclient passes 0
///     completion           ^(NSError *)  — ONE argument. Declaring ^(BOOL, NSError *) reads x2,
///                                          which holds garbage, and dies in objc_retain.
///
///   v32@0:8@"ASDPurchaseHistoryQuery"16@?<v@?@"NSArray"@"NSError">24
///     completion           ^(NSArray *, NSError *)
@interface ASDPurchaseHistory : NSObject
+ (instancetype)sharedInstance;
- (void)updateForAccountID:(long long)accountID
               withContext:(unsigned long long)context
     withCompletionHandler:(void (^)(NSError *error))handler;
- (void)executeQuery:(ASDPurchaseHistoryQuery *)query
   withResultHandler:(void (^)(NSArray *apps, NSError *error))handler;
@end

@interface ACAccountStore : NSObject
+ (instancetype)ams_sharedAccountStore;
- (id)ams_activeiTunesAccount;
@end

@interface ACAccount : NSObject
- (NSNumber *)ams_DSID;
@end

/// Run one of the two asynchronous legs and wait. Both hand back (something, NSError *), and both
/// resolve off this thread, so a semaphore is correct here — unlike the purchase queue in
/// versions.m, which resolves on this thread's runloop and would deadlock.
static BOOL waitFor(void (^start)(dispatch_semaphore_t sem)) {
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    start(sem);
    return dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 120ull * NSEC_PER_SEC)) == 0;
}

NSArray<LibraryApp *> *accountLibrary(NSArray<NSString *> *bundleIDs, NSError **outError) {
    Class historyClass = NSClassFromString(@"ASDPurchaseHistory");
    Class queryClass   = NSClassFromString(@"ASDPurchaseHistoryQuery");
    Class storeClass   = NSClassFromString(@"ACAccountStore");
    if (!historyClass || !queryClass || !storeClass) {
        if (outError) *outError = [NSError errorWithDomain:@"appstorectl" code:1 userInfo:@{
            NSLocalizedDescriptionKey: @"AppStoreDaemon classes unavailable"}];
        return nil;
    }

    ACAccount *account = [[(id)storeClass ams_sharedAccountStore] ams_activeiTunesAccount];
    NSNumber *dsid = [account ams_DSID];
    if (!dsid) {
        if (outError) *outError = [NSError errorWithDomain:@"appstorectl" code:5 userInfo:@{
            NSLocalizedDescriptionKey: @"no active iTunes account"}];
        return nil;
    }

    ASDPurchaseHistory *history = [historyClass sharedInstance];
    __block NSError *failure = nil;

    // Refresh first. Without it the query answers from whatever appstored last cached, which on a
    // device that has not opened the App Store app can be nothing at all.
    BOOL refreshed = waitFor(^(dispatch_semaphore_t sem) {
        [history updateForAccountID:dsid.longLongValue
                        withContext:0
              withCompletionHandler:^(NSError *error) {
            failure = error;
            dispatch_semaphore_signal(sem);
        }];
    });
    if (!refreshed) logLine(@"library: refresh timed out; querying the cached history anyway");
    if (failure) logLine(@"library: refresh failed (%@); querying anyway", failure.localizedDescription);

    ASDPurchaseHistoryQuery *query = [queryClass new];
    query.accountID = dsid.longLongValue;
    if (bundleIDs.count) query.bundleIDs = bundleIDs;

    __block NSArray *apps = nil;
    BOOL queried = waitFor(^(dispatch_semaphore_t sem) {
        [history executeQuery:query withResultHandler:^(NSArray *result, NSError *error) {
            apps    = result;
            failure = error ?: failure;
            dispatch_semaphore_signal(sem);
        }];
    });
    if (!queried) {
        if (outError) *outError = [NSError errorWithDomain:@"appstorectl" code:2 userInfo:@{
            NSLocalizedDescriptionKey: @"timed out querying the purchase history"}];
        return nil;
    }
    if (!apps) {
        if (outError) *outError = failure ?: [NSError errorWithDomain:@"appstorectl" code:3 userInfo:@{
            NSLocalizedDescriptionKey: @"the purchase history query returned nothing"}];
        return nil;
    }

    // Measured on 16.7.12: appstored ignores the query's bundleIDs and answers with the whole
    // locker regardless, so filter here too rather than trusting it.
    NSSet *wanted = bundleIDs.count ? [NSSet setWithArray:bundleIDs] : nil;

    NSMutableArray<LibraryApp *> *out = [NSMutableArray arrayWithCapacity:apps.count];
    for (ASDPurchaseHistoryApp *app in apps) {
        if (![app respondsToSelector:@selector(storeItemID)]) continue;
        if (wanted && ![wanted containsObject:app.bundleID ?: @""]) continue;
        LibraryApp *entry = [LibraryApp new];
        entry.bundleID         = app.bundleID;
        entry.storeItemID      = @(app.storeItemID);
        entry.title            = app.title;
        entry.datePurchased    = app.datePurchased;
        entry.redownloadParams = app.redownloadParams;
        entry.hidden           = app.isHidden;
        if ([app respondsToSelector:@selector(preflightPackageURL)])
            entry.preflightPackageURL = app.preflightPackageURL;
        entry.rawDescription = [app description];
        [out addObject:entry];
    }
    return out;
}

LibraryApp *libraryEntryForBundleID(NSString *bundleID, NSError **outError) {
    // bundleIDs on the query is a filter appstored applies itself, so ask for the one.
    NSArray<LibraryApp *> *apps = accountLibrary(@[bundleID], outError);
    for (LibraryApp *app in apps)
        if ([app.bundleID isEqualToString:bundleID]) return app;
    return nil;
}
