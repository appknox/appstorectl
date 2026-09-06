// AMSDialogPrivate.h — the dialog types appstored hands to a registered dialog observer.
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
