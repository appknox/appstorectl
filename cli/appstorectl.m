// appstorectl — buy and install an App Store app from the shell, by bundle id.
//
//   appstorectl install   <bundle-id> [--adam <id>] [--accept]
//   appstorectl resolve   <bundle-id>
//   appstorectl uninstall <bundle-id>
//   appstorectl jobs
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
#import <objc/runtime.h>
#import <spawn.h>
#import <sys/wait.h>

#import "ASDPrivate.h"

#pragma mark - Small helpers

static BOOL gQuiet = NO;

static void note(NSString *fmt, ...) {
    if (gQuiet) return;
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    printf("%s\n", s.UTF8String);
}

static NSString *humanBytes(long long b) {
    if (b <= 0) return @"0 B";
    static const char *u[] = {"B", "KB", "MB", "GB"};
    double v = (double)b; int i = 0;
    while (v >= 1024.0 && i < 3) { v /= 1024.0; i++; }
    return [NSString stringWithFormat:@"%.1f %s", v, u[i]];
}

#pragma mark - adamId resolution

// The store's own lookup endpoint. We try the device's App Store country first, then bare (which
// defaults to US), because a bundle id can be absent from one storefront and present in another.
static NSString *deviceCountryCode(void) {
    // The active storefront lives in itunesstored's prefs as e.g. "143441-1,29". Mapping every
    // storefront id to an ISO country is not worth it; the device region gets it right in
    // practice and the bare query covers the rest.
    NSString *cc = [[NSLocale currentLocale] objectForKey:NSLocaleCountryCode];
    return cc.length == 2 ? [cc lowercaseString] : nil;
}

static NSNumber *resolveAdamID(NSString *bundleID, NSString **outName) {
    NSMutableArray<NSString *> *urls = [NSMutableArray array];
    NSString *cc = deviceCountryCode();
    if (cc) [urls addObject:[NSString stringWithFormat:
        @"https://itunes.apple.com/lookup?bundleId=%@&country=%@", bundleID, cc]];
    [urls addObject:[NSString stringWithFormat:
        @"https://itunes.apple.com/lookup?bundleId=%@", bundleID]];

    for (NSString *u in urls) {
        NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:u]];
        if (!data.length) continue;
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        NSArray *results = j[@"results"];
        if (![results isKindOfClass:NSArray.class] || !results.count) continue;

        NSDictionary *r = results.firstObject;
        NSNumber *trackId = r[@"trackId"];
        if (![trackId isKindOfClass:NSNumber.class]) continue;
        if (outName) *outName = r[@"trackName"];
        note(@"[+] %@  ->  adamId %@   (%@, %@ %@, minOS %@)",
             bundleID, trackId, r[@"trackName"] ?: @"?",
             r[@"price"] ?: @"?", r[@"currency"] ?: @"", r[@"minimumOsVersion"] ?: @"?");
        return trackId;
    }
    return nil;
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
@end

@implementation Observers

- (void)handleDialogRequest:(id)request resultHandler:(id)handler {
    note(@"[dialog] store requested a dialog");
    [self answer:handler what:"dialog"];
}

- (void)handleAuthenticateRequest:(id)request resultHandler:(id)handler {
    note(@"[auth] store requested authentication");
    [self answer:handler what:"auth"];
}

- (void)answer:(id)handler what:(const char *)what {
    if (!handler) return;
    @try {
        void (^blk)(BOOL, id) = handler;
        blk(self.autoAccept, nil);
        note(@"[%s] answered %@", what, self.autoAccept ? @"accept" : @"decline");
    } @catch (NSException *e) {
        note(@"[%s] could not answer: %@", what, e.reason);
    }
}

// appstored delivers an NSArray of ASDProgress here, not a single object — the selector name is
// singular but the payload is not.
- (void)notificationCenter:(id)center receivedProgress:(id)payload {
    NSArray *items = [payload isKindOfClass:NSArray.class] ? payload : @[payload];
    for (ASDProgress *p in items) {
        if (![p respondsToSelector:@selector(bundleID)]) continue;
        if (self.bundleID && ![p.bundleID isEqualToString:self.bundleID]) continue;
        self.sawProgress = YES;

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


// When the store wants a confirmation it replies with a ConfirmPaymentSheet dialog whose
// okButtonAction.buyParams already contains a confirmedPaymentUUID — i.e. the server hands us
// exactly what to resend once the user says yes. The payload only reaches us as a description
// string, so pull the buyParams out of it textually.
// Scrape okButtonAction.buyParams out of a payload rendered as a description string.
// iOS 15.x only exposes the payload this way, under AMSServerPayload_desc.
static NSString *buyParamsFromDescription(NSString *desc) {
    if (![desc isKindOfClass:NSString.class]) return nil;
    NSRange key = [desc rangeOfString:@"buyParams = \""];
    if (key.location == NSNotFound) return nil;
    NSUInteger start = key.location + key.length;
    NSRange end = [desc rangeOfString:@"\"" options:0 range:NSMakeRange(start, desc.length - start)];
    if (end.location == NSNotFound) return nil;
    return [desc substringWithRange:NSMakeRange(start, end.location - start)];
}

// The store answers a confirmation-required purchase with a dialog whose okButtonAction.buyParams
// already contains a confirmedPaymentUUID — the server telling us exactly what to resend once the
// user says yes. Replaying it completes the purchase with no second sheet.
//
// Where that payload lives is NOT stable across iOS versions:
//   15.8.1 (19H380)  userInfo["AMSServerPayload_desc"]  — a description STRING
//   16.7.12 (20H364) userInfo["AMSServerPayload"]       — a real NSDictionary
// Prefer the dictionary (structured, no parsing) and fall back to scraping any string-valued key
// that looks like a server payload.
static NSString *confirmBuyParamsFromError(NSError *err) {
    NSDictionary *userInfo = err.userInfo;

    id payload = userInfo[@"AMSServerPayload"];
    if ([payload isKindOfClass:NSDictionary.class]) {
        id action = [[payload objectForKey:@"dialog"] objectForKey:@"okButtonAction"];
        id params = [action isKindOfClass:NSDictionary.class]
                  ? [action objectForKey:@"buyParams"] : nil;
        if ([params isKindOfClass:NSString.class] && [params length]) return params;
    }

    // Either the key is the _desc variant, or the dictionary was shaped differently than expected.
    for (NSString *key in userInfo) {
        if (![key hasPrefix:@"AMSServerPayload"]) continue;
        id value = userInfo[key];
        NSString *params = buyParamsFromDescription(
            [value isKindOfClass:NSString.class] ? value : [value description]);
        if (params.length) return params;
    }
    return nil;
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

static NSString *installedBundlePath(NSString *bundleID) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *root = @"/var/containers/Bundle/Application";
    for (NSString *uuid in [fm contentsOfDirectoryAtPath:root error:NULL]) {
        NSString *container = [root stringByAppendingPathComponent:uuid];
        NSString *meta = [container stringByAppendingPathComponent:@"iTunesMetadata.plist"];
        NSDictionary *md = [NSDictionary dictionaryWithContentsOfFile:meta];
        if (![md[@"softwareVersionBundleId"] isEqualToString:bundleID]) continue;

        for (NSString *entry in [fm contentsOfDirectoryAtPath:container error:NULL]) {
            if (![entry hasSuffix:@".app"]) continue;
            return [container stringByAppendingPathComponent:entry];
        }
    }
    return nil;
}

static BOOL isFullyInstalled(NSString *appPath) {
    if (!appPath) return NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *scInfo = [appPath stringByAppendingPathComponent:@"SC_Info"];
    NSArray *sc = [fm contentsOfDirectoryAtPath:scInfo error:NULL];
    for (NSString *f in sc) if ([f hasSuffix:@".sinf"]) return YES;
    return NO;
}

#pragma mark - Commands

static int cmdInstall(NSString *bundleID, NSNumber *adamID, BOOL autoAccept, BOOL autoConfirm,
                      BOOL forceDismiss) {
    if (!adamID) {
        NSString *name = nil;
        adamID = resolveAdamID(bundleID, &name);
        if (!adamID) {
            fprintf(stderr, "could not resolve an adamId for %s — check the bundle id, or pass --adam\n",
                    bundleID.UTF8String);
            return 66;
        }
    }

    if (isFullyInstalled(installedBundlePath(bundleID))) {
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
    p.buyParameters = [NSString stringWithFormat:
        @"salableAdamId=%@&productType=C&price=0&pricingParameters=STDQ", adamID];
    p.createsJobs   = YES;
    p.clientID      = @"com.apple.AppStore";
    // Mandatory and easy to miss: purchaseID defaults to 0, and a job with purchaseID 0 is never
    // correlated to its purchase, so appstored parks it at phase 9 forever with no error at all.
    // The AutoConfirmSheet tweak in SpringBoard watches for this flag file and is otherwise inert.
    // Scope it to this run: create it here, remove it on every exit path below.
    NSString *const kAutoConfirmFlag = @"/var/jb/tmp/.autoconfirm";
    if (forceDismiss) {
        [[NSFileManager defaultManager] createFileAtPath:kAutoConfirmFlag contents:nil attributes:nil];
        note(@"[+] force-dismiss armed (AutoConfirmSheet tweak will answer the sheet)");
    }
    void (^disarm)(void) = ^{
        if (forceDismiss) [[NSFileManager defaultManager] removeItemAtPath:kAutoConfirmFlag error:NULL];
    };

    note(@"[+] purchasing %@ (adamId %@)", bundleID, adamID);

    // Talk to the purchase service directly rather than through ASDPurchaseManager, so the
    // purchase and the dialog answer travel over one proxy. Hold it for the whole call.
    NSError *svcErr = nil;
    id svc = [[NSClassFromString(@"ASDServiceBroker") defaultBroker] getPurchaseServiceWithError:&svcErr];
    if (!svc) {
        fprintf(stderr, "could not reach the purchase service: %s\n",
                (svcErr.localizedDescription ?: @"unknown").UTF8String);
        return 3;
    }

    __block BOOL ok = NO;
    __block NSString *retryParams = nil;

    // One purchase attempt. Returns via the two __block vars above.
    BOOL (^attempt)(NSString *) = ^BOOL(NSString *params) {
        p.buyParameters = params;
        // Fresh id per attempt so the retry is not deduped onto the first one.
        p.purchaseID    = (long long)(arc4random_uniform(8000000) + 1000000);
        long long pid   = p.purchaseID;
        ok = NO; retryParams = nil;
        note(@"    attempt with purchaseID %lld", pid);
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
                    retryParams = confirmBuyParamsFromError(err);
                    if (!retryParams) {
                        note(@"[-] purchase failed");
                        if (err) {
                            note(@"    domain : %@", err.domain);
                            note(@"    code   : %ld", (long)err.code);
                            note(@"    message: %@", err.localizedDescription ?: @"-");
                            for (NSString *k in err.userInfo) {
                                if ([k isEqualToString:@"NSLocalizedDescription"]) continue;
                                note(@"    %@ = %@", k, err.userInfo[k]);
                            }
                        }
                    }
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
    // With --force-dismiss the tweak answers the sheet and this path is usually not needed.
    if (!ok && retryParams) {
        note(@"[+] store returned a confirmation with confirmedPaymentUUID; resending");
        if (!attempt(retryParams)) { note(@"[-] retry timed out"); disarm(); return 4; }
        if (!ok) note(@"[-] retry rejected — the UUID is probably single-use or cancel-invalidated");
    }

    disarm();   // the sheet is behind us either way; do not leave the tweak armed
    if (!ok) return 1;
    note(@"[+] purchased, waiting for install");

    // Poll disk for completion; progress lines arrive asynchronously from the observer meanwhile.
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
    }
    note(@"[-] gave up waiting after 10 minutes; check `appstorectl jobs`");
    return 5;
}

static int cmdUninstall(NSString *bundleID) {
    NSString *app = installedBundlePath(bundleID);
    if (!app) { note(@"[=] %@ is not installed", bundleID); return 0; }

    // MobileInstallation is the right API, but ipainstaller ships with the bootstrap and handles
    // LaunchServices deregistration correctly, so spawn it rather than reimplement it.
    // posix_spawn rather than system() so the bundle id never goes through a shell.
    const char *tool = "/var/jb/usr/bin/ipainstaller";
    char *const args[] = { (char *)tool, (char *)"-u", (char *)bundleID.UTF8String, NULL };
    pid_t pid = 0;
    if (posix_spawn(&pid, tool, NULL, NULL, args, NULL) != 0) {
        fprintf(stderr, "could not run ipainstaller\n");
        return 1;
    }
    int status = 0;
    waitpid(pid, &status, 0);
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
        "appstorectl — buy and install App Store apps from the shell\n\n"
        "  appstorectl install   <bundle-id> [--adam <id>] [--accept]\n"
        "  appstorectl resolve   <bundle-id>\n"
        "  appstorectl uninstall <bundle-id>\n"
        "  appstorectl jobs\n\n"
        "  --adam <id>  skip store lookup and use this adamId\n"
        "  --accept       auto-answer store dialogs affirmatively\n"
        "  --force-dismiss  auto-dismiss the confirmation sheet (needs the AutoConfirmSheet tweak)\n"
        "  --try-confirm  attempt to answer the confirmation sheet (does not currently work)\n"
        "\n"
        "The store shows a confirmation sheet for the first purchase. Dismiss it (tapping\n"
        "anywhere outside is enough); the confirmedPaymentUUID is then replayed automatically\n"
        "and the install completes without further interaction.\n"
        "  -q           only print errors\n");
}

int main(int argc, char **argv) {
    setbuf(stdout, NULL);
    @autoreleasepool {
        if (argc < 2) { usage(); return 64; }
        if (!dlopen("/System/Library/PrivateFrameworks/AppStoreDaemon.framework/AppStoreDaemon",
                    RTLD_NOW)) {
            fprintf(stderr, "dlopen AppStoreDaemon failed: %s\n", dlerror());
            return 2;
        }

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
        BOOL forceDismiss = NO;

        for (int i = 2; i < argc; i++) {
            NSString *a = @(argv[i]);
            if ([a isEqualToString:@"--accept"])        { autoAccept = YES;   continue; }
            if ([a isEqualToString:@"--try-confirm"])   { autoConfirm = YES;  continue; }
            if ([a isEqualToString:@"--force-dismiss"]) { forceDismiss = YES; continue; }
            if ([a isEqualToString:@"-q"])         { gQuiet = YES;     continue; }
            if ([a isEqualToString:@"--adam"] && i + 1 < argc) {
                adamOverride = @(atoll(argv[++i]));
                continue;
            }
            [pos addObject:a];
        }

        if ([cmd isEqualToString:@"jobs"]) return cmdJobs();
        if (pos.count < 1) { usage(); return 64; }
        NSString *bundleID = pos[0];

        if ([cmd isEqualToString:@"resolve"])   return resolveAdamID(bundleID, NULL) ? 0 : 66;
        if ([cmd isEqualToString:@"uninstall"]) return cmdUninstall(bundleID);
        if ([cmd isEqualToString:@"install"])
            return cmdInstall(bundleID, adamOverride, autoAccept, autoConfirm, forceDismiss);

        usage();
        return 64;
    }
}
