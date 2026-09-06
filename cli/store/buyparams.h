// buyparams.h — reading the buy-params string the store hands back with a dialog.
//
// When the store wants a confirmation it answers with a dialog whose okButtonAction.buyParams
// already contains a confirmedPaymentUUID — the server telling you exactly what to resend once the
// user says yes. Replaying that string completes the purchase with no second sheet.
//
// The UUID is bound to the request that produced it and does not survive the process: replaying one
// captured from an earlier run gets HTTP 500. The resend has to happen in the same session.
#import <Foundation/Foundation.h>

/// okButtonAction.buyParams out of a store refusal, or nil if the error carries none.
///
/// Where the payload lives is NOT stable across iOS versions:
///   15.8.1 (19H380)   userInfo["AMSServerPayload_desc"]   a description STRING
///   16.7.12 (20H364)  userInfo["AMSServerPayload"]        a real NSDictionary
/// The dictionary is preferred; the string form is scraped as a fallback.
NSString *serverBuyParamsFromError(NSError *error);
