// Dismiss the App Store purchase-confirmation sheet in PassbookUIService. Dismissal returns a
// confirmedPaymentUUID that appstorectl replays; this tweak never confirms or authorizes payment.
// It acts only on PKPaymentAuthorizationRemoteAlertViewController while a fresh one-shot
// /var/jb/tmp/.autoconfirm flag exists. The CLI cleans the flag after a normal purchase call.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// The dismissal API is not stable across iOS versions:
//   15.8.1 (19H380)  -[... dismissWithRemoteOrigination:]
//   16.7.12 (20H364)  -[... askForDismissalWithReason:error:completion:]   (the 15.x selector and
//                     _dismiss are both gone; calling either throws unrecognized selector)
// So never hardcode one — probe with respondsToSelector: and fall through. See dismissSheet().
@interface PKPaymentAuthorizationRemoteAlertViewController : UIViewController
- (void)dismissWithRemoteOrigination:(BOOL)remote;
- (void)askForDismissalWithReason:(long long)reason
                            error:(NSError **)error
                       completion:(id)completion;
@end

// Created by appstorectl --force-dismiss; absent means this tweak is completely inert.
static NSString *const kEnableFlagPath = @"/var/jb/tmp/.autoconfirm";

// NSLog goes to the unified log, which cannot be streamed on this device (iOS ships no
// /usr/bin/log). Append to a file so every decision is inspectable over SSH.
static NSString *const kTracePath = @"/var/jb/tmp/autoconfirm.log";
static const NSTimeInterval kArmLifetime = 5 * 60;

static void trace(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *stamped = [NSString stringWithFormat:@"%@ %@\n", NSDate.date, line];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:kTracePath];
    if (!handle) {
        [stamped writeToFile:kTracePath atomically:NO encoding:NSUTF8StringEncoding error:NULL];
        return;
    }
    [handle seekToEndOfFile];
    [handle writeData:[stamped dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
}

static BOOL consumeArm(void) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSDictionary *attributes = [files attributesOfItemAtPath:kEnableFlagPath error:NULL];
    if (!attributes) return NO;

    NSDate *modified = attributes[NSFileModificationDate];
    NSTimeInterval age = -modified.timeIntervalSinceNow;
    if (!modified || age < 0 || age > kArmLifetime) {
        [files removeItemAtPath:kEnableFlagPath error:NULL];
        trace(@"ignoring expired force-dismiss flag");
        return NO;
    }

    NSError *error = nil;
    if (![files removeItemAtPath:kEnableFlagPath error:&error]) {
        trace(@"could not consume force-dismiss flag: %@", error);
        return NO;
    }
    return YES;
}

// Close the sheet using whichever API this iOS version actually has. Ordered newest-known first;
// each candidate is checked with respondsToSelector: so a missing one is skipped rather than
// throwing. If every candidate is gone, that is logged loudly — it means Apple moved the API again
// and the tweak needs a new entry, not that anything is subtly broken.
static void dismissSheet(PKPaymentAuthorizationRemoteAlertViewController *vc) {

    // iOS 16.x. The completion block's arity is undocumented, so pass a zero-argument block:
    // always safe to invoke, extra registers ignored. Reason 0 is the generic/default case.
    if ([vc respondsToSelector:@selector(askForDismissalWithReason:error:completion:)]) {
        @try {
            NSError *error = nil;
            [vc askForDismissalWithReason:0 error:&error completion:^{ }];
            trace(@"dismissed via askForDismissalWithReason: (error=%@)",
                  error ?: @"none");
            return;
        } @catch (NSException *e) {
            trace(@"askForDismissalWithReason: threw %@: %@", e.name, e.reason);
        }
    }

    // iOS 15.x.
    if ([vc respondsToSelector:@selector(dismissWithRemoteOrigination:)]) {
        @try {
            [vc dismissWithRemoteOrigination:NO];
            trace(@"dismissed via dismissWithRemoteOrigination:");
            return;
        } @catch (NSException *e) {
            trace(@"dismissWithRemoteOrigination: threw %@: %@", e.name, e.reason);
        }
    }

    // Older/other builds.
    if ([vc respondsToSelector:@selector(_dismiss)]) {
        @try {
            [vc performSelector:@selector(_dismiss)];
            trace(@"dismissed via _dismiss");
            return;
        } @catch (NSException *e) {
            trace(@"_dismiss threw %@: %@", e.name, e.reason);
        }
    }

    // Last resort: plain UIKit. Works when the sheet is a normally presented child, which is not
    // guaranteed for a remote alert — hence last.
    @try {
        UIViewController *presenter = vc.presentingViewController ?: vc;
        [presenter dismissViewControllerAnimated:NO completion:nil];
        trace(@"dismissed via UIKit dismissViewControllerAnimated:");
        return;
    } @catch (NSException *e) {
        trace(@"UIKit dismissal threw %@: %@", e.name, e.reason);
    }

    trace(@"NO WORKING DISMISSAL API on %@ — the sheet was left alone. "
          @"PassKitUI has changed; add the current selector to dismissSheet().",
          UIDevice.currentDevice.systemVersion);
}

%hook PKPaymentAuthorizationRemoteAlertViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;

    if (!consumeArm()) {
        trace(@"payment sheet appeared but not armed — leaving it alone");
        return;
    }

    trace(@"payment sheet appeared while armed — dismissing");

    // Dismiss on the next runloop turn: doing it inside viewDidAppear: races the presentation
    // animation and PassKit can end up with a half-torn-down controller.
    dispatch_async(dispatch_get_main_queue(), ^{
        dismissSheet((PKPaymentAuthorizationRemoteAlertViewController *)self);
    });
}

%end

%ctor {
    @autoreleasepool {
        Class cls = objc_getClass("PKPaymentAuthorizationRemoteAlertViewController");
        if (!cls) {
            trace(@"ctor in %@: PassKit alert class unavailable — hook NOT installed",
                  NSProcessInfo.processInfo.processName);
            return;
        }
        %init(PKPaymentAuthorizationRemoteAlertViewController = cls);
        trace(@"ctor in %@: hooked PKPaymentAuthorizationRemoteAlertViewController",
              NSProcessInfo.processInfo.processName);
    }
}
