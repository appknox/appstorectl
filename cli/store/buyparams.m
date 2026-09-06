// buyparams.m — see buyparams.h.
#import <Foundation/Foundation.h>

#import "buyparams.h"

/// Scrape okButtonAction.buyParams out of a payload rendered as a description string. iOS 15.x only
/// exposes it this way, under AMSServerPayload_desc.
static NSString *buyParamsFromDescription(NSString *desc) {
    if (![desc isKindOfClass:NSString.class]) return nil;
    NSRange key = [desc rangeOfString:@"buyParams = \""];
    if (key.location == NSNotFound) return nil;
    NSUInteger start = key.location + key.length;
    NSRange end = [desc rangeOfString:@"\"" options:0 range:NSMakeRange(start, desc.length - start)];
    if (end.location == NSNotFound) return nil;
    return [desc substringWithRange:NSMakeRange(start, end.location - start)];
}

NSString *serverBuyParamsFromError(NSError *error) {
    NSDictionary *userInfo = error.userInfo;

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
