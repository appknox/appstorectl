# The three authorization gates

Getting to a hands-off install means clearing three independent mechanisms. They are genuinely
separate: clearing one produces **no visible change** until the others are cleared too, which makes
this confusing to debug from the outside.

| # | Gate | Where it lives | Clear it with |
|---|---|---|---|
| 1 | Password for free downloads | Apple ID account setting, server-synced | `authpref free never`, **or nothing at all**, see below |
| 2 | Biometric signature | device — `BiometricState` | Settings → Touch ID & Passcode → iTunes & App Store off |
| 3 | Confirmation sheet | PassbookUIService, PassKit remote alert | `--force-dismiss` + AutoConfirmSheet |

## Gate 1 — the account password setting

`SSAccount` exposes it client-side, so `authpref` reads and writes it directly:

```objc
@property long long freeDownloadsPasswordSetting;   // 1 = always, 2 = sometimes, 3 = never
@property long long paidPurchasesPasswordSetting;
- (void)updateAccountPasswordSettingsWithRequestProperties:(id)props completionBlock:(id)block;
```

Values map to wire strings in
`-[UpdateAccountPasswordSettingsOperation _serverValueForAccountPasswordSettingValue:defaultValue:]`
(`0x1001d623c`) and are sent as `{"free": …, "paid": …}` by `_newAccountPasswordSettingsDictionary`
(`0x1001d6130`).

**The default is the trap.** `_newAccountPasswordSettingsDictionary` passes
`defaultValue:@"always"`, so an *unset* setting behaves as always-require. An account that looks
unconfigured still prompts.

**The server refuses `paid never`.** `free never` is accepted; the paid setting stays at
`sometimes`. Apple enforces a floor on paid purchases.

This setting lives on the Apple ID and syncs to every device on that account.

### Gate 1 is not actually a prerequisite

Verified on iPhone10,3 / 16.7.12 with `<test-account>`, `2026-08-27`.

When the setting is `unset (0)` the store does not refuse the purchase. It asks, by returning a
second dialog after the confirmation sheet:

```
dialogId          MZCommerce.ASN.AlwaysSometimes.MediaAndPurchases
message           Require password for additional purchases on this device?
okButtonString    Require After 15 Minutes      -> okButtonAction.buyParams  asn=2
cancelButtonString Always Require               -> cancelButtonAction.buyParams asn=1
```

Both button actions carry a **complete** `buyParams` string, including the
`confirmedPaymentUUID` from the first sheet plus `hasBeenAuthedForBuy=true` and
`hasConfirmedPaymentSheet=true`. Replaying `okButtonAction.buyParams` answers the question and the
purchase completes. `cmdInstall` now loops on this rather than retrying once, because the store asks
twice and a single retry left the second question unanswered.

**It does write the account preference, but not visibly at first.** An earlier version of this
document claimed the opposite, on the strength of `authpref` still reporting `unset (0)` immediately
after a successful install. That reading was stale.

`asn=2` is "Require After 15 Minutes", and the store persists it. Measured across a session on
`2026-08-27`: the setting read `unset (0)` for hours and several installs, then settled to
`sometimes (2)`. The local view lags the server write, because itunesstored holds a cached
`SSAccount` and only drops it on a Darwin notification. Do not read `authpref` straight after a
purchase and conclude anything from it.

The observable consequence is the round count:

| `freeDownloadsPasswordSetting` | rounds a purchase needs |
|---|---|
| `unset (0)` | 2 (ConfirmPaymentSheet, then ASN) |
| `sometimes (2)` | 1 (ConfirmPaymentSheet only) |

So gate 1 is **self-clearing**: the first successful purchase answers the ASN question and the
account settles at `sometimes (2)`, after which the dialog never returns. It never reaches
`never (3)` this way, which is what `authpref free never` would have set, but the difference no
longer costs a round trip.

None of this changes the headline: an account sitting at `unset (0)`, on which `authpref free never`
cannot run at all, still installs fine.

Observed end to end on `com.netflix.Speedtest` (2 MB, chosen so the purchase dominates the log),
`2026-08-27`, with the account reading `unset (0)` at the time (see the caveat above about that
reading lagging):

```console
$ appstorectl install com.netflix.Speedtest --force-dismiss --export
[+] purchasing com.netflix.Speedtest (adamId 1133348139)
    attempt with purchaseID 6416205                                   <- 1: ConfirmPaymentSheet
[+] store returned a dialog with confirmedPaymentUUID; resending (round 1)
    attempt with purchaseID 1486764                                   <- 2: ASN dialog
[dialog] store requested a dialog
[dialog] replied nil; dialogs are answered by replaying buyParams
[+] store returned a dialog with confirmedPaymentUUID; resending (round 2)
    attempt with purchaseID 6377010                                   <- 3: completes
[+] purchased, waiting for install
```

Three attempts, two replays. A fresh `purchaseID` per attempt is required, otherwise the store
dedupes the retry onto the first one.

The `[dialog] replied nil` line confirms that the result handler ran without the former
`KERN_INVALID_ADDRESS at 0x1` failure.

On this account, `authpref` cannot run:
`UpdateAccountPasswordSettingsOperation` requires a secure token the account does not hold, and the
account is stuck at `SSServerErrorDomain -5000` (no two-factor store trust for this device). The
meaning of `-5000` is documented in [AUTH-INTERNALS.md](AUTH-INTERNALS.md).
So the practical rule is:

- `authpref free never` is an **optimisation**: it removes one round trip per install.
- It is **not** required. An account that cannot run it still installs fine.

## Gate 2 — biometric signature

```
-[ISBiometricStore isBiometricStateEnabled]   0x1ba753a78
    return biometricState == 2;
```

`BiometricState = 2` in `com.apple.itunesstored.plist` means biometric purchase auth is on. This is
the mechanism behind the `MZCommerce.TID.SignatureRequired` dialog the store returns — the signature
travels in the `X-Apple-TID-*` headers. "TID" is Apple's naming for the device biometric generally,
not specifically Touch ID; a Face ID device uses the same headers and selectors.

> **Two keys, and the decompilation above is not the whole story on 16.7.12.** The plist holds both
> `BiometricState` and `BiometricStateEnabled`, read by different accessors. Live on 16.7.12:
> writing `BiometricState = 0` alone leaves `-isBiometricStateEnabled` returning **YES**; it only
> flips to NO once `BiometricStateEnabled` is also `0`. `-[ISBiometricStore setBiometricState:]`,
> the only public setter, writes just the first, so clearing it alone leaves the biometric branch
> armed.
>
> Related: `+[ISBiometricStore shouldUseAutoEnrollment]` is URL-bag driven and was **YES** on
> 16.7.12, so the server can silently re-opt an account into biometric auth on sign-in. A device
> with no passcode then ends up opted into a biometric it cannot perform, and every purchase falls
> back to a password prompt (`MZCommerce.ConfirmPaymentSheet.Auth`).

Clearing it is a Settings action, not a plist write. `ISBiometricStore` also has
`registerAccountIdentifier:`, `createX509CertChainDataForAccountIdentifier:purpose:error:` and
`deleteKeychainTokensForAccountIdentifier:error:` — the biometric identity is registered
server-side with a cert chain, so poking `BiometricState` directly desyncs device and server.
`ISBiometricOptInOperation` is the supported teardown.

With gates 1 and 2 cleared, the Touch ID prompt is replaced by a plain confirmation tap.

## Gate 3 — the confirmation sheet

This one has no client-side switch at all.

### It is not answerable through appstored

`-[PerformPurchaseTask handleDialogRequest:purchase:purchaseQueue:completion:]` (`0x1001e60a4`)
routes dialogs:

```
if (deviceIsAppleWatch || presenter.useLocalAuthAndSystemDialogs)
        -> AMSSystemAlertDialogTask present
else if (presenter.useLocalAuthAndInteractiveDialogs)
        -> interactive path (AskPermission extension)
else if (requestToken.notificationClient != nil)
        -> deliverDialogRequest: to a registered client observer
else
        -> ASDErrorDomain 1061 "No client available to handle dialog request"
```

`setUseLocalAuthAndSystemDialogs:` is called from exactly one place — `ManagedApplicationTask`
`_purchaseInfoWithMetadata:`, the MDM path — so for a normal purchase it is NO, and the client
observer branch should be taken.

It is not. The failure arrives as `AMSErrorDomain 6 "Payment sheet cancelled"`, never `1061`, and a
registered dialog observer is never invoked. **The sheet is presented by AppleMediaServices upstream
of appstored's dialog delegate.**

Things that consequently do not work:

| attempt | result |
|---|---|
| `setDialogObserver:` + auto-accept | observer never called |
| `notifyDialogCompleteForPurchaseID:result:selectedButton:` | accepted, no error, **no-op** — it completes dialogs delivered to a client, and AMS registered none |
| suppressing it via `ASDPurchase` | no field maps to `PurchaseInfo.suppressDialogs`; `skipsConfirmationDialogs` is never set from client input |

### Who actually draws it

Snapshotting the process table during a purchase:

```
1798  07:11:00  appstorectl
1801  07:11:03  /Applications/PassbookUIService.app/PassbookUIService
```

Terminating PassbookUIService dismisses the sheet. Hooking
`-[UIViewController presentViewController:animated:completion:]` inside it names the controller:

```
PKPaymentAuthorizationServiceCompactNavigationContainerController
  (from PKPaymentAuthorizationRemoteAlertViewController)
```

A PassKit payment-authorization remote alert. Note PassbookUIService links PassKit and **not**
AppleMediaServicesUI — an earlier attempt to hook `AMSUIAlertDialogTask` there only resolved the
class because the tweak's own `dlopen` pulled the framework in, and could never have fired.

### Dismissing is sufficient

The sheet does not need confirming. Its rejection payload contains:

```
dialog.okButtonAction.buyParams =
    "pricingParameters=STDQ&salableAdamId=…&confirmedPaymentUUID=<uuid>…"
```

That is the server telling the client what to resend. `appstorectl` scrapes the
`confirmedPaymentUUID` out of `AMSServerPayload_desc` and replays the purchase, which completes
without a second sheet.

So AutoConfirmSheet only calls `dismissWithRemoteOrigination:` — never authorizes. Worst case is a
cancelled sheet.
