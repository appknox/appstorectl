// account.m — shared account plumbing and the read-only `accounts` command. Sign-in lives in
// login.m, removal in logout.m.

#import <dlfcn.h>
#import "account.h"
#import "appstorectl.h"
#import "log.h"
#import "SSAuthPrivate.h"

id accountStore(void) {
    // StoreServices is not linked, and is not the framework appstorectl.m already loads. Loading
    // it here keeps the purchase path free of a dependency it never uses.
    if (!dlopen("/System/Library/PrivateFrameworks/StoreServices.framework/StoreServices",
                RTLD_NOW)) {
        fprintf(stderr, "[-] dlopen StoreServices failed: %s\n", dlerror());
        logLine(@"dlopen StoreServices FAILED: %s", dlerror());
        return nil;
    }
    Class store = NSClassFromString(@"SSAccountStore");
    if (!store) {
        fprintf(stderr, "[-] SSAccountStore unavailable\n");
        logLine(@"SSAccountStore class not found after dlopen");
        return nil;
    }
    // Once per process, not per call: waitForAccount polls this every 250 ms and would otherwise
    // bury the log in identical lines.
    static BOOL announced = NO;
    if (!announced) {
        announced = YES;
        logLine(@"StoreServices loaded, SSAccountStore resolved");
    }
    return [store defaultStore];
}

static NSArray<SSAccount *> *liveAccounts(void) {
    id store = accountStore();
    if (!store) return nil;
    // reloadAccounts drops the cache; the invalidation behind it is a Darwin notification that
    // only lands on a runloop turn, which is why a caller that sleeps sees stale data forever.
    [store reloadAccounts];
    return [store accounts];
}

SSAccount *findAccount(NSString *appleID) {
    for (SSAccount *a in liveAccounts()) {
        NSString *name = a.accountName;
        if ([name isKindOfClass:[NSString class]] &&
            [name caseInsensitiveCompare:appleID] == NSOrderedSame) return a;
    }
    return nil;
}

SSAccount *waitForAccount(NSString *appleID, BOOL wantPresent, NSTimeInterval timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    SSAccount *found = nil;
    do {
        found = findAccount(appleID);
        if ((found != nil) == wantPresent) return found;
        // runUntilDate:, never sleep. Sleeping blocks the thread the accounts-changed Darwin
        // notification needs to be delivered on, so the cache never invalidates and every re-read
        // returns the same stale answer forever.
        [[NSRunLoop currentRunLoop]
            runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
    } while ([deadline timeIntervalSinceNow] > 0);
    return findAccount(appleID);
}

// A storefront id like "143467-2,29" says nothing at a glance, and nothing on the device will
// decode it per account: no plist ships a table, and -[SSDevice sdk_loadStorefrontCountryCode:]
// answers for the *current* storefront only. So this is a hand-kept map of the ones worth naming.
// Anything unmapped keeps its raw id rather than guessing, which is also what makes a short list
// acceptable: being absent here costs nothing.
static const struct { int front; const char *cc; } kStoreFronts[] = {
    {143441,"US"}, {143444,"GB"}, {143442,"FR"}, {143443,"DE"}, {143455,"CA"},
    {143450,"IT"}, {143454,"ES"}, {143452,"NL"}, {143459,"CH"}, {143445,"AT"},
    {143446,"BE"}, {143449,"IE"}, {143453,"PT"}, {143456,"SE"}, {143457,"NO"},
    {143458,"DK"}, {143447,"FI"}, {143448,"GR"}, {143478,"PL"}, {143489,"CZ"},
    {143482,"HU"}, {143487,"RO"}, {143526,"BG"}, {143460,"AU"}, {143461,"NZ"},
    {143462,"JP"}, {143463,"HK"}, {143464,"SG"}, {143465,"CN"}, {143466,"KR"},
    {143467,"IN"}, {143470,"TW"}, {143471,"VN"}, {143473,"MY"}, {143474,"PH"},
    {143475,"TH"}, {143476,"ID"}, {143477,"PK"}, {143468,"MX"}, {143469,"RU"},
    {143503,"BR"}, {143505,"AR"}, {143501,"CO"}, {143507,"PE"}, {143483,"CL"},
    {143472,"ZA"}, {143479,"SA"}, {143480,"TR"}, {143481,"AE"}, {143516,"EG"},
    {143491,"IL"}, {143492,"UA"}, {143493,"KW"}, {143498,"QA"}, {143559,"BH"},
};

// "143467-2,29" -> "143467-2,29 (IN)". intValue stops at the first non-digit, which is the '-'.
static NSString *storeFrontLabel(NSString *sf) {
    if (!sf.length) return @"-";
    int front = sf.intValue;
    for (size_t i = 0; i < sizeof(kStoreFronts) / sizeof(kStoreFronts[0]); i++)
        if (kStoreFronts[i].front == front)
            return [NSString stringWithFormat:@"%@ (%s)", sf, kStoreFronts[i].cc];
    return sf;
}

// Gate 1, per account. authpref only ever reports this for the active account, so without it here
// there is no way to see it for the other three without switching to each in turn.
//
// Reported for signed-out accounts too. The value is server-synced per Apple ID and a signed-out
// record holds the last cached copy, which is still the value that applies when it signs back in.
// It also lags: the store persists the ASN answer well before a local read reflects it, so treat a
// fresh reading as "not yet observed" rather than as "unset". See docs/GATES.md.
static const char *passwordSettingLabel(SSAccount *a) {
    switch (a.freeDownloadsPasswordSetting) {
        case 1:  return "always";
        case 2:  return "sometimes";
        case 3:  return "never";
        default: return "unset";      // 0, which the server treats as "always". See docs/GATES.md.
    }
}

// One row per account. Both callers print the same columns, so they share this rather than keeping
// two copies in step by hand.
//
// accountName is guarded for the same reason findAccount type-checks it: a record can carry a
// non-string or absent name, and `%s` on the NULL that .UTF8String then returns is undefined.
static void printAccountRows(NSArray<SSAccount *> *accounts) {
    logLine(@"account store returned %lu account(s)", (unsigned long)accounts.count);

    for (SSAccount *a in accounts) {
        note(@"  %-28s %-13s %-18s %-9s %s %s",
             a.accountName.UTF8String ?: "(unnamed)",
             a.uniqueIdentifier.stringValue.UTF8String ?: "-",
             storeFrontLabel(a.storeFrontIdentifier).UTF8String,
             passwordSettingLabel(a),
             a.isAuthenticated ? "signed" : "out   ",
             a.isActive ? "active" : "");

        // Raw values behind the row: the setting as an integer rather than its name, and the
        // storefront without the country gloss, which is our lookup and not Apple's.
        logLine(@"  acct %@ dsid=%@ sf=%@ auth=%d active=%d local=%d free=%lld paid=%lld",
                a.accountName ?: @"(nil)",
                a.uniqueIdentifier ?: @"(nil)",
                a.storeFrontIdentifier ?: @"(nil)",
                a.isAuthenticated, a.isActive, a.isLocalAccount,
                a.freeDownloadsPasswordSetting,
                a.paidPurchasesPasswordSetting);
    }
}

void printAccountTable(NSString *heading) {
    NSArray<SSAccount *> *accounts = liveAccounts();
    if (!accounts) return;
    if (heading.length) note(@"%@", heading);
    printAccountRows(accounts);
}

// warnf rather than fprintf: an error chain is the single most useful thing to still have months
// later, and printing it only to a terminal nobody was watching throws it away.
void printErrorChain(NSError *e, int depth) {
    if (!e) return;
    NSString *pad = [@"" stringByPaddingToLength:(NSUInteger)(depth * 2)
                                      withString:@" " startingAtIndex:0];
    warnf(@"    %@%@ %ld", pad, e.domain, (long)e.code);
    for (NSString *k in e.userInfo) {
        if ([k isEqualToString:NSUnderlyingErrorKey]) continue;
        warnf(@"      %@%@ = %@", pad, k, e.userInfo[k]);
    }
    id under = e.userInfo[NSUnderlyingErrorKey];
    if ([under isKindOfClass:[NSError class]]) printErrorChain(under, depth + 2);
}

// appstored's own account status, asked over XPC rather than read out of a plist.
//
// See ASDPrivate.h for why this exists: every SSAccountStore expiry accessor is a hardcoded clock
// over a stored date and says the same thing whether a purchase will succeed or be refused.
//
// The reply block's arity is undocumented, so take four void* slots and screen slot 0 with the
// pointer-alignment check used elsewhere, rather than letting ARC retain whatever is in a register.
static NSString *daemonAccountStatus(void) {
    Class taskClass = NSClassFromString(@"ASDAccountStatusTask");
    if (!taskClass) { logLine(@"daemon status: ASDAccountStatusTask unavailable"); return nil; }

    id task = [[taskClass alloc] init];
    if (!task) { logLine(@"daemon status: could not build the task"); return nil; }

    __block NSString *summary = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    @try {
        [task statusWithCompletion:^(void *a0, void *a1, void *a2, void *a3) {
            id resp = (a0 && !((uintptr_t)a0 & 7)) ? (__bridge id)a0 : nil;
            if ([resp respondsToSelector:@selector(accountStatus)]) {
                summary = [NSString stringWithFormat:@"accountStatus=%lld  hasError=%d  dsid=%@",
                           [resp accountStatus], [resp hasErrorStatus],
                           [resp accountID] ?: @"(nil)"];
            } else {
                summary = [NSString stringWithFormat:@"unusable reply, slot0=%p", a0];
            }
            dispatch_semaphore_signal(sem);
        }];
    } @catch (NSException *e) {
        logLine(@"daemon status: threw %@", e.reason);
        return @"(threw)";
    }

    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10ull * NSEC_PER_SEC)) != 0) {
        logLine(@"daemon status: timed out");
        return @"(no reply within 10s)";
    }
    logLine(@"daemon status: %@", summary ?: @"(empty)");
    return summary;
}

// Store-level session state, printed under the table rather than as a column: there is one value
// for the device, and a column repeating it on every row would imply it belongs to each account.
//
// Deliberately worded so it cannot be read as "this account can buy". It cannot: the same flags
// read YES during purchases that succeed, and YES again when the store demands a password. Nothing
// locally observable predicts that, which is the useful thing to know.
static void printStoreSession(id store) {
    if (![store respondsToSelector:@selector(isExpired)]) return;

    BOOL any = [store isExpired];
    NSMutableArray<NSString *> *perType = [NSMutableArray array];
    for (long long t = 0; t <= 2; t++)
        [perType addObject:[NSString stringWithFormat:@"%lld=%@", t,
                            [store isExpiredForTokenType:t] ? @"exp" : @"ok"]];

    // Live first, cached second, each labelled by where it came from. The two disagree routinely
    // and the difference is the whole point: one is a daemon answering now, the other is a
    // timestamp this process read out of a plist.
    NSString *live = daemonAccountStatus();

    note(@"");
    note(@"  store session");
    note(@"    live     %-46s  appstored, over XPC",
         (live ?: @"(unavailable)").UTF8String);
    note(@"    cached   %-46s  LastAuthTime plist + 900s clock, uid %d",
         ([NSString stringWithFormat:@"isExpired=%@  tokens %@",
           any ? @"YES" : @"no", [perType componentsJoinedByString:@" "]]).UTF8String,
         getuid());
    note(@"             the cached line is NOT a purchase predictor: it reads the same whether a");
    note(@"             purchase succeeds or is refused. Only attempting one tells you that.");

    logLine(@"store session: cached isExpired=%d tokens[%@] uid=%d",
            any, [perType componentsJoinedByString:@" "], getuid());
}

int cmdAccounts(void) {
    id store = accountStore();
    if (!store) return kAccountLoadFailed;
    [store reloadAccounts];
    NSArray<SSAccount *> *accounts = [store accounts];
    if (!accounts) return kAccountLoadFailed;

    note(@"  %-28s %-13s %-18s %-9s %s", "APPLE ID", "DSID", "STOREFRONT", "PW", "STATE");
    printAccountRows(accounts);
    printStoreSession(store);
    return kAccountOK;
}
