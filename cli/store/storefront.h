// storefront.h — changing which country's App Store the account buys from.
//
// Note this is a different object from the one `accounts` prints. That reads
// SSAccount.storeFrontIdentifier out of StoreServices, which is read-only here. The setter lives on
// ACAccount as an AMSCore addition, and is what asclient's `account setStorefront` drives —
// -[AccountCommand_Universal runWithArguments:andOptions:] (0x1000b7ffc).
#import <Foundation/Foundation.h>

/// Point every signed-in or local iTunes account at `storefront` and save. NO on failure with
/// outError set.
///
/// The identifier is the bare numeric front, e.g. 143441 for the US. Apple's own help names
/// CA 143455, CN 143465, JP 143462, UK 143444, US 143441. `accounts` prints the current value in
/// its longer "143441-1,29" form, which is the front plus a platform suffix; the suffix is not
/// yours to set.
///
/// The save is local: asclient passes verifyCredentials:NO, so nothing is asked of the store and
/// nothing validates that the account may buy from that region. An invalid or unentitled front is
/// therefore accepted here and refused later, by the store, on the next purchase.
BOOL setAccountStorefront(NSString *storefront, NSError **outError);

/// What ACAccount currently holds, per account, as "<username> = <storefront>" lines. This is the
/// value the setter writes and is NOT the one `accounts` prints — that reads
/// SSAccount.storeFrontIdentifier out of StoreServices, which is a separate copy.
NSArray<NSString *> *accountStorefronts(void);
