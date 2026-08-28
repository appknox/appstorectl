// account.h — the seam for the account commands. Split across account.m (shared), login.m and
// logout.m so no one file carries all three.

#import <Foundation/Foundation.h>

@class SSAccount;

#pragma mark - Exit codes

// Distinct codes so a caller can branch without parsing prose. cmdLogin and cmdLogout return these.
enum {
    kAccountOK             = 0,
    kAccountUsage          = 64,
    kAccountLoadFailed     = 2,   // StoreServices or a class inside it is unavailable
    kAccountNoPassword     = 65,  // no password source, and no terminal to ask on
    kAccountRejected       = 10,  // the store server rejected the credentials
    kAccountAuthFailed     = 11,  // authentication failed some other way
    kAccountTimedOut       = 12,  // the daemon never replied
    kAccountUnverified     = 13,  // reported success, but re-reading the store disagreed
    kAccountNotFound       = 20,  // no account matches that Apple ID
    kAccountRefused        = 21,  // a safety guard declined
    kAccountRemoveFailed   = 22,  // removal reported failure
    kAccountNeedsTerminal  = 66,  // a two-factor code must be typed, and there is no terminal
    kAccountNotChallenged  = 67,  // AuthKit signed in from cache without a challenge, so no trust
    kAccountBadPassword    = 68,  // AuthKit said the password itself is wrong
};

#pragma mark - Commands

/// List every store account with its storefront and authentication state. Read-only.
int cmdAccounts(void);

/// Sign in `appleID`, creating the account if the device does not have it.
///
/// The password is never taken from argv, where ps would expose it. In order: `passwordFile`,
/// then $APPSTORECTL_PASSWORD, then an interactive prompt if stdin is a terminal.
///
/// `altDSID` and `requiredUniqueIdentifier` are deliberately left unset on the context. The lookup
/// in +[SSAuthenticateRequest _accountToAuthenticateWithAuthenticationContext:] resolves on
/// (altDSID, DSID, username); with only a username, a miss falls into the branch that mints a new
/// account, which is what signing in a new Apple ID needs. Supplying an altDSID risks matching some
/// unrelated local record and authenticating the wrong account.
/// `showPassword` echoes the typed password. Off by default; it exists so a mis-read
/// credential can be told apart from a wrong one, which the server reports identically.
int cmdLogin(NSString *appleID, NSString *passwordFile, BOOL showPassword, BOOL allowBootstrap);

/// Remove `appleID` from the device. There is no UI for this: iOS lists only the *active* store
/// account, so an inactive one is invisible in Settings.
///
/// Refuses the local pseudo-account outright, and refuses the active account unless `force`.
int cmdLogout(NSString *appleID, BOOL force);

#pragma mark - Shared helpers, implemented in account.m

/// Load StoreServices and return +[SSAccountStore defaultStore], or nil after printing why.
id accountStore(void);

/// Case-insensitively find an account by name. The store lowercases what the server returns, so a
/// case-sensitive compare reports "not found" for an account that is sitting right there.
SSAccount *findAccount(NSString *appleID);

/// Re-read the store until `appleID` reaches `wantPresent`, or the timeout expires. Returns the
/// account, or nil.
///
/// This spins the runloop rather than sleeping, and that is load-bearing. Both the sign-in and the
/// removal completions fire *before* accountsd's accounts-changed Darwin notification is delivered,
/// and reloadAccounts keeps serving the cached snapshot until it lands. Reading once, immediately,
/// reports a successful removal as a failure and a freshly created account as absent.
SSAccount *waitForAccount(NSString *appleID, BOOL wantPresent, NSTimeInterval timeout);

void printAccountTable(NSString *heading);

/// Print an NSError and its whole underlying chain. A bare domain and code is the least useful part
/// of a store failure; the server payload lives in userInfo.
void printErrorChain(NSError *e, int depth);

#pragma mark - Two-factor bootstrap, implemented in authkit.m

/// Establish two-factor trust for `appleID` on this device by driving AuthKit's command-line
/// sign-in, which prompts for a verification code on stdin.
///
/// This exists because the store path cannot do it. `SSAuthenticateRequest` never presents a
/// challenge; it answers -5000 when the device holds no trust for the Apple ID. Measured on the
/// same account within one hour: challenged AuthKit sign-in then store login works repeatedly;
/// un-challenged AuthKit sign-in (answered from cached identity) leaves store login still failing.
///
/// Needs a terminal. One-off per (Apple ID, device).
int authkitBootstrap(NSString *appleID, NSString *password);
