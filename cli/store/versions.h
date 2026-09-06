// versions.h — asking the store which builds of an app it will still serve.
#import <Foundation/Foundation.h>

/// Every external version identifier the store will still serve for this app, ascending, oldest
/// first, so the last element is what a plain install gets. Nil on failure with outError set.
///
/// This deliberately does not go through appstored. ASDPurchaseResult carries success, error and
/// itemID and nothing else, so the version list is unreachable from an appstored client.
/// AppleMediaServices' own purchase queue hands back the raw store response, and the list lives at
///
///     songList[0].metadata.softwareVersionExternalIdentifiers
///
/// which is what -[Lookup lookupEvidsForApp:withCompletion:] reads in asclient (0x100146924).
///
/// dialogDelegate is set as the AMSPurchaseQueueConfiguration delegate. It should implement
/// handleDialogRequest:purchase:purchaseQueue:completion: — the queue can raise a dialog mid-lookup
/// and an unanswered one stalls until the timeout. Pass nil to decline that and eat the stall.
///
/// Not a free read: enqueuing a purchase is what makes the store answer, and the store notes it.
/// asclient clears the download queue for that reason before its own size lookup
/// (-[Lookup lookupDownloadSizeForApp:withCompletion:]). Nothing downloads here, because
/// downloading is appstored's job and appstored is not involved, but do not call this in a loop.
/// One item from the store's metadata lookup, in amp-api shape. A plain read: no purchase, no
/// payment sheet. -[Lookup _processedLookupResult:] (asclient 0x100149420) is the map of what is
/// inside, the useful part being
///
///     attributes.platformAttributes.ios.{bundleId, externalVersionId, versionHistory, offers}
///
/// where offers[0].buyParams is the string the store itself would use for this app.
NSDictionary *storeLookupForBundleID(NSString *bundleID, NSError **outError);

///
/// buyParamsOverride replaces the whole generated string when non-nil. The store 500s on a
/// buy-params string it considers incomplete, and which fields it wants is not documented anywhere,
/// so this exists to bisect that from the shell rather than from a rebuild.
/// purchaseType selects which flavour of purchase is enqueued. asclient uses 0 for a normal
/// purchase, 2 for DSID-less, and 5 for the VPP/HRN flow that reads a download URL out of the
/// response (-[VPPCommand _generateHRNRequest:options:] 0x1001190ac). Pass 0 unless probing.
///
/// outResponse, when non-NULL, receives the raw store response from the last round even on
/// failure. The version list is one field of it; a download URL would be another.
NSArray<NSNumber *> *storeEvidsForAdamID(NSNumber *adamID, NSString *bundleID,
                                         NSString *buyParamsOverride, long long purchaseType,
                                         id dialogDelegate, NSDictionary **outResponse,
                                         NSError **outError);
