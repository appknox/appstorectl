// appstorectl — buy and install an App Store app from the shell, by bundle ID.
//
//   appstorectl purchase  <bundle-id> [--adam <id>]
//   appstorectl install   <bundle-id> [--adam <id>] [-o <path>] [--evid <id>] [--no-export|--no-decrypt]
//   appstorectl export    <bundle-id> [-o <path>] [--no-decrypt]
//   appstorectl resolve   <bundle-id>
//   appstorectl search    <term> [-l <count>]
//   appstorectl uninstall <bundle-id>
//   appstorectl jobs
//   appstorectl version
//
// Purchase and install live here; reconstructing an IPA from an installed app lives in export.m,
// and appstorectl.h is the seam between them.
//
// It does not reimplement the store protocol. It hands an ASDPurchase to appstored over XPC and
// lets Apple's own pipeline do the buying, downloading, FairPlay binding and installing — the same
// path the App Store app's Get button takes.
//
// Build on device (the binary MUST live under /var/jb; /tmp binaries are SIGKILLed):
//   clang-16 -isysroot /var/jb/usr/share/SDKs/iPhoneOS.sdk -arch arm64 \
//            -framework Foundation -fobjc-arc -o appstorectl appstorectl.m
//   ldid -Sent.plist appstorectl
//
// Required entitlement: com.apple.itunesstored.private   (that one alone gates the service;
// every com.apple.appstored.* entitlement returns ASDErrorDomain 505 here)
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <errno.h>
#import <objc/runtime.h>
#import <spawn.h>
#import <string.h>
#import <sys/wait.h>

#import "store/AMSPrivate.h"
#import "store/buyparams.h"
#import "store/library.h"
#import "store/storefront.h"
#import "store/versions.h"
#import "ASDPrivate.h"
#import "account.h"
#import "appstorectl.h"
#import "log.h"
#import "biometric.h"
#import "export.h"

#ifndef APPSTORECTL_VERSION
#error APPSTORECTL_VERSION must be supplied by the build system
#endif

#pragma mark - Small helpers

// Dump everything the store said. AMSServerPayload carries the real reason (dialog title, body and
// okButtonAction) and is the only place a refusal explains itself, so print the whole userInfo
// rather than just localizedDescription, which is usually a generic string.
static void describeError(NSError *err) {
    if (!err) { note(@"    (no error object)"); return; }
    note(@"    domain : %@", err.domain);
    note(@"    code   : %ld", (long)err.code);
    note(@"    message: %@", err.localizedDescription ?: @"-");
    for (NSString *k in err.userInfo) {
        if ([k isEqualToString:@"NSLocalizedDescription"]) continue;
        note(@"    %@ = %@", k, err.userInfo[k]);
    }
    // The terminal copy above is what a human skims. This is the one worth having in six months:
    // the whole userInfo, undecorated, including the AMSServerPayload dialog that names which gate
    // refused. escapeForLog flattens its newlines so it stays one record.
    logLine(@"error userInfo (verbatim): %@", err.userInfo);
}

NSString *humanBytes(long long b) {
    if (b <= 0) return @"0 B";
    static const char *u[] = {"B", "KB", "MB", "GB"};
    double v = (double)b; int i = 0;
    while (v >= 1024.0 && i < 3) { v /= 1024.0; i++; }
    return [NSString stringWithFormat:@"%.1f %s", v, u[i]];
}

#pragma mark - adamId resolution

// The store's own lookup endpoint. We try the device's App Store country first, then bare (which
// defaults to US), because a bundle ID can be absent from one storefront and present in another.
static NSString *deviceCountryCode(void) {
    // The active storefront lives in itunesstored's prefs as e.g. "143441-1,29". Mapping every
    // storefront id to an ISO country is not worth it; the device region gets it right in
    // practice and the bare query covers the rest.
    NSString *cc = [[NSLocale currentLocale] objectForKey:NSLocaleCountryCode];
    return cc.length == 2 ? [cc lowercaseString] : nil;
}

/// outPrice receives the storefront price as an NSNumber, or nil if the lookup did not carry one.
/// nil is not the same as free: treat an unknown price as paid.
static NSNumber *resolveAdamID(NSString *bundleID, NSString **outName, NSNumber **outPrice) {
    NSMutableArray<NSString *> *urls = [NSMutableArray array];
    NSString *cc = deviceCountryCode();
    if (cc) [urls addObject:[NSString stringWithFormat:
        @"https://itunes.apple.com/lookup?bundleId=%@&country=%@", bundleID, cc]];
    [urls addObject:[NSString stringWithFormat:
        @"https://itunes.apple.com/lookup?bundleId=%@", bundleID]];

    for (NSString *u in urls) {
        NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:u]];
        if (!data.length) { logLine(@"lookup no data: %@", u); continue; }
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        NSArray *results = j[@"results"];
        if (![results isKindOfClass:NSArray.class] || !results.count) {
            logLine(@"lookup 0 results: %@", u);
            continue;
        }
        logLine(@"lookup hit: %@", u);

        NSDictionary *r = results.firstObject;
        NSNumber *trackId = r[@"trackId"];
        if (![trackId isKindOfClass:NSNumber.class]) continue;
        if (outName) *outName = r[@"trackName"];
        if (outPrice) {
            id price = r[@"price"];
            *outPrice = [price isKindOfClass:NSNumber.class] ? price : nil;
        }
        note(@"[+] %@  ->  adamId %@   (%@, %@ %@, minOS %@)",
             bundleID, trackId, r[@"trackName"] ?: @"?",
             r[@"price"] ?: @"?", r[@"currency"] ?: @"", r[@"minimumOsVersion"] ?: @"?");
        return trackId;
    }

    // The endpoint above is public and follows the device locale, so an app that exists only in
    // the account's storefront is invisible to it — mAadhaar (com.Uidai.mAadhaar) is in the Indian
    // catalog and nowhere else, and a US-locale device cannot see it however the account is set.
    //
    // The catalog lookup is authenticated and follows the ACCOUNT's storefront, so it can. It costs
    // a round trip and needs a signed-in account, which is why it is the fallback and not the
    // first choice.
    logLine(@"lookup: public endpoint had nothing for %@; trying the account's storefront", bundleID);
    NSError *storeErr = nil;
    NSDictionary *item = storeLookupForBundleID(bundleID, &storeErr);
    if (!item) {
        logLine(@"lookup: catalog lookup also failed: %@", storeErr.localizedDescription ?: @"?");
        return nil;
    }

    NSNumber *itemID = item[@"id"];
    if (![itemID isKindOfClass:NSNumber.class]) {
        // amp-api returns the id as a string in some responses.
        id raw = item[@"id"];
        itemID = [raw isKindOfClass:NSString.class] ? @([raw longLongValue]) : nil;
    }
    if (!itemID) return nil;

    NSDictionary *attrs = item[@"attributes"];
    NSDictionary *ios   = attrs[@"platformAttributes"][@"ios"];
    id offer  = [ios[@"offers"] isKindOfClass:NSArray.class] ? [ios[@"offers"] firstObject] : nil;
    id price  = [offer isKindOfClass:NSDictionary.class] ? offer[@"price"] : nil;

    if (outName)  *outName  = attrs[@"name"];
    if (outPrice) *outPrice = [price respondsToSelector:@selector(doubleValue)]
                            ? @([price doubleValue]) : nil;

    note(@"[+] %@  ->  adamId %@   (%@, %@, minOS %@)  via the account's storefront",
         bundleID, itemID, attrs[@"name"] ?: @"?",
         price ?: @"?", ios[@"minimumOSVersion"] ?: @"?");
    return itemID;
}

static int cmdSearch(NSString *term, NSInteger limit) {
    NSURLComponents *url = [NSURLComponents componentsWithString:@"https://itunes.apple.com/search"];
    NSMutableArray<NSURLQueryItem *> *query = [@[
        [NSURLQueryItem queryItemWithName:@"media" value:@"software"],
        [NSURLQueryItem queryItemWithName:@"entity" value:@"software"],
        [NSURLQueryItem queryItemWithName:@"term" value:term],
        [NSURLQueryItem queryItemWithName:@"limit" value:@(limit).stringValue],
    ] mutableCopy];
    NSString *cc = activeAccountStorefrontCountryCode() ?: deviceCountryCode();
    if (cc) [query addObject:[NSURLQueryItem queryItemWithName:@"country" value:cc]];
    url.queryItems = query;

    NSError *err = nil;
    NSData *data = [NSData dataWithContentsOfURL:url.URL options:0 error:&err];
    NSDictionary *payload = data.length
        ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&err] : nil;
    NSArray *results = [payload isKindOfClass:NSDictionary.class] ? payload[@"results"] : nil;
    if (![results isKindOfClass:NSArray.class]) {
        warnf(@"search failed: %@", err.localizedDescription ?: @"invalid response");
        return 1;
    }
    if (!results.count) {
        note(@"[=] no App Store results for \"%@\"", term);
        return 0;
    }

    NSUInteger index = 0;
    for (NSDictionary *app in results) {
        if (![app isKindOfClass:NSDictionary.class]) continue;
        note(@"[%lu] %@", (unsigned long)++index, app[@"trackName"] ?: @"(unnamed)");
        note(@"    bundleId: %@", app[@"bundleId"] ?: @"-");
        note(@"    adamId:   %@", app[@"trackId"] ?: @"-");
        note(@"    version:  %@", app[@"version"] ?: @"-");
        note(@"    minOS:    %@", app[@"minimumOsVersion"] ?: @"-");
        note(@"    price:    %@ %@", app[@"price"] ?: @"-", app[@"currency"] ?: @"");
    }
    note(@"[+] %lu result(s)", (unsigned long)index);
    return 0;
}

#pragma mark - Observers

// appstored calls this when the store wants to talk to the user. A well-formed purchase on a
// signed-in device normally takes the system biometric path and never lands here, but a degraded
// state (signed out, terms changed, Ask to Buy) will — and without an observer registered the
// purchase dies with ASDErrorDomain 1060 "No dialog observer was available".
@interface Observers : NSObject
@property (assign) BOOL autoAccept;
@property (copy)   NSString *bundleID;
@property (assign) BOOL sawProgress;
/// When the last progress callback for this bundle arrived. The install wait uses it to tell a
/// stalled job from a slow one: an install that is still reporting bytes must never be abandoned,
/// whatever the job list happens to say at that instant.
@property (assign) CFAbsoluteTime lastProgressAt;
@end

@implementation Observers

// The block is (AMSDialogResult *, NSError *) — two object slots, result first. That is not a
// guess: it is the inlined block signature from the protocol method-type table
// __OBJC_$_PROTOCOL_METHOD_TYPES_ASDNotificationCenterDialogObserver in AppStoreDaemon,
//   v32@0:8@"AMSDialogRequest"16@?<v@?@"AMSDialogResult"@"NSError">24
// and it matches what Apple's own asclient does with the same handler. See AMSDialogPrivate.h.
//
// An earlier comment here claimed a dialog could not be answered affirmatively and that replaying
// okButtonAction.buyParams was the only route. That was wrong, and it was wrong because the block
// had been declared ^(BOOL, id): passing YES put the literal 0x1 where an object pointer belongs,
// so NSXPC ran objc_opt_isKindOfClass on 0x1 and the process died. The slot was never a BOOL.
//
// Answering here should complete the purchase without a second round and without a sheet to
// dismiss. The buyParams replay in cmdInstall stays as the backstop for the cases this cannot
// reach — a password prompt or a TID signature, which no dialog answer can satisfy.
- (void)handleDialogRequest:(AMSDialogRequest *)request
              resultHandler:(void (^)(AMSDialogResult *, NSError *))handler {
    AMSDialogAction *chosen = request.defaultAction ?: request.buttonActions.firstObject;
    note(@"[dialog] %@ — %@", request.identifier ?: @"(no identifier)", request.message ?: @"(no message)");

    if (!handler) return;
    BOOL isCompatibleVersionOffer =
        [request.identifier isEqualToString:@"MZCommerce.OsRequiresEarlierAppVersion"];
    if ((!self.autoAccept && !isCompatibleVersionOffer) || !chosen) {
        // Declining is a legitimate answer: a nil result is what the observer returns when it
        // will not act, and the store then falls back to the replay path.
        note(@"[dialog] not answering (%@)", chosen ? @"--accept not set" : @"no button actions");
        handler(nil, nil);
        return;
    }

    Class resultClass = NSClassFromString(@"AMSDialogResult");
    if (!resultClass) {
        warnf(@"AMSDialogResult unavailable; AppleMediaServices did not load");
        handler(nil, nil);
        return;
    }

    AMSDialogResult *result = [[resultClass alloc] initWithOriginalRequest:request
                                                 selectedActionIdentifier:chosen.identifier];
    result.textfieldValues = @[];
    note(@"[dialog] answering %@ (%@)", chosen.identifier ?: @"(no id)", chosen.title ?: @"");
    handler(result, nil);
}

// The same dialog, arriving from AMSPurchaseQueue instead of appstored. Different selector, four
// arguments instead of two, identical payload — so hand it to the two-argument version rather than
// duplicating the logic.
- (void)handleDialogRequest:(AMSDialogRequest *)request
                   purchase:(id)purchase
              purchaseQueue:(id)queue
                 completion:(void (^)(AMSDialogResult *, NSError *))completion {
    [self handleDialogRequest:request resultHandler:completion];
}

- (void)handleAuthenticateRequest:(id)request
                         purchase:(id)purchase
                    purchaseQueue:(id)queue
                       completion:(void (^)(id, NSError *))completion {
    [self handleAuthenticateRequest:request resultHandler:completion];
}

// Authentication is a password prompt. There is nothing to answer without credentials, so decline
// and let the caller see the real reason rather than a timeout.
- (void)handleAuthenticateRequest:(id)request resultHandler:(void (^)(id, NSError *))handler {
    note(@"[auth] store requested authentication; declining (no credentials to supply)");
    if (handler) handler(nil, nil);
}

// appstored delivers an NSArray of ASDProgress here, not a single object — the selector name is
// singular but the payload is not.
- (void)notificationCenter:(id)center receivedProgress:(id)payload {
    NSArray *items = [payload isKindOfClass:NSArray.class] ? payload : @[payload];
    for (ASDProgress *p in items) {
        if (![p respondsToSelector:@selector(bundleID)]) continue;
        if (self.bundleID && ![p.bundleID isEqualToString:self.bundleID]) continue;
        self.sawProgress    = YES;
        self.lastProgressAt = CFAbsoluteTimeGetCurrent();

        long long dDone = p.downloadCompletedUnitCount, dTotal = p.downloadTotalUnitCount;
        long long iDone = p.installCompletedUnitCount,  iTotal = p.installTotalUnitCount;

        if (dTotal > 0 && dDone < dTotal) {
            note(@"  downloading  %@ / %@  (%.0f%%)  %@/s",
                 humanBytes(dDone), humanBytes(dTotal),
                 100.0 * dDone / dTotal, humanBytes((long long)p.throughput));
        } else if (iTotal > 0 && iDone < iTotal) {
            note(@"  installing   %.0f%%", 100.0 * iDone / iTotal);
        } else if (p.totalUnitCount > 0 && p.completedUnitCount > 0) {
            // appstored emits placeholder progress objects with -1 / 0 counts around the
            // transitions; printing those just produces "-0%" noise.
            note(@"  progress     %.0f%%", 100.0 * p.completedUnitCount / p.totalUnitCount);
        }
    }
}

@end


#pragma mark - Version enumeration

static int cmdLibrary(NSString *filter) {
    NSError *err = nil;
    NSArray<LibraryApp *> *apps = accountLibrary(filter.length ? @[filter] : nil, &err);
    if (!apps) {
        warnf(@"could not read the library: %@", err.localizedDescription ?: @"unknown");
        printErrorChain(err, 1);
        return 1;
    }
    if (!apps.count) { note(@"[=] nothing in this account's library%@",
                            filter.length ? @" for that bundle id" : @""); return 0; }

    // %-44@ does not pad an NSString the way %-44s pads a C string, so pad explicitly.
    NSString *(^col)(NSString *, NSUInteger) = ^(NSString *s, NSUInteger width) {
        s = s.length ? s : @"-";
        return s.length >= width ? s
             : [s stringByPaddingToLength:width withString:@" " startingAtIndex:0];
    };
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.dateFormat = @"yyyy-MM-dd";

    note(@"  %@ %@ %@ %@", col(@"BUNDLE ID", 44), col(@"ADAM ID", 12),
         col(@"PURCHASED", 10), @"TITLE");
    for (LibraryApp *app in apps)
        note(@"  %@ %@ %@ %@%@",
             col(app.bundleID, 44), col(app.storeItemID.stringValue, 12),
             col(app.datePurchased ? [fmt stringFromDate:app.datePurchased] : nil, 10),
             app.title ?: @"", app.hidden ? @"  (hidden)" : @"");
    note(@"[+] %lu app(s)", (unsigned long)apps.count);
    return 0;
}

/// Everything appstored holds about one owned app. Undocumented; this exists to answer whether
/// preflightPackageURL and redownloadParams are usable without a store round trip.
static int cmdStorefront(NSString *storefront) {
    // No argument reads rather than writes. This is the value the setter acts on, which is not the
    // one `accounts` prints — that comes from StoreServices and is a separate copy.
    if (!storefront.length) {
        NSArray<NSString *> *fronts = accountStorefronts();
        if (!fronts.count) { warnf(@"no iTunes accounts"); return 1; }
        for (NSString *line in fronts) note(@"  %@", line);
        note(@"[=] this is ACAccount's value; `accounts` prints StoreServices', which can differ");
        return 0;
    }
    // Only a shape check. Nothing on the device knows which fronts this account may buy from, and
    // the save does not ask, so a wrong-but-plausible value is accepted here and refused by the
    // store later. Catching a typo is worth it; pretending to validate is not.
    //
    // Both forms are allowed. asclient's help gives the bare front (143441) and that is what it
    // writes, but the value already on an account reads back as "143441-1,29" — the front plus a
    // platform suffix — so a digits-only check could not write an account's own value back.
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"0123456789-,"];
    if (![allowed isSupersetOfSet:[NSCharacterSet characterSetWithCharactersInString:storefront]]
        || !storefront.intValue) {
        warnf(@"%@ does not look like a storefront id; expected 143444 or 143444-1,29", storefront);
        return 64;
    }

    NSError *err = nil;
    if (!setAccountStorefront(storefront, &err)) {
        // Nothing to change is not a failure worth an error exit; every other case is.
        if ([err.domain isEqualToString:@"appstorectl"] && err.code == 5) return 0;
        warnf(@"could not set the storefront: %@", err.localizedDescription ?: @"unknown");
        printErrorChain(err, 1);
        return 1;
    }
    note(@"[+] storefront set. Saved locally and not validated until the next store call, which is");
    note(@"    also when the system appends the platform suffix, e.g. 143444 becomes 143444-2,29.");
    return 0;
}

static int cmdLibraryRaw(NSString *bundleID) {
    NSError *err = nil;
    NSArray<LibraryApp *> *apps = accountLibrary(@[bundleID], &err);
    if (!apps.count) {
        warnf(@"nothing for %@: %@", bundleID, err.localizedDescription ?: @"not in the library");
        return 1;
    }
    for (LibraryApp *app in apps) {
        note(@"preflightPackageURL = %@", app.preflightPackageURL ?: @"(nil)");
        note(@"redownloadParams    = %@", app.redownloadParams ?: @"(nil)");
        note(@"---- raw ----\n%@", app.rawDescription ?: @"(nil)");
    }
    return 0;
}

/// Dump the store's metadata lookup for a bundle id. Undocumented on purpose: it is a research
/// affordance, not a feature, and the shape it prints is Apple's, not ours.
static int cmdLookupRaw(NSString *bundleID) {
    NSError *err = nil;
    NSDictionary *item = storeLookupForBundleID(bundleID, &err);
    if (!item) {
        warnf(@"lookup failed for %@: %@", bundleID, err.localizedDescription ?: @"unknown");
        printErrorChain(err, 1);
        return 1;
    }
    note(@"%@", item);
    return 0;
}

static int cmdVersions(NSString *bundleID, NSString *paramsOverride, long long purchaseType) {
    NSString *name = nil;
    NSNumber *price = nil;
    NSNumber *adamID = resolveAdamID(bundleID, &name, &price);
    if (!adamID) { warnf(@"could not resolve an adamId for %@", bundleID); return 66; }
    if (price == nil || price.doubleValue != 0.0) {
        warnf(@"%@ is not a free app — appstorectl handles free apps only", bundleID);
        return 65;
    }

    // The metadata lookup is a plain read: no purchase, no sheet. It carries the build the store
    // would serve right now and its own buy-params string, which is a better starting point than a
    // hand-built one (it has pg=default and appExtVrsId, which ours does not).
    NSString *serverParams = paramsOverride;
    if (!serverParams) {
        NSError *lookupErr = nil;
        NSDictionary *item = storeLookupForBundleID(bundleID, &lookupErr);
        NSDictionary *ios = item[@"attributes"][@"platformAttributes"][@"ios"];
        id current = ios[@"externalVersionId"];
        if (current) note(@"[+] current build: evid %@  (minOS %@)", current,
                          ios[@"minimumOSVersion"] ?: @"?");

        id offers = ios[@"offers"];
        id params = [offers isKindOfClass:NSArray.class] ? [offers firstObject][@"buyParams"] : nil;
        if ([params isKindOfClass:NSString.class]) serverParams = params;
        else logLine(@"versions: no server buyParams (%@); using the built-in string",
                     lookupErr.localizedDescription ?: @"offers missing");
    }

    // The queue can raise a dialog mid-lookup, and an unanswered one stalls it until the timeout.
    Observers *observers = [Observers new];
    observers.autoAccept = YES;
    observers.bundleID   = bundleID;

    NSError *err = nil;
    NSDictionary *response = nil;
    NSArray<NSNumber *> *evids = storeEvidsForAdamID(adamID, bundleID, serverParams, purchaseType,
                                                     observers, &response, &err);
    // --ptype is a probe, so show what came back whatever happened. A fulfilled response is the
    // whole question: songList[0].URL is the download URL vpp hrn reads.
    if (purchaseType != 0)
        note(@"---- raw response (purchaseType %lld) ----\n%@", purchaseType, response ?: @"(nil)");
    if (!evids) {
        warnf(@"could not list older versions for %@: %@", bundleID,
              err.localizedDescription ?: @"unknown");
        printErrorChain(err, 1);
        // Say what is actually wrong rather than leaving a bare 500 on screen. This is a known
        // wall, not a transient failure — see store/versions.m for what was tried.
        note(@"    The version list only exists in a fulfilled purchase response, and MZBuy will");
        note(@"    not fulfil one from this process. The current build above still works with");
        note(@"    --evid, and any evid you have from elsewhere does too.");
        return 1;
    }

    note(@"[+] %lu version(s), oldest first. The last one is what a plain install gets.",
         (unsigned long)evids.count);
    NSUInteger offset = evids.count - 1;
    for (NSNumber *evid in evids) {
        note(@"    evid %-12@  offset %lu%@", evid, (unsigned long)offset,
             offset == 0 ? @"  (current)" : @"");
        offset--;
    }
    return 0;
}


// The dialog-carried buy params moved to store/buyparams.m when the version lookup needed the same
// extraction. This alias keeps the call sites below reading the way they always did.
static NSString *confirmBuyParamsFromError(NSError *err) { return serverBuyParamsFromError(err); }

// Not every sheet is the same sheet, and dismissing only works for one of them. Observed dialogs:
//
//   MZCommerce.ConfirmPaymentSheet       dialog.kind = Buy            dismissal works
//   MZCommerce.ConfirmPaymentSheet.Auth  dialog.kind = authorization  dismissal is useless
//   MZCommerce.TID.SignatureRequired     biometric signature          dismissal is useless
//
// The Buy sheet is pure confirmation, so a rejection still carries a usable confirmedPaymentUUID.
// The other two demand something a dismissal cannot produce — a password or a TID signature — and
// the buyParams they hand back are rejected on replay. Telling them apart is the difference between
// "retry once more" and "a human has to touch this device".
static NSString *storeDialogKind(NSError *err) {
    id payload = err.userInfo[@"AMSServerPayload"];
    if ([payload isKindOfClass:NSDictionary.class]) {
        id kind = [[payload objectForKey:@"dialog"] objectForKey:@"kind"];
        if ([kind isKindOfClass:NSString.class] && [kind length]) return kind;
    }

    // iOS 15.x renders the payload as a description string instead of a dictionary.
    for (NSString *key in err.userInfo) {
        if (![key hasPrefix:@"AMSServerPayload"]) continue;
        id value = err.userInfo[key];
        NSString *desc = [value isKindOfClass:NSString.class] ? value : [value description];
        NSRange at = [desc rangeOfString:@"kind = "];
        if (at.location == NSNotFound) continue;
        NSUInteger start = at.location + at.length;
        NSRange end = [desc rangeOfString:@";" options:0
                                    range:NSMakeRange(start, desc.length - start)];
        if (end.location == NSNotFound) continue;
        NSString *kind = [[desc substringWithRange:NSMakeRange(start, end.location - start)]
                          stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (kind.length) return kind;
    }
    return nil;
}

static void explainDialogKind(NSString *kind) {
    if (!kind.length) return;
    if ([kind caseInsensitiveCompare:@"authorization"] == NSOrderedSame) {
        note(@"[-] the store wants the Apple ID password — the sign-in session has expired.");
        note(@"    authpref governs the per-purchase password prompt, not the account session,");
        note(@"    so it cannot suppress this. Sign in once on the device (App Store app, or");
        note(@"    Settings -> App Store), then re-run.");
        return;
    }
    note(@"[-] store dialog kind '%@' cannot be answered by dismissing it", kind);
}

// Answer a pending confirmation sheet for this purchase. selectedButton 0 is the default
// ("ok" / Get in the ConfirmPaymentSheet); 1 is Cancel.
// Answer a pending confirmation sheet. Must be sent on the SAME service proxy that carried
// startPurchase: — fetching a second proxy (from either broker) tears down the in-flight reply and
// surfaces as NSCocoaErrorDomain 4099 "the message was sent over an additional proxy and therefore
// this proxy has become invalid".
static void answerPendingDialog(id svc, long long purchaseID, BOOL accept) {
    if (!svc) { note(@"[dialog] no purchase service"); return; }
    @try {
        [svc notifyDialogCompleteForPurchaseID:@(purchaseID)
                                        result:accept
                                selectedButton:accept ? 0 : 1
                             withResultHandler:^(void *a0, void *a1) { }];
        note(@"[dialog] answered purchaseID %lld with %@", purchaseID, accept ? @"Get" : @"Cancel");
    } @catch (NSException *e) {
        note(@"[dialog] notifyDialogComplete threw: %@", e.reason);
    }
}

#pragma mark - Install state

// The job list only shows in-flight work, so a small app can finish before the first poll. The
// bundle on disk is the ground truth: a placeholder is a couple of files, a real install has the
// executable and an SC_Info/*.sinf written at install time.
// The store writes the delivered version into the container's iTunesMetadata.plist, so read it
// from there rather than the app's own Info.plist — this is what the store actually served, which
// can differ from the newest listing when the device is below the app's minimum OS.
static NSString *installedVersionDescription(NSString *bundleID) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *root = @"/var/containers/Bundle/Application";
    for (NSString *uuid in [fm contentsOfDirectoryAtPath:root error:NULL]) {
        NSString *meta = [[root stringByAppendingPathComponent:uuid]
                          stringByAppendingPathComponent:@"iTunesMetadata.plist"];
        NSDictionary *md = [NSDictionary dictionaryWithContentsOfFile:meta];
        if (![md[@"softwareVersionBundleId"] isEqualToString:bundleID]) continue;

        NSString *shortVersion = md[@"bundleShortVersionString"];
        NSString *build        = md[@"bundleVersion"];
        id externalID          = md[@"softwareVersionExternalIdentifier"];

        NSMutableString *out = [NSMutableString string];
        [out appendString:shortVersion.length ? shortVersion : @"?"];
        if (build.length && ![build isEqualToString:shortVersion]) {
            [out appendFormat:@" (build %@)", build];
        }
        if (externalID) [out appendFormat:@"  externalVersionId %@", externalID];
        return out;
    }
    return nil;
}

// The container, not the .app: iTunesMetadata.plist is a sibling of the bundle, and export needs
// both. installedBundlePath() derives the .app from this.
NSString *installedContainerPath(NSString *bundleID) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *root = @"/var/containers/Bundle/Application";
    for (NSString *uuid in [fm contentsOfDirectoryAtPath:root error:NULL]) {
        NSString *container = [root stringByAppendingPathComponent:uuid];
        NSString *meta = [container stringByAppendingPathComponent:@"iTunesMetadata.plist"];
        NSDictionary *md = [NSDictionary dictionaryWithContentsOfFile:meta];
        if ([md[@"softwareVersionBundleId"] isEqualToString:bundleID]) return container;
    }
    return nil;
}

NSString *bundleInContainer(NSString *container) {
    if (!container) return nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *entry in [fm contentsOfDirectoryAtPath:container error:NULL]) {
        if ([entry hasSuffix:@".app"]) return [container stringByAppendingPathComponent:entry];
    }
    return nil;
}

static NSString *installedBundlePath(NSString *bundleID) {
    return bundleInContainer(installedContainerPath(bundleID));
}

BOOL isFullyInstalled(NSString *appPath) {
    if (!appPath) return NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *scInfo = [appPath stringByAppendingPathComponent:@"SC_Info"];
    NSArray *sc = [fm contentsOfDirectoryAtPath:scInfo error:NULL];
    for (NSString *f in sc) if ([f hasSuffix:@".sinf"]) return YES;
    return NO;
}

#pragma mark - Commands

typedef NS_ENUM(int, JobState) {
    kJobUnknown = -1,   // could not ask, or the answer was not usable
    kJobAbsent  =  0,   // asked, got a list, this bundle was not in it
    kJobPresent =  1,
};

/// Does appstored still hold a job for this bundle?
///
/// The install wait polls the filesystem for a sinf, which only ever answers "not yet". It cannot
/// tell "still downloading" from "appstored gave up minutes ago", and those need very different
/// waits. This asks the other side.
///
/// Three-valued on purpose. The caller aborts an install on `kJobAbsent`, so "I could not find
/// out" must never be reported as "there is no job": a missing class, a reply that never came, or
/// a payload that was not a list are all ignorance, not evidence. Collapsing them to NO would
/// abort a perfectly healthy install on any transient hiccup.
///
/// Same over-declared void* block as cmdJobs: the reply arity is undocumented and only slot 0 is
/// ever a real object.
static JobState jobStateFor(NSString *bundleID) {
    id jm = [[NSClassFromString(@"ASDJobManager") alloc] init];
    if (!jm) return kJobUnknown;

    __block JobState state = kJobUnknown;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [jm getJobsUsingBlock:^(void *a0, void *a1, void *a2) {
        id jobs = (a0 && !((uintptr_t)a0 & 7)) ? (__bridge id)a0 : nil;
        if ([jobs isKindOfClass:NSArray.class]) {
            state = kJobAbsent;                 // a real list; absence now means something
            for (id j in jobs) {
                // respondsToSelector, not a bare valueForKey: an ASDJob without that key would
                // raise NSUndefinedKeyException, and throwing here would take down an install that
                // is otherwise fine. cmdJobs can afford the bare call; this cannot.
                if (![j respondsToSelector:@selector(bundleID)]) continue;
                id bid = [j valueForKey:@"bundleID"];
                if ([bid isKindOfClass:NSString.class] && [bid isEqualToString:bundleID]) {
                    state = kJobPresent;
                    break;
                }
            }
        }
        dispatch_semaphore_signal(sem);
    }];

    // A timeout leaves state at kJobUnknown, which is the point: a slow appstored must not read as
    // a dropped job.
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5ull * NSEC_PER_SEC)) != 0)
        return kJobUnknown;
    return state;
}

// A full app purchase ignores ASDPurchase.createsJobs=NO (that flag is for IAPs). Cancel the
// resulting job by its persistentID, which is the same identifier asclient's `jobs cancel` uses.
static BOOL cancelInstallJobForBundleID(NSString *bundleID) {
    ASDJobManager *manager = [NSClassFromString(@"ASDJobManager") new];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];

    while (deadline.timeIntervalSinceNow > 0) {
        __block NSNumber *jobID = nil;
        dispatch_semaphore_t listed = dispatch_semaphore_create(0);
        [manager getJobsUsingBlock:^(void *a0, void *a1, void *a2) {
            id jobs = (a0 && !((uintptr_t)a0 & 7)) ? (__bridge id)a0 : nil;
            if ([jobs isKindOfClass:NSArray.class]) {
                for (ASDJob *job in jobs) {
                    if ([job.bundleID isEqualToString:bundleID]) {
                        jobID = @(job.persistentID);
                        break;
                    }
                }
            }
            dispatch_semaphore_signal(listed);
        }];
        dispatch_semaphore_wait(listed, dispatch_time(DISPATCH_TIME_NOW, 2ull * NSEC_PER_SEC));

        if (jobID) {
            __block BOOL completed = NO;
            dispatch_semaphore_t cancelled = dispatch_semaphore_create(0);
            [manager cancelJobsWithIDs:@[jobID] completionBlock:^{
                completed = YES;
                dispatch_semaphore_signal(cancelled);
            }];
            dispatch_semaphore_wait(cancelled,
                                    dispatch_time(DISPATCH_TIME_NOW, 10ull * NSEC_PER_SEC));
            logLine(@"purchase: cancel job %@ completed=%d", jobID, completed);
            return completed;
        }
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
    }

    logLine(@"purchase: no install job appeared for %@", bundleID);
    return YES;
}

static int cmdInstall(NSString *bundleID, NSNumber *adamID, NSNumber *evid, BOOL autoAccept,
                      BOOL autoConfirm, BOOL forceDismiss, BOOL purchaseOnly) {
    logLine(@"%@: begin bundle=%@ adamOverride=%@ accept=%d tryConfirm=%d forceDismiss=%d",
            purchaseOnly ? @"purchase" : @"install", bundleID, adamID ?: @"(none)",
            autoAccept, autoConfirm, forceDismiss);
    // Free-only, and the gate has to be explicit. The buy params below hardcode price=0 and now
    // also assert hasBeenAuthedForBuy / hasConfirmedPaymentSheet, which tell the store the user has
    // already seen and approved a payment sheet. On a free app that is true by construction — there
    // is no sheet to approve. On a paid app it would be a lie that could complete a real charge
    // with nothing shown on screen. asclient guards the same two params with
    // `price == 0.0 || owned` (-[Installer _purchaseApp:], 0x100111db0); this is that guard.
    //
    // An explicit --adam skips the lookup, so there is no price to check. That is not a refusal:
    // --adam exists for bundle IDs the device storefront will not resolve. It just means the two
    // params are withheld and the purchase falls back to the sheet-and-replay route, which is what
    // every install did before.
    BOOL knownFree = NO;
    if (!adamID) {
        NSString *name = nil;
        NSNumber *price = nil;
        adamID = resolveAdamID(bundleID, &name, &price);
        if (!adamID) {
            warnf(@"could not resolve an adamId for %@ — check the bundle ID, or pass --adam",
                  bundleID);
            return 66;
        }
        knownFree = (price != nil && price.doubleValue == 0.0);
        if (price != nil && !knownFree) {
            warnf(@"%@ costs %@ — appstorectl handles free apps only", bundleID, price);
            return 65;
        }
        if (!knownFree)
            warnf(@"lookup returned no price for %@; treating it as paid", bundleID);
    } else {
        note(@"[=] --adam given, so the price is unknown; using the sheet-and-replay path");
    }

    if (!purchaseOnly && isFullyInstalled(installedBundlePath(bundleID))) {
        note(@"[=] %@ is already installed", bundleID);
        note(@"[=] version:   %@", installedVersionDescription(bundleID) ?: @"(unknown)");
        return 0;
    }

    id center = [NSClassFromString(@"ASDNotificationCenter") defaultCenter];
    Observers *obs = [Observers new];
    obs.autoAccept = autoAccept;
    obs.bundleID   = bundleID;
    [center setDialogObserver:obs];
    [center addProgressObserver:obs];

    ASDPurchase *p  = [NSClassFromString(@"ASDPurchase") new];
    p.bundleID      = bundleID;                 // mandatory: the install coordinator is keyed by it
    p.itemID        = adamID;
    // hasBeenAuthedForBuy / hasConfirmedPaymentSheet are what Apple's own asclient sets on the
    // FIRST attempt whenever the app is free or already owned, before the store has raised
    // anything: -[Installer _purchaseApp:] (asclient 0x100111db0). appstorectl only ever saw them
    // come back inside a rejection's okButtonAction.buyParams. Sending them up front stops the
    // sheet being raised at all rather than dismissing it afterwards — measured 3/3 on 16.7.12
    // with the AutoConfirmSheet tweak removed from the device entirely.
    //
    // Only when the lookup said the price is 0. See the gate above for why that matters.
    // STDQ buys, STDRDL redownloads. Sending STDQ for something already in the locker asks the
    // store for the wrong thing; asclient picks on the owned flag
    // (-[Installer _purchaseApp:] 0x100111db0), and appstored's own cached redownload-params for an
    // installed app read pricingParameters=STDRDL. The locker query is a round trip through
    // appstored, so a failure here is not fatal — fall back to STDQ, which is what shipped before.
    NSError *libErr = nil;
    LibraryApp *owned = libraryEntryForBundleID(bundleID, &libErr);
    if (libErr) logLine(@"%@: locker lookup failed (%@); assuming not owned",
                        purchaseOnly ? @"purchase" : @"install", libErr.localizedDescription);
    if (purchaseOnly && owned) {
        [center removeProgressObserver:obs];
        note(@"[=] %@ is already owned by this account", bundleID);
        return 0;
    }
    NSString *pricing = owned ? @"STDRDL" : @"STDQ";
    if (owned) note(@"[=] already in this account's library; redownloading");

    p.buyParameters = knownFree
        ? [NSString stringWithFormat:
              @"salableAdamId=%@&productType=C&price=0&pricingParameters=%@"
              @"&hasBeenAuthedForBuy=true&hasConfirmedPaymentSheet=true", adamID, pricing]
        : [NSString stringWithFormat:
              @"salableAdamId=%@&productType=C&price=0&pricingParameters=%@", adamID, pricing];
    p.isRedownload = owned != nil;
    // Pin a specific build. appExtVrsId is the key on the normal (DSID-carrying) path;
    // externalVersionId is the DSID-less spelling, and asclient sends that one only when it is
    // installing DSID-less: -[Installer _purchaseApp:] (0x100111db0). We are never DSID-less here.
    //
    // `appstorectl versions <bundle-id>` lists what the store will serve.
    if (evid) {
        p.buyParameters = [p.buyParameters stringByAppendingFormat:@"&appExtVrsId=%@", evid];
        note(@"[+] pinning external version id %@", evid);
    }
    p.createsJobs   = !purchaseOnly;
    p.clientID      = @"com.apple.AppStore";
    // Mandatory and easy to miss: purchaseID defaults to 0, and a job with purchaseID 0 is never
    // correlated to its purchase, so appstored parks it at phase 9 forever with no error at all.
    // AutoConfirmSheet consumes this flag when the purchase sheet appears and rejects it after five
    // minutes. We still remove it on every normal exit so it normally exists only during this call.
    NSString *const kAutoConfirmFlag = @"/var/jb/tmp/.autoconfirm";
    NSString *const kAutoConfirmDylib =
        @"/var/jb/Library/MobileSubstrate/DynamicLibraries/AutoConfirmSheet.dylib";
    NSFileManager *files = NSFileManager.defaultManager;
    // Since the buy params above stop the sheet being raised at all, this normally arms a flag
    // nothing ever reads. Do not claim the tweak will dismiss a sheet when the tweak is not even
    // installed — the old line said that on every run and it was not true on any of them.
    BOOL tweakInstalled = [files fileExistsAtPath:kAutoConfirmDylib];
    if (forceDismiss) {
        [files removeItemAtPath:kAutoConfirmFlag error:NULL];
        if (![files createFileAtPath:kAutoConfirmFlag contents:nil attributes:nil]) {
            warnf(@"could not arm AutoConfirmSheet at %@", kAutoConfirmFlag);
            return 3;
        }
        // /var/jb/tmp is sticky. PassbookUIService runs as mobile, so it can consume the one-shot
        // flag only when mobile owns the file created here by root.
        if (chown(kAutoConfirmFlag.fileSystemRepresentation, 501, (gid_t)-1) != 0) {
            warnf(@"could not transfer AutoConfirmSheet flag to mobile: %s", strerror(errno));
            [files removeItemAtPath:kAutoConfirmFlag error:NULL];
            return 3;
        }
        if (tweakInstalled) {
            note(@"[+] force-dismiss armed; AutoConfirmSheet is installed");
        } else {
            // The package stopped shipping the tweak, so this is the normal case now, not an edge
            // one. Say it on the terminal: someone passing --force-dismiss is expecting a sheet to
            // be handled, and silently arming a flag nothing reads would let them wait for it.
            warnf(@"--force-dismiss armed, but AutoConfirmSheet is not installed, so nothing will "
                   "dismiss a sheet. It is not in this package; build it from tweak/ if you need it.");
        }
    }
    void (^disarm)(void) = ^{
        if (!forceDismiss) return;
        [files removeItemAtPath:kAutoConfirmFlag error:NULL];
        if ([files fileExistsAtPath:kAutoConfirmFlag])
            warnf(@"could not remove AutoConfirmSheet flag at %@", kAutoConfirmFlag);
        else
            logLine(@"force-dismiss disarmed");
    };

    note(@"[+] purchasing %@ (adamId %@)", bundleID, adamID);

    // Talk to the purchase service directly rather than through ASDPurchaseManager, so the
    // purchase and the dialog answer travel over one proxy. Hold it for the whole call.
    NSError *svcErr = nil;
    id svc = [[NSClassFromString(@"ASDServiceBroker") defaultBroker] getPurchaseServiceWithError:&svcErr];
    if (!svc) {
        // 505 here is "Not entitled for this service", i.e. com.apple.itunesstored.private did not
        // apply, usually a stale cached code signature.
        warnf(@"could not reach the purchase service: %@",
              svcErr.localizedDescription ?: @"unknown");
        printErrorChain(svcErr, 1);
        disarm();
        return 3;
    }
    logLine(@"purchase service proxy acquired");

    __block BOOL ok = NO;
    __block NSString *retryParams = nil;
    // Kept so a rejected retry can report what the store actually said. Without it the only clue
    // is our own summary line, and a retry that fails *with* a dialog payload prints nothing at
    // all — which is precisely the case worth diagnosing.
    __block NSError *lastError = nil;

    // One purchase attempt. Returns via the two __block vars above.
    BOOL (^attempt)(NSString *) = ^BOOL(NSString *params) {
        p.buyParameters = params;
        // Fresh id per attempt so the retry is not deduped onto the first one.
        p.purchaseID    = (long long)(arc4random_uniform(8000000) + 1000000);
        long long pid   = p.purchaseID;
        ok = NO; retryParams = nil;
        note(@"    attempt with purchaseID %lld", pid);
        // Never printed: it is a long query string and it carries confirmedPaymentUUID and guid.
        // It is also the single most useful thing to have when reconstructing why a purchase went
        // the way it did, which is what the 0600 log is for.
        logLine(@"    buyParameters: %@", params ?: @"(nil)");
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);

        // The sheet is presented by AMS, not routed to our dialog observer, so we cannot intercept
        // it. We can however answer it by purchase id once it is up. Retry a few times because we
        // are never told when it appears.
        if (autoConfirm) {
            for (int delay = 2; delay <= 8; delay += 3) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)delay * NSEC_PER_SEC),
                               dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                    if (!ok) answerPendingDialog(svc, pid, YES);
                });
            }
        }

        // The confirmation sheet is drawn by PassbookUIService (verified: it spawns exactly when
        // the purchase starts, and terminating it dismisses the sheet). Dismissing — not
        // confirming — is enough: the rejection carries confirmedPaymentUUID, which the retry
        // below replays to complete the purchase silently.
        //
        // This is blunt, hence the flag. It is scoped to our own in-flight purchase, and
        // PassbookUIService is launch-on-demand so it simply respawns when next needed.
        if (forceDismiss) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6ull * NSEC_PER_SEC),
                           dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                if (ok) return;
                pid_t child = 0;
                const char *tool = "/usr/bin/killall";
                char *const args[] = { (char *)tool, (char *)"-9",
                                       (char *)"PassbookUIService", NULL };
                if (posix_spawn(&child, tool, NULL, NULL, args, NULL) == 0) {
                    int st = 0; waitpid(child, &st, 0);
                    note(@"[dismiss] closed the payment sheet");
                }
            });
        }
        [svc startPurchase:p withReplyHandler:^(ASDPurchaseResult *r, NSError *e) {
                ok = r.success;
                if (!r.success) {
                    NSError *err = r.error ?: e;
                    lastError   = err;
                    retryParams = confirmBuyParamsFromError(err);
                    // Which dialog refused and whether it handed back replayable params. This is
                    // the pair that decides whether the loop continues, and neither is printed.
                    logLine(@"purchaseID %lld failed: %@ %ld dialog=%@ retryParams=%@",
                            pid, err.domain, (long)err.code,
                            storeDialogKind(err) ?: @"(none)",
                            retryParams.length ? @"yes" : @"no");
                    if (!retryParams) {
                        NSDictionary *payload = err.userInfo[@"AMSServerPayload"];
                        NSString *dialogID = payload[@"metrics"][@"dialogId"];
                        if ([dialogID isEqualToString:@"MZCommerce.ProductRequiresLaterStoreVersion"]) {
                            note(@"[-] %@", payload[@"customerMessage"] ?: @"This app requires a newer iOS version.");
                            note(owned
                                ? @"    Apple did not offer a compatible older build for this device."
                                : @"    Acquire it once on a compatible device, then retry here.");
                        } else {
                            note(@"[-] purchase failed");
                            describeError(err);
                        }
                    }
                } else {
                    logLine(@"purchaseID %lld succeeded", pid);
                }
                dispatch_semaphore_signal(sem);
            }];
        return dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 180ull*NSEC_PER_SEC)) == 0;
    };

    if (!attempt(p.buyParameters)) {
        note(@"[-] timed out waiting for the purchase");
        disarm();
        return 4;
    }

    // The store asked for confirmation and told us what to resend. Do exactly that.
    // With --force-dismiss the tweak dismisses the sheet and this path is usually not needed.
    //
    // It can ask more than once, and a single retry is not enough. Observed on a free install
    // whose account had freeDownloadsPasswordSetting unset (0):
    //
    //   attempt 1 -> MZCommerce.ConfirmPaymentSheet
    //   attempt 2 -> MZCommerce.ASN.AlwaysSometimes.MediaAndPurchases
    //                "Require password for additional purchases on this device?"
    //
    // Each rejection carries its own okButtonAction.buyParams, so the second one is the server
    // telling us how to answer the ASN question (asn=2, "Require After 15 Minutes") while keeping
    // the confirmedPaymentUUID from the first. Replaying it is answering the dialog, and it needs
    // no dialog observer, which is why this path is preferred over --accept.
    //
    // Bounded two ways: a hard cap, and a check that the params actually changed. Identical
    // buyParams twice means the replay is not making progress and looping would only spend
    // purchase attempts against the store.
    NSMutableSet *seenParams = [NSMutableSet set];
    BOOL replayed = NO;
    for (int round = 1; !ok && retryParams.length && round <= 4; round++) {
        if ([seenParams containsObject:retryParams]) {
            note(@"[-] store repeated the same buyParams; not replaying again");
            break;
        }
        [seenParams addObject:retryParams];

        note(@"[+] store returned a dialog with confirmedPaymentUUID; resending (round %d)", round);
        replayed = YES;
        if (!attempt(retryParams)) { note(@"[-] retry timed out"); disarm(); return 4; }
    }

    // Only report a rejection for a replay we actually made. A first attempt that failed without
    // any buyParams has already printed its own diagnosis inside the attempt block.
    if (!ok && replayed) {
        note(@"[-] retry rejected by the store");
        describeError(lastError);
        explainDialogKind(storeDialogKind(lastError));
    }

    disarm();   // the sheet is behind us either way; do not leave the tweak armed
    if (!ok) return 1;
    if (purchaseOnly) {
        [center removeProgressObserver:obs];
        if (!cancelInstallJobForBundleID(bundleID)) {
            warnf(@"license acquired, but the install job could not be canceled");
            return 6;
        }
        if (isFullyInstalled(installedBundlePath(bundleID))) {
            warnf(@"license acquired, but %@ finished installing before cancellation", bundleID);
            return 6;
        }
        note(@"[+] license acquired; install canceled");
        return 0;
    }
    note(@"[+] purchased, waiting for install");

    // Poll disk for completion; progress lines arrive asynchronously from the observer meanwhile.
    //
    // Disk alone is not enough. It answers "no sinf yet" identically whether the download is still
    // running or appstored dropped the job ten minutes ago, so a dead install used to burn the full
    // 600 s and then blame the clock. Watch the job list too.
    BOOL sawJob = NO;
    int absentPolls = 0;

    for (int elapsed = 0; elapsed < 600; elapsed += 2) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:2]];
        NSString *app = installedBundlePath(bundleID);
        if (isFullyInstalled(app)) {
            [center removeProgressObserver:obs];
            NSString *version = installedVersionDescription(bundleID);
            note(@"[+] installed: %@", app);
            note(@"[+] version:   %@", version ?: @"(unknown)");
            return 0;
        }

        if (elapsed % 6) continue;               // ask appstored every ~6 s, not every 2 s

        // Only a definite kJobAbsent counts against the install. kJobUnknown means the question
        // could not be answered, and that must behave exactly like "job present" here: never
        // abandon an install on the strength of not knowing.
        JobState js = jobStateFor(bundleID);
        if (js != kJobAbsent) {
            if (js == kJobPresent) sawJob = YES;
            absentPolls = 0;
            continue;
        }

        // Nothing has started yet. A job can take a moment to appear after the purchase, so an
        // empty list this early means "not yet", not "gone".
        if (!sawJob && !obs.sawProgress) continue;

        // Two independent signals, deliberately. Aborting a healthy install is far worse than
        // waiting out a dead one, and the job list alone is not trustworthy enough to act on: it is
        // not known whether it goes briefly empty at the download-to-install handoff, and a wrong
        // guess there would kill a working install of a large app.
        //
        // So the job must be absent AND nothing must have reported progress for a while. An install
        // still emitting bytes is never abandoned, whatever the list says.
        static const double kQuietSeconds = 45.0;
        double quiet = obs.sawProgress ? CFAbsoluteTimeGetCurrent() - obs.lastProgressAt : 0.0;
        if (obs.sawProgress && quiet < kQuietSeconds) { absentPolls = 0; continue; }

        // And require the absence to persist, so a single missed reply cannot end the run. The
        // 5 s timeout inside jobExistsFor reports "no job" on a slow reply, which is exactly the
        // case this guards against.
        if (++absentPolls < 3) continue;

        [center removeProgressObserver:obs];
        logLine(@"install: no job for %@ after %ds, %.0fs since last progress, no sinf",
                bundleID, elapsed, quiet);
        warnf(@"[-] appstored has no job for %@ and it never finished installing", bundleID);
        warnf(@"    (%ds waited, %.0fs since the last progress report)", elapsed, quiet);
        warnf(@"    A Home Screen placeholder is usually left behind; clear it with:");
        warnf(@"        appstorectl uninstall %@", bundleID);
        return 6;
    }

    note(@"[-] gave up waiting after 10 minutes; check `appstorectl jobs`");
    return 5;
}

static int cmdUninstall(NSString *bundleID) {
    NSString *app = installedBundlePath(bundleID);
    // 66 (EX_NOINPUT), matching export, rather than 0. Both are asked to act on an installed app
    // and neither can, so they should not disagree about whether that is a failure. A script that
    // treats 0 as "it is gone now" would otherwise never notice it had the wrong bundle ID.
    if (!app) { warnf(@"%@ is not installed", bundleID); return 66; }

    // MobileInstallation is the right API, but ipainstaller ships with the bootstrap and handles
    // LaunchServices deregistration correctly, so spawn it rather than reimplement it.
    // posix_spawn rather than system() so the bundle ID never goes through a shell.
    const char *tool = "/var/jb/usr/bin/ipainstaller";
    char *const args[] = { (char *)tool, (char *)"-u", (char *)bundleID.UTF8String, NULL };
    logLine(@"exec %s -u %@", tool, bundleID);
    pid_t pid = 0;
    if (posix_spawn(&pid, tool, NULL, NULL, args, NULL) != 0) {
        warnf(@"could not run ipainstaller: %s", strerror(errno));
        return 1;
    }
    int status = 0;
    waitpid(pid, &status, 0);
    logLine(@"ipainstaller pid %d exited %d", pid, WIFEXITED(status) ? WEXITSTATUS(status) : -1);
    return (WIFEXITED(status) && WEXITSTATUS(status) == 0) ? 0 : 1;
}

static int cmdJobs(void) {
    id jm = [[NSClassFromString(@"ASDJobManager") alloc] init];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [jm getJobsUsingBlock:^(void *a0, void *a1, void *a2) {
        id jobs = (a0 && !((uintptr_t)a0 & 7)) ? (__bridge id)a0 : nil;
        if (![jobs isKindOfClass:NSArray.class] || ![jobs count]) {
            printf("no active jobs\n");
        } else {
            for (id j in jobs)
                printf("%-40s phase=%-3s pct=%-6s purchaseID=%s\n",
                    [[j valueForKey:@"bundleID"] UTF8String] ?: "?",
                    [[[j valueForKey:@"phase"] description] UTF8String],
                    [[[j valueForKey:@"percentComplete"] description] UTF8String],
                    [[[j valueForKey:@"purchaseID"] description] UTF8String]);
        }
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 20ull * NSEC_PER_SEC));
    return 0;
}

static void usage(void) {
    fprintf(stderr,
        "appstorectl — install and export free App Store apps from the shell\n\n"
        "Commands:\n"
        "  appstorectl purchase  <bundle-id> [--adam <id>]\n"
        "  appstorectl install   <bundle-id> [--adam <id>] [--evid <id>] [-o <path>]\n"
        "  appstorectl export    <bundle-id> [-o <path>]\n"
        "  appstorectl resolve   <bundle-id>\n"
        "  appstorectl search    <term> [-l <count>]\n"
        "  appstorectl versions  <bundle-id>\n"
        "  appstorectl library   [<bundle-id>]\n"
        "  appstorectl storefront [<id>]\n"
        "  appstorectl uninstall <bundle-id>\n"
        "  appstorectl jobs\n"
        "  appstorectl version\n\n"
        "Account commands:\n"
        "  appstorectl accounts\n"
        "  appstorectl login    <apple-id> [--password-file <path>] [--show-password] [--no-bootstrap]\n"
        "  appstorectl logout   <apple-id> [--force]\n\n"
        "Install options:\n"
        "  --no-export       install only; do not create an IPA\n"
        "  --no-decrypt      export an encrypted IPA (cryptid 1)\n"
        "  --no-preflight    skip the biometric-state check\n"
        "  --adam <id>       skip lookup and use this adamId\n"
        "  --evid <id>       install a specific build\n"
        "  --accept          affirmatively answer other store dialogs\n"
        "  --try-confirm     try the legacy confirmation-sheet answer\n"
        "  -o <path>         export destination\n"
        "  -q                print only errors\n");
}

int main(int argc, char **argv) {
    setbuf(stdout, NULL);
    @autoreleasepool {
        // Before the argc check, so even a malformed invocation leaves a trace. An install that
        // cannot be explained later is the whole reason this file exists.
        logBeginSession(argc, argv);

        if (argc < 2) { usage(); return logEndSession(64); }
        if (!strcmp(argv[1], "version")) {
            printf("appstorectl %s\n", APPSTORECTL_VERSION);
            return logEndSession(0);
        }
        if (!dlopen("/System/Library/PrivateFrameworks/AppStoreDaemon.framework/AppStoreDaemon",
                    RTLD_NOW)) {
            fprintf(stderr, "dlopen AppStoreDaemon failed: %s\n", dlerror());
            logLine(@"dlopen AppStoreDaemon failed: %s", dlerror());
            return logEndSession(2);
        }
        // AppStoreDaemon pulls this in already, but the dialog answer depends on AMSDialogResult
        // being present and a missing class there is a silent decline rather than an error.
        if (!dlopen("/System/Library/PrivateFrameworks/AppleMediaServices.framework/AppleMediaServices",
                    RTLD_NOW))
            logLine(@"dlopen AppleMediaServices failed: %s", dlerror());

        NSString *cmd = @(argv[1]);
        NSMutableArray<NSString *> *pos = [NSMutableArray array];
        NSNumber *adamOverride = nil;
        BOOL autoAccept = NO;
        // Off by default: notifyDialogCompleteForPurchaseID: is accepted by the daemon but does
        // NOT dismiss the AMS-presented confirmation sheet, because AMS never registered a pending
        // dialog for this purchase. Leaving it on just burns the 180s timeout when nobody is
        // watching the screen. Kept behind a flag because it is the right API if Apple ever routes
        // payment sheets through the dialog delegate.
        BOOL autoConfirm = NO;
        // On by default. This is the flow that gets run every time: buy it, get it off the device,
        // get it readable. The opt-outs exist for the rare run that wants something narrower, and
        // the old positive flags are still accepted so nothing already scripted breaks.
        // Off by default since the buy params stop the sheet being raised at all on the free-app
        // path. --force-dismiss turns it back on for the cases that path does not cover: --adam,
        // which withholds the preauth params, and any account state not yet mapped (Ask to Buy, a
        // biometric requirement, freeDownloadsPasswordSetting still unset).
        BOOL forceDismiss = NO;
        BOOL alsoExport = YES;
        BOOL decryptExport = YES;
        BOOL skipPreflight = NO;
        BOOL force = NO;
        BOOL showPassword = NO;
        BOOL allowBootstrap = YES;
        NSString *exportPath = nil;
        NSString *passwordFile = nil;
        NSNumber *evid = nil;
        NSString *paramsOverride = nil;
        long long purchaseType = 0;
        NSInteger searchLimit = 5;

        for (int i = 2; i < argc; i++) {
            NSString *a = @(argv[i]);
            if ([a isEqualToString:@"--accept"])        { autoAccept = YES;   continue; }
            if ([a isEqualToString:@"--try-confirm"])   { autoConfirm = YES;  continue; }
            // Accepted and redundant: these are the defaults now. Kept so existing invocations
            // keep working rather than dying on an unknown argument.
            if ([a isEqualToString:@"--force-dismiss"]) { forceDismiss = YES; continue; }
            if ([a isEqualToString:@"--export"])        { alsoExport = YES;   continue; }
            if ([a isEqualToString:@"--decrypt"])       { decryptExport = YES; continue; }

            if ([a isEqualToString:@"--no-dismiss"])    { forceDismiss = NO;  continue; }
            if ([a isEqualToString:@"--no-export"])     { alsoExport = NO;    continue; }
            if ([a isEqualToString:@"--no-decrypt"])    { decryptExport = NO; continue; }
            if ([a isEqualToString:@"--no-preflight"])  { skipPreflight = YES; continue; }
            if ([a isEqualToString:@"--force"])         { force = YES;      continue; }
            if ([a isEqualToString:@"--show-password"]) { showPassword = YES; continue; }
            if ([a isEqualToString:@"--no-bootstrap"])  { allowBootstrap = NO; continue; }
            if ([a isEqualToString:@"-q"])         { gQuiet = YES;     continue; }
            if ([a isEqualToString:@"--password-file"] && i + 1 < argc) {
                passwordFile = @(argv[++i]);
                continue;
            }
            if ([a isEqualToString:@"-o"] && i + 1 < argc) {
                exportPath = @(argv[++i]);
                continue;
            }
            if ([a isEqualToString:@"--adam"] && i + 1 < argc) {
                adamOverride = @(atoll(argv[++i]));
                continue;
            }
            if ([a isEqualToString:@"--ptype"] && i + 1 < argc) {
                purchaseType = atoll(argv[++i]);
                continue;
            }
            if ([a isEqualToString:@"--params"] && i + 1 < argc) {
                paramsOverride = @(argv[++i]);
                continue;
            }
            if ([a isEqualToString:@"--evid"] && i + 1 < argc) {
                evid = @(atoll(argv[++i]));
                continue;
            }
            if ([a isEqualToString:@"--limit"] || [a isEqualToString:@"-l"]) {
                searchLimit = ++i < argc ? atol(argv[i]) : 0;
                continue;
            }
            [pos addObject:a];
        }

        // Internal, re-exec'd as mobile by biometricPreflight(). Not in usage on purpose.
        if ([cmd isEqualToString:@"_biometric-preflight"]) return logEndSession(cmdBiometricPreflight());

        if ([cmd isEqualToString:@"jobs"])     return logEndSession(cmdJobs());
        // Account commands take an Apple ID, not a bundle ID, so they are dispatched before the
        // positional argument below is named `bundleID`.
        if ([cmd isEqualToString:@"accounts"]) return logEndSession(cmdAccounts());
        if ([cmd isEqualToString:@"storefront"]) return logEndSession(cmdStorefront(pos.count ? pos[0] : nil));
        if ([cmd isEqualToString:@"library"])  return logEndSession(cmdLibrary(pos.count ? pos[0] : nil));
        if ([cmd isEqualToString:@"search"]) {
            if (!pos.count || searchLimit < 1 || searchLimit > 200) {
                warnf(@"usage: appstorectl search <term> [-l 1..200]");
                return logEndSession(64);
            }
            return logEndSession(cmdSearch([pos componentsJoinedByString:@" "], searchLimit));
        }
        if (pos.count < 1) { usage(); return logEndSession(64); }
        if ([cmd isEqualToString:@"login"])    return logEndSession(cmdLogin(pos[0], passwordFile, showPassword, allowBootstrap));
        if ([cmd isEqualToString:@"logout"])   return logEndSession(cmdLogout(pos[0], force));

        NSString *bundleID = pos[0];

        if ([cmd isEqualToString:@"resolve"]) {
            // Say so. resolveAdamID only prints on success, so a miss used to exit 66 having
            // written nothing at all, which reads as the tool doing nothing rather than as a
            // bundle ID that is not in this storefront.
            if (resolveAdamID(bundleID, NULL, NULL)) return logEndSession(0);
            warnf(@"could not resolve an adamId for %@ — check the bundle ID, or try another "
                   "storefront; the lookup follows the device locale, not the active account",
                  bundleID);
            return logEndSession(66);
        }
        if ([cmd isEqualToString:@"_lookup-raw"])  return logEndSession(cmdLookupRaw(bundleID));
        if ([cmd isEqualToString:@"_library-raw"]) return logEndSession(cmdLibraryRaw(bundleID));
        if ([cmd isEqualToString:@"versions"])  return logEndSession(cmdVersions(bundleID, paramsOverride, purchaseType));
        if ([cmd isEqualToString:@"uninstall"]) return logEndSession(cmdUninstall(bundleID));
        if ([cmd isEqualToString:@"export"])    return logEndSession(cmdExport(bundleID, exportPath, decryptExport));
        if ([cmd isEqualToString:@"purchase"]) {
            if (evid) {
                warnf(@"--evid is only valid with install");
                return logEndSession(64);
            }
            if (!skipPreflight) biometricPreflight();
            return logEndSession(cmdInstall(bundleID, adamOverride, nil, autoAccept, autoConfirm,
                                            forceDismiss, YES));
        }
        if ([cmd isEqualToString:@"install"]) {
            // Before spending a purchase: if the account is opted into a biometric this device
            // cannot perform, the store will demand a password no dismissal can answer. Clearing
            // that is the difference between a hands-off install and a dead end.
            if (!skipPreflight) biometricPreflight();

            int rc = cmdInstall(bundleID, adamOverride, evid, autoAccept, autoConfirm, forceDismiss,
                                NO);
            // Only package what actually installed — exporting after a failed install would either
            // error confusingly or silently archive a stale copy from an earlier run.
            if (rc != 0 || !alsoExport) return logEndSession(rc);
            return logEndSession(cmdExport(bundleID, exportPath, decryptExport));
        }

        usage();
        return logEndSession(64);
    }
}
