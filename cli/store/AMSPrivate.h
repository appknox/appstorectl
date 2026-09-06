// AMSPrivate.h — AppleMediaServices types: the dialog objects appstored hands to a registered
// dialog observer, and the purchase queue used to ask the store which versions of an app exist.
//
// Unlike the reply blocks in ASDPrivate.h, the arity here is NOT a guess and was not established
// by probing. It is read directly out of the protocol method-type table
// __OBJC_$_PROTOCOL_METHOD_TYPES_ASDNotificationCenterDialogObserver at 0x1ee43da78 in
// AppStoreDaemon (15.8.1):
//
//   v32@0:8@"AMSAuthenticateRequest"16@?<v@?@"AMSAuthenticateResult"@"NSError">24
//   v32@0:8@"AMSDialogRequest"16@?<v@?@"AMSDialogResult"@"NSError">24
//   v32@0:8@"AMSEngagementRequest"16@?<v@?@"AMSEngagementResult"@"NSError">24
//
// The `<...>` is the block's own signature, inlined by the compiler: two object arguments, the
// result first and an NSError second. There is no BOOL anywhere in it.
//
// Cross-checked against Apple's own client. -[InstallCommandUniversal handleDialogRequest:
// resultHandler:] (asclient, 0x100086080, iOS 16.0 beta AppleInternal) passes the resultHandler
// straight into -[AMSPromise addFinishBlock:], and asclient's own finish block sub_10014AF04
// decompiles as (blockSelf, result, error). Same shape from both directions.
//
// See ../../asclient-re/FINDINGS.md §4 and DELTAS-FOR-APPSTORECTL.md §1 in the research tree.

#import <Foundation/Foundation.h>

/// One button on a store dialog. `identifier` is what goes back in the result; the store matches
/// on it, not on the title.
@interface AMSDialogAction : NSObject
@property (copy) NSString *identifier;
@property (copy) NSString *title;
@property (assign) long long style;
@property (copy) NSDictionary *userInfo;
@end


@interface AMSDialogTextField : NSObject
@property (copy) NSString *placeholder;
@property (copy) NSString *text;
@property (assign) BOOL secure;
@end


/// What the store is asking. `defaultAction` is the affirmative button when the store nominates
/// one — prefer it over indexing into buttonActions, which is ordered for display, not by intent.
@interface AMSDialogRequest : NSObject
@property (copy) NSString *identifier;
@property (copy) NSString *title;
@property (copy) NSString *message;
@property (copy) NSArray<AMSDialogAction *> *buttonActions;
@property (copy) AMSDialogAction *defaultAction;
@property (copy) AMSDialogAction *cancelAction;
@property (copy) NSArray<AMSDialogTextField *> *textFields;
@property (copy) NSDictionary *userInfo;
- (AMSDialogAction *)locateActionWithIdentifier:(NSString *)identifier;
@end


/// The answer. `textfieldValues` is lowercase-f in Apple's selector; that is not a typo here.
@interface AMSDialogResult : NSObject
- (instancetype)initWithOriginalRequest:(AMSDialogRequest *)request
               selectedActionIdentifier:(NSString *)identifier;
@property (readonly) AMSDialogRequest *originalRequest;
@property (copy) NSString *selectedActionIdentifier;
@property (copy) NSArray<NSString *> *textfieldValues;
@property (copy) NSDictionary *userInfo;
@end


/// Delivered to the object registered with -[ASDNotificationCenter setDialogObserver:].
///
/// Note that `dialogObserver` is a WEAK property — the attribute string on
/// _OBJC_IVAR_$_ASDNotificationCenter._dialogObserver reads
/// T@"<ASDNotificationCenterDialogObserver>",W,V_dialogObserver, and -setDialogObserver:
/// (0x199fa1e30) calls objc_storeWeak. Keep a strong reference for the life of the install or the
/// observer disappears and the purchase dies with ASDErrorDomain 1060.
@protocol ASDNotificationCenterDialogObserver <NSObject>
@optional
- (void)handleDialogRequest:(AMSDialogRequest *)request
              resultHandler:(void (^)(AMSDialogResult *result, NSError *error))resultHandler;
- (void)handleAuthenticateRequest:(id)request
                    resultHandler:(void (^)(id result, NSError *error))resultHandler;
- (void)handleEngagementRequest:(id)request
                  resultHandler:(void (^)(id result, NSError *error))resultHandler;
@end


#pragma mark - Purchase queue

// Asking the store which versions of an app exist means going around appstored. ASDPurchaseResult
// carries only success / error / itemID, so the version list never reaches an appstored client.
// AppleMediaServices' own purchase queue hands back the raw store response instead, which is where
// songList[0].metadata.softwareVersionExternalIdentifiers lives.
//
// This is the path Apple's asclient uses for exactly this purpose:
// -[Lookup _getPurchaseResponse:error:] (0x10014a9d8) and -[Lookup lookupEvidsForApp:withCompletion:]
// (0x100146924).

/// A parsed buy-params string. Keys are the AMSBuyParamProperty* externs; the raw names are what
/// the store actually sees, so they are used literally here.
@interface AMSBuyParams : NSObject
+ (instancetype)buyParamsWithString:(NSString *)string;
- (instancetype)initWithString:(NSString *)string;
- (NSString *)stringValue;
- (NSString *)parameterForKey:(NSString *)key;
- (void)setParameter:(NSString *)value forKey:(NSString *)key;
@end


/// purchaseType: 0 normal, 2 DSID-less, 5 the VPP/HRN manifest flow.
/// Established from -[Installer _purchaseApp:] and -[VPPCommand _generateHRNRequest:options:].
@interface AMSPurchase : NSObject
- (instancetype)initWithPurchaseType:(long long)type buyParams:(AMSBuyParams *)params;
@property (strong) id account;              // ACAccount
@property (copy)   NSString *logUUID;       // shows up in the store-side log; asclient uses "Lookup:<bundle>:<item>"
@property (assign, getter=isUserInitiated) BOOL userInitiated;
@property (copy)   NSDictionary *additionalHeaders;
@property (copy)   NSString *clientId;
@property (copy)   NSString *callerBundleId;
@end


/// What the finish block receives, one per enqueued purchase.
@interface AMSPurchaseResult : NSObject
@property (readonly) NSDictionary *responseDictionary;   // the raw store JSON
@property (readonly) NSError *error;
@end


/// The bag decides which store endpoints a request uses and how it identifies itself.
///
/// asclient does NOT use +[AMSPurchaseQueue createBagForSubProfile] for the purchase queue. It
/// builds its own — -[ASCBag init] (0x1000a0e80) — as the appstored profile, then overrides two
/// keys in +[ASCBag _setDefaultValuesForBag:] (0x1000a103c):
///
///     [AMSBag bagForProfile:@"appstored" profileVersion:@"1"]
///     storefront-header-suffix  =  t:apps3
///     update-password-settings  =  https://buy.itunes.apple.com/.../MZFinance.woa/wa/updatePasswordSettings
///
/// storefront-header-suffix is appended to X-Apple-Store-Front, which is how MZBuy tells clients
/// apart. That matters here: see storeEvidsForAdamID.
@interface AMSBag : NSObject
+ (instancetype)bagForProfile:(NSString *)profile profileVersion:(NSString *)version;
- (void)setDefaultValue:(id)value forKey:(NSString *)key;
@end


/// FairPlay keybag context. asclient resets it immediately before every purchase it enqueues
/// (-[Lookup _getPurchaseResponse:error:] 0x10014a9d8).
@interface AMSKeybag : NSObject
+ (instancetype)sharedInstance;
- (void)resetContext;
@end


@interface AMSPurchaseQueueConfiguration : NSObject
- (instancetype)initWithBag:(id)bag;
@property (weak) id delegate;
@end


/// createBagForSubProfile comes from AMSBagConsumer and returns the bag this class expects, so
/// there is no need to build one by hand.
@interface AMSPurchaseQueue : NSObject
+ (id)createBagForSubProfile;
- (instancetype)initWithConfiguration:(AMSPurchaseQueueConfiguration *)configuration;
- (id)enquePurchases:(NSArray<AMSPurchase *> *)purchases;   // returns an AMSPromise
@end


/// The finish block is (result, error). Confirmed from asclient's own block sub_10014AF04, which
/// decompiles as (blockSelf, results, error) — the same two-object shape as the dialog handler.
@interface AMSPromise : NSObject
- (void)addFinishBlock:(void (^)(id result, NSError *error))block;
/// Blocks until the promise resolves. asclient uses this for the media lookup and the runloop spin
/// only for the purchase queue, so it is safe here but not there.
- (id)resultWithError:(NSError **)error;
@end


/// The store's metadata lookup, which is a plain read: no purchase, no payment sheet, no
/// confirmation. -[Lookup _newMediaTask] (asclient 0x100147a14) builds it exactly like this.
/// type 0 is the app lookup. Platform strings are the literal "iphone" / "ipad".
@interface AMSMediaTask : NSObject
+ (id)createBagForSubProfile;
- (instancetype)initWithType:(long long)type
            clientIdentifier:(NSString *)clientIdentifier
               clientVersion:(NSString *)clientVersion
                         bag:(id)bag;
@property (strong) id account;
@property (copy) NSArray *additionalPlatforms;
@property (copy) NSArray *bundleIdentifiers;
@property (copy) NSArray *itemIdentifiers;
/// The default response carries externalVersionId (the current build) but no history. asclient
/// reads a `versionHistory` array out of platformAttributes, so it must ask for it here.
@property (copy) NSArray *includedResultKeys;
@property (copy) NSDictionary *additionalQueryParams;
- (AMSPromise *)perform;
@end


/// What -[AMSMediaTask perform] resolves to. responseDataItems is the amp-api `data` array;
/// -[Lookup _processedLookupResult:] (0x100149420) is the map of what is inside each item.
@interface AMSMediaResult : NSObject
@property (readonly) NSArray *responseDataItems;
@property (readonly) NSDictionary *responseDictionary;
@end


/// Dialogs raised by the purchase queue arrive here instead of at ASDNotificationCenter, with a
/// four-argument selector rather than the observer's two.
@protocol AMSPurchaseQueueDelegate <NSObject>
@optional
- (void)handleDialogRequest:(AMSDialogRequest *)request
                   purchase:(AMSPurchase *)purchase
              purchaseQueue:(AMSPurchaseQueue *)queue
                 completion:(void (^)(AMSDialogResult *result, NSError *error))completion;
- (void)handleAuthenticateRequest:(id)request
                         purchase:(AMSPurchase *)purchase
                    purchaseQueue:(AMSPurchaseQueue *)queue
                       completion:(void (^)(id result, NSError *error))completion;
@end
