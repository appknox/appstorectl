// SSAuthPrivate.h — StoreServices interfaces for signing an Apple ID in and out.
//
// Separate from ASDPrivate.h on purpose: that file is the purchase pipeline, this one is account
// authentication, and neither needs the other. SSAccount and SSAccountStore are already declared
// in ASDPrivate.h with the members the purchase path uses, so the additions here are categories
// rather than redeclarations.
//
// Recovered from iOS 16.7.12 (20H364). Addresses are for that build. Private API throughout.
//
// Unlike the rest of appstorectl, none of this needs to run as mobile. The biometric pre-flight
// forks and setuid(501)s because purchase-authorization prefs live in mobile's preference domain;
// accounts do not. Signing in and out was verified to behave identically as uid 0 and uid 501,
// because accountsd is a system-wide daemon rather than a per-user preference store.

#import <Foundation/Foundation.h>
// For the base SSAccount and SSAccountStore declarations. A category needs the real @interface,
// a forward @class is not enough.
#import "ASDPrivate.h"

#pragma mark - Authentication context

// The immutable half exists too; only the mutable one is useful to a caller.
//
// promptStyle is the setting that decides whether authentication happens at all. From
// -[SSAuthenticateRequest _shouldRunAuthenticationForAccount:] at 0x1a1a34d5c:
//
//     account is nil  -> authenticate
//     1               -> authenticate, unconditionally
//     1000            -> never authenticate
//     1001            -> only when !account.isAuthenticated
//     anything else   -> only when the token type is expired, else only when !isAuthenticated
//
// The default is 0, and leaving it there against an already-authenticated, unexpired account makes
// the request return *success* having contacted nobody. Always set 1 for a real sign-in.
@interface SSMutableAuthenticationContext : NSObject
@property (copy)   NSString *accountName;
@property (copy)   NSString *password;
/// What a UI would prefill. Distinct from password; set both.
@property (copy)   NSString *initialPassword;
@property (assign) long long promptStyle;
@property (assign) BOOL canSetActiveAccount;
@property (assign) BOOL canCreateNewAccount;
@property (assign) BOOL allowsSilentAuthentication;
@property (assign) BOOL allowsRetry;
/// Leave NO. Suppressing dialogs is what stops a second factor from ever being offered.
@property (assign) BOOL shouldSuppressDialogs;
@property (assign) BOOL shouldCreateNewSession;
/// Deliberately unused by login. See the note on cmdLogin() in account.h.
@property (copy)   NSString *altDSID;
@end

@interface SSAuthenticationContext : NSObject
/// Factory that presets two ivars a bare -init leaves empty (0x1a1a35794). Prefer it.
+ (instancetype)contextForSignIn;
@end


#pragma mark - Authentication request

// authenticateResponseType, from -[SSAuthenticateRequest _responseTypeForError:] at 0x1a1a347a4
// plus the success assignment at 0x1a1a320a8. Each value below is Apple's own log string.
typedef NS_ENUM(long long, SSAuthenticateResponseType) {
    SSAuthenticateResponseTypeFailed          = 0,  // "Authentication request failed. error = %@"
    SSAuthenticateResponseTypeRejected        = 1,  // "The server rejected the credentials we passed it."
    SSAuthenticateResponseTypeCancelled       = 2,  // "The user cancelled the authentication."
    SSAuthenticateResponseTypeNeedsReview     = 3,  // "This is a new account that needs to be reviewed."
    SSAuthenticateResponseTypeSucceeded       = 4,
};

@interface SSAuthenticateResponse : NSObject
@property (readonly) SSAccount *authenticatedAccount;
@property (readonly) SSAuthenticateResponseType authenticateResponseType;
/// 1 PromptAuth, 2 PET from an alternate account, 3 SilentAuth, 4 the account already had its own
/// PET, 5 SilentPasswordAuth. Informational only: the value is also settable straight from an
/// options key by the outer updateAccountWithAuthKit:, so it does not reliably identify a rung.
@property (readonly) long long credentialSource;
@property (readonly) NSError *error;
@property (readonly) NSDictionary *responseDictionary;
@end

@interface SSAuthenticateRequest : NSObject
- (instancetype)initWithAuthenticationContext:(id)context;
/// Reply block arity established empirically with a non-ARC four-slot probe: slot 0 is always an
/// SSAuthenticateResponse, slot 1 is an NSError or nil. Two arguments is safe under ARC.
- (void)startWithAuthenticateResponseBlock:(void (^)(SSAuthenticateResponse *r, NSError *e))block;
/// YES if the caller may drive a second factor. Requires com.apple.authkit.client.private or
/// com.apple.authkit.client.internal (or being a daemon). Without it the request is shipped to
/// itunesstored over XPC instead of running in process, and a 2FA challenge cannot be answered.
+ (BOOL)_isAuthkitEntitled;
@end


#pragma mark - Account store additions

@interface SSAccount (Auth)
@property (readonly) NSString *storeFrontIdentifier;
@property (readonly) NSString *altDSID;
@property (readonly, getter=isAuthenticated) BOOL authenticated;
@property (readonly, getter=isActive)        BOOL active;
@property (readonly, getter=isLocalAccount)  BOOL localAccount;
@end

@interface SSAccountStore (Auth)
@property (readonly) NSArray<SSAccount *> *accounts;

/// Store-level, NOT per account. Both read `LastAuthTime` out of `com.apple.itunesstored` and
/// compare against a 900 s TTL:
///
///     key    = (tokenType == 1) ? @"LastAuthTime-%@" : @"LastAuthTime";
///     stored = CFPreferencesCopyAppValue(key, @"com.apple.itunesstored");
///     if (!stored) return YES;                 // never authenticated == expired
///     return now > stored + 900.0;
///
/// Two things make this a poor health signal, both measured:
///
/// 1. Only `resetExpirationForTokenType:` writes that key, and the AMS payment-sheet path never
///    calls it. On a device where it was never written these return YES permanently, including
///    during purchases that succeed.
/// 2. The prefs live in **mobile's** domain. As root the read may land in a different, empty
///    domain and answer YES for that reason instead.
///
/// Report it, do not branch on it.
- (BOOL)isExpired;
- (BOOL)isExpiredForTokenType:(long long)tokenType;
/// Drops the cache. The invalidation behind it arrives as a Darwin notification and is only
/// delivered on a runloop turn, so never sleep before calling this.
- (void)reloadAccounts;
/// Delegates to -[ACAccountStore removeAccount:withCompletionHandler:] (0x1a1a3f890). Needs
/// com.apple.private.accounts.allaccounts, or accountsd answers com.apple.accounts code 7,
/// "The application is not permitted to delete iTunes Store accounts".
///
/// Use this and NOT -[SSAccountStore removeAccount:error:], which blocks on a semaphore with a
/// five second timeout and deadlocks into "Timed out while trying to remove %@" if the completion
/// lands on the queue the caller is blocking.
- (void)removeAccount:(SSAccount *)account completion:(void (^)(BOOL ok, NSError *e))completion;
@end
