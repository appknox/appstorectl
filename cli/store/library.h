// library.h — what the active account owns, straight from appstored.
//
// This is the query asclient uses to decide whether an app is a purchase or a redownload:
// -[ASCPurchases _getDAAPItems:] (0x100115590) refreshes ASDPurchaseHistory for the account's DSID
// and then runs an ASDPurchaseHistoryQuery against it. No store request of our own, so none of the
// client-trust problems in versions.m apply here.
#import <Foundation/Foundation.h>

/// One entry from the account's locker. Only the fields worth having are declared; the real class
/// has around fifty.
@interface LibraryApp : NSObject
@property (copy) NSString *bundleID;
@property (copy) NSNumber *storeItemID;
@property (copy) NSString *title;
@property (copy) NSDate   *datePurchased;
/// The store's own buy params for redownloading this app, issued by the store and cached by
/// appstored. Reads like productType=C&price=0&salableAdamId=…&pricingParameters=STDRDL.
@property (copy) NSString *redownloadParams;
@property (assign) BOOL hidden;
/// A URL the store hands out for the app's package. Whether it is actually fetchable, and whether
/// it is the full asset or only a preflight stub, is the open question — see `_library-raw`.
@property (copy) NSString *preflightPackageURL;
/// -[ASDPurchaseHistoryApp description], verbatim. Only for looking at what else is in there.
@property (copy) NSString *rawDescription;
@end

/// Everything the active account owns, or nil on failure. bundleIDs narrows the query when non-nil.
///
/// Refreshing the history is a round trip to the store made *by appstored*, so it can take a
/// while; both legs are given 120 s, which is what asclient allows.
NSArray<LibraryApp *> *accountLibrary(NSArray<NSString *> *bundleIDs, NSError **outError);

/// Convenience over accountLibrary: the locker entry for one bundle id, or nil if not owned.
/// A nil return with a nil outError means "looked, not there" rather than "could not look".
LibraryApp *libraryEntryForBundleID(NSString *bundleID, NSError **outError);
