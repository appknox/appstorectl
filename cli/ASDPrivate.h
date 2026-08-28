// ASDPrivate.h — private interfaces used to drive the App Store purchase pipeline.
//
// Recovered from iOS 15.8.1 (19H380) by class-dumping the shared cache. Ivar offsets and enum
// values below were read out of the binaries, not guessed. Nothing here is public API and all of
// it can change between iOS releases.
//
// A hard-won warning about reply blocks
// -------------------------------------
// class-dump renders every completion handler as `(id /* block */)handler` — no argument types.
// Declaring one with the wrong arity is not a graceful failure: ARC emits objc_storeStrong on an
// argument slot that holds a leftover register value, and the process dies with SIGBUS inside
// objc_retain. Probing the slots is also unsafe, because a bad pointer raises a signal and @try
// only catches ObjC exceptions.
//
// The safe pattern, learned three times over:
//   1. declare the block with NO arguments — always valid to invoke, extra registers ignored
//   2. confirm the outcome by re-reading state, not by parsing a reply you cannot trust
// Where an arity IS known below, it was established empirically with a non-ARC probe that took
// four void* slots and printed the raw registers.

#import <Foundation/Foundation.h>

#pragma mark - AppStoreDaemon.framework

// The purchase request handed to appstored. Four fields matter; the rest of the pipeline fills
// itself in.
@interface ASDPurchase : NSObject

/// Mandatory. PreparePurchaseTask keys the IXAppInstallCoordinator on it; nil produces
/// "Cannot create coordinator for purchase without bundle identifier" and nothing installs.
@property (copy) NSString *bundleID;

/// The adamId. If nil, the daemon falls back to `salableAdamId` inside buyParameters.
@property (copy) NSNumber *itemID;

/// A percent-encoded URL query string, parsed by AMSBuyParams via NSURLComponents. Nothing on the
/// device validates its contents — every constraint is server-side. In practice four keys suffice:
///   salableAdamId=<id>&productType=C&price=0&pricingParameters=STDQ
/// productType must NOT be "A": that value diverts the whole purchase to the StoreKit IAP service.
@property (copy) NSString *buyParameters;

/// Selects the endpoint by URL-bag key. nil defaults to "buyProduct". Note "downloadProduct" is
/// the DSID-less path (downloaddispatch.itunes.apple.com/r/accountless), NOT a redownload — for a
/// redownload of an owned item, stay on buyProduct.
@property (copy) NSString *bagKey;

@property (copy) NSString *clientID;
@property (copy) NSString *vendorName;

/// Mandatory in practice, and easy to miss because it defaults to 0. appstored correlates a job
/// back to its purchase through this value; with 0 the job is created but never scheduled and
/// parks at phase 9 (percentComplete -1, orderKey nil) forever, with failureError nil. No error is
/// ever raised — it simply never downloads. Set any nonzero value.
@property (assign) long long purchaseID;

@property (assign) BOOL isRedownload;
@property (assign) BOOL createsJobs;
@end


@interface ASDPurchaseResult : NSObject
@property (readonly) BOOL success;
@property (readonly) NSError *error;
/// nil even on success. Do not use it to confirm anything.
@property (readonly) NSNumber *itemID;
@end


@interface ASDPurchaseManager : NSObject
+ (instancetype)sharedManager;
- (void)startPurchase:(id)purchase withResultHandler:(void (^)(ASDPurchaseResult *r, NSError *e))h;
@end


@interface ASDServiceBroker : NSObject
+ (id)defaultBroker;
/// Fetch the purchase service proxy ONCE and hold it. Requesting a second proxy — from this or any
/// other broker — tears down the in-flight startPurchase: reply and surfaces as
/// NSCocoaErrorDomain 4099 "the message was sent over an additional proxy and therefore this proxy
/// has become invalid."
- (id)getPurchaseServiceWithError:(NSError **)error;
@end


/// The purchase service's XPC protocol.
@protocol ASDPurchaseServiceProtocol
- (void)startPurchase:(id)purchase withReplyHandler:(id)handler;
/// Answers a dialog that was *delivered to a client* via deliverDialogRequest:. The App Store
/// confirmation sheet is presented by AppleMediaServices through PassbookUIService and never
/// registered here, so calling this for it is accepted but is a no-op. Kept because it is the
/// correct API should Apple ever route payment sheets through the dialog delegate.
- (void)notifyDialogCompleteForPurchaseID:(id)purchaseID
                                   result:(BOOL)result
                           selectedButton:(long long)button
                        withResultHandler:(id)handler;
@end


@interface ASDNotificationCenter : NSObject
+ (instancetype)defaultCenter;
- (void)setDialogObserver:(id)observer;
- (void)addProgressObserver:(id)observer;
- (void)removeProgressObserver:(id)observer;
@end


/// Delivered to an ASDNotificationCenterProgressObserver. The selector is
/// notificationCenter:receivedProgress: — singular, but the payload is an NSArray of these.
@interface ASDProgress : NSObject
@property (readonly) NSString *bundleID;
@property (readonly) long long completedUnitCount;
@property (readonly) long long totalUnitCount;
@property (readonly) long long downloadCompletedUnitCount;
@property (readonly) long long downloadTotalUnitCount;
@property (readonly) long long installCompletedUnitCount;
@property (readonly) long long installTotalUnitCount;
@property (readonly) long long phase;
@property (readonly) double throughput;
@end


/// Lists in-flight jobs only. A small app can finish inside the first poll interval, so treat the
/// bundle on disk as ground truth for completion rather than polling this.
@interface ASDJobManager : NSObject
- (id)init;
- (void)getJobsUsingBlock:(id)block;
/// Removes the job AND its placeholder container, leaving no orphan icon. The clean way to
/// recover from a stalled install.
- (void)cancelJobsWithIDs:(id)ids completionBlock:(id)block;
@end


#pragma mark - StoreServices.framework

/// Purchase authorization settings. These live on the Apple ID and sync, they are not device-local
/// — the same values Settings > Media & Purchases > Password Settings writes.
///
/// Values: 1 = always, 2 = sometimes, 3 = never.
/// An unset value (0) behaves as "always": _newAccountPasswordSettingsDictionary passes
/// defaultValue:@"always". So an account that looks unconfigured still prompts.
///
/// The server accepts `free -> never` but refuses `paid -> never`; Apple enforces a floor on paid
/// purchases.
@interface SSAccount : NSObject
@property (copy) NSString *accountName;
@property (retain) NSNumber *uniqueIdentifier;
@property long long freeDownloadsPasswordSetting;
@property long long paidPurchasesPasswordSetting;
/// Reply block arity is undocumented; declare it with no arguments and verify by re-reading.
- (void)updateAccountPasswordSettingsWithRequestProperties:(id)props completionBlock:(id)block;
@end


@interface SSAccountStore : NSObject
+ (id)defaultStore;
@property (readonly) SSAccount *activeAccount;

/// `activeAccount` returns a CACHED SSAccount. After writing a password setting it still reports
/// the old value in the same process, even though the write succeeded — a fresh process sees the
/// new value. Re-read through this with reloadIfNecessary:YES to force a refresh.
- (id)accountWithUniqueIdentifier:(id)identifier reloadIfNecessary:(BOOL)reload;
@end
