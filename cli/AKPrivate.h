// AKPrivate.h — AuthKit interfaces for the one interactive step this tool cannot avoid.
//
// AuthKit and the iTunes Store are separate systems. A store sign-in through SSAuthenticateRequest
// never presents a two-factor challenge, even when the process is AuthKit-entitled and dialogs are
// not suppressed; it just answers SSServerErrorDomain -5000. The verification-code prompt lives
// only here, in AKAppleIDAuthenticationCommandLineContext, which reads the code from stdin.
//
// Measured on iPhone10,3 / iOS 16.7.12, same account, same password, within one hour:
//
//   AuthKit sign-in that WAS challenged, code entered   -> store login then works, repeatedly
//   AuthKit sign-in that was NOT challenged (cached)    -> store login still answers -5000
//   no AuthKit sign-in at all                           -> store login answers -5000
//
// So -5000 does not mean "wrong password". It means this device holds no two-factor-established
// trust for that Apple ID. Establishing it is a one-off per (Apple ID, device), and it needs a
// human to type a code.

#import <Foundation/Foundation.h>

/// Drives sign-in from a command line. Recovered from iOS 16.7.12 (20H364).
///
/// The code prompt is emitted by
/// -[... _promptForVerificationCodeWithSecureEntry:forTrustedNumber:] (0x1947e4410), which
/// short-circuits when securityCode is already set and otherwise calls AKReadLine on stdin. So this
/// only works attached to a terminal.
@interface AKAppleIDAuthenticationCommandLineContext : NSObject
- (void)setUsername:(NSString *)username;
/// Underscored in the original. There is no public setter.
- (void)_setPassword:(NSString *)password;
- (void)setReason:(NSString *)reason;
/// Presetting this skips the interactive prompt. Unused here: a code is single-use and short-lived,
/// so taking it from the environment buys nothing over just typing it.
- (void)setSecurityCode:(NSString *)code;
@end

@interface AKAppleIDAuthenticationController : NSObject
/// Completion is `^(NSDictionary *results, NSError *error)`. Two arguments, error last. That arity
/// was established empirically with a non-ARC four-slot probe, after three wrong readings caused by
/// inspecting the captured pointers *after* the runloop returned, when the autoreleased dictionary
/// had already been freed and read back with a zero isa.
- (void)authenticateWithContext:(id)context
                     completion:(void (^)(NSDictionary *results, NSError *error))completion;
@end

#pragma mark - Keys in the results dictionary

/// Present and 1 only when the server actually presented a challenge UI. This is the signal that
/// matters: a sign-in can succeed and return full credentials from cached device identity without
/// ever challenging, and that establishes no store trust. Absent means "not challenged".
static NSString *const kAKDidShowServerUI = @"AKDidShowServerUI";
static NSString *const kAKAltDSID         = @"AKAltDSID";
static NSString *const kAKDSID            = @"AKDSID";
