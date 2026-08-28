# Findings

The non-obvious things, roughly in order of how much time each cost.

## purchaseID must be nonzero

`ASDPurchase.purchaseID` defaults to **0**, and with 0 the purchase *succeeds* — `success = 1`, a
placeholder appears on the Home Screen — and then nothing ever downloads. The job sits like this
indefinitely:

```
bundleID          com.netflix.Speedtest
storeItemID       1133348139
failureError      (nil)          <- no error at all
percentComplete   -1             <- never started
phase             9
orderKey          (nil)          <- no queue position
purchaseID        0
```

appstored correlates a job back to its purchase through `purchaseID`. With 0 the job is created but
never scheduled. Nothing fails, so nothing is reported.

Set any nonzero value and the whole pipeline runs to completion.

### What phase 9 means

`-[JobManagerListener _externalPhaseForPhase:]` (`0x10022ba34`) maps internal phases to what a
client sees:

```
internal   external
  -40   ->   4        15,20 -> 7
  -30   ->   0        30    -> 2
  -20   ->   3        40,50 -> 5
  -15,-10 -> 6
  default ->  9        <- everything unmapped lands here
```

So 9 is a fallback bucket, not a state. `+[AppInstallQueue _computedPhaseForCoordinatorState:allowResume:]`
(`0x100323f28`) shows coordinator states 0 and 1 give internal phase **10**, which has no entry
above. Phase 9 therefore means *the install coordinator exists in its initial state and never
advanced* — consistent with `orderKey = nil`.

## One entitlement, and it is not the obvious one

`com.apple.itunesstored.private` — alone. Bisected one entitlement at a time against both the
purchase and purchase-history services:

| entitlement | result |
|---|---|
| **`com.apple.itunesstored.private`** | **works** |
| `com.apple.appstored.private` | 505 |
| `com.apple.appstored.install-apps` | 505 |
| `com.apple.appstored.update-apps` | 505 |
| `com.apple.appstored.jobmanager` | 505 |
| `com.apple.appstored.coordinate-apps` | 505 |
| `com.apple.appstored.xpc.updates` | 505 |

`-[StoreQueueListener listener:shouldAcceptNewConnection:]` (`0x1000712c4`) accepts on any of
`appstored.private`, `appstored.install-apps` or `itunesstored.private` — but that is a *different
listener*. `ASDPurchaseManager` goes through the service catalog, gated in
`-[XPCServiceClient _provideService:forEntitlement:withReply:]` (`0x100190328`), which raises
`ASDErrorDomain 505 "Not entitled for this service."`

## Reply blocks: wrong arity is a crash, and probing is also a crash

`ipsw class-dump` renders every completion handler as `(id /* block */)handler` — no argument types.
Declaring one wrong is not graceful:

```
EXC_BAD_ACCESS (SIGBUS), (Data Abort) byte read Alignment fault
  objc_retain + 8
  objc_storeStrong + 44
  __main_block_invoke + 56
  __NSXPCCONNECTION_IS_CALLING_OUT_TO_REPLY_BLOCK__
```

ARC emitted `objc_storeStrong` on an argument slot holding a leftover register value.

Inspecting the slots to find out is *also* unsafe: a bad pointer raises SIGSEGV, and `@try` catches
ObjC exceptions, not signals. Two tools crashed that way.

The safe pattern:

1. **declare the block with no arguments** — always valid to invoke, extra registers ignored
2. confirm the outcome by re-reading state

To actually discover an arity, build non-ARC, over-declare as four `void *`, and print the raw
registers. That is how `updateWithCompletionHandler:` was found to be `^(NSError *)` — one argument,
not two.

## One service proxy, not two

Calling `+[ASDServiceBroker defaultBroker] getPurchaseServiceWithError:` while a `startPurchase:`
is in flight kills it:

```
NSCocoaErrorDomain 4099
"The connection to service named com.apple.appstored.xpc was interrupted, but the message was sent
 over an additional proxy and therefore this proxy has become invalid."
```

Standing up a second connection invalidates the first one's reply proxy. Fetch the service proxy
once, hold it, and send everything over it.

## The store answers with dialogs, not verdicts

A rejected purchase returns **HTTP 200** with a dialog in the payload. Sending a deliberately
invalid purchase produced:

```
dialogId    = "MZCommerce.TID.SignatureRequired"
customerMessage = "Sign In to iTunes Store"
okButtonAction.buyParams = "isInApp=false&icloud-backup-enabled=1&clientCorrelationKey=…
                            &guid=…&hasBeenAuthedForBuy=true&ageCheck=true&ad-networks=%28%20%20%29"
```

`okButtonAction.buyParams` is Apple's server telling the client exactly what to resend once the user
agrees. That mechanism is what makes hands-off operation possible — dismiss the sheet, take the
`confirmedPaymentUUID` it hands back, resend.

## Incompatible apps stall silently

An app whose `minimumOsVersion` exceeds the device is **still purchased**. appstored creates a
placeholder, and the job parks at `percentComplete -1` with `failureError = nil`. There is no error
at any layer.

Observed with Chrome (minOS 18.0 on iOS 15.8.1). The store served version `152.x` — the current
build — rather than a last-compatible one.

`cancelJobsWithIDs:` clears both job and placeholder container, leaving no orphan icon.

Check `minOS` with `resolve` first.

## The store .ipa never exists as a file

`IXPromisedStreamingZipTransfer` extracts the archive **while it downloads**. Confirmed empirically:
`/var/mobile/Media/Downloads/` holds only `downloads.28.sqlitedb`, the queue database, with zero
payload at any point during or after an install.

So there is no "grab the downloaded ipa" moment. `export` reconstructs the package from the
installed container instead. The result is a genuine FairPlay-encrypted archive (`cryptid 1`,
verified on the main binary and on all five of Opera's app extensions), but it is not byte-identical
to Apple's: zip ordering differs, the `.sinf` is this Apple ID's, and the store already thinned the
slice server-side (`variantID = 1:iPhone10,3:16`).

Timestamps prove where the sinf comes from. On a FAST install, `SC_Info/FAST.sinf` carries the
install time while `.supp`, `.supf`, `.supx` and `Manifest.plist` all carry the archive's own date
from 2022. installd writes the sinf per Apple ID at install time; the rest ships in the ipa.

## SinfPaths is not the list you want

`SC_Info/Manifest.plist` holds two keys, and on an app with extensions they differ:

```
SinfPaths            => [ SC_Info/Opera.sinf ]                      1 entry
SinfReplicationPaths => [ ...5 appex sinfs..., SC_Info/Opera.sinf ] 6 entries
```

Validating an export against `SinfPaths` alone passes an archive missing every extension's sinf.
On an app with no extensions the two keys are identical, so this is invisible until a plugin-bearing
app is tested. `export` takes the union.

## Two biometric keys, and the public setter writes the wrong one

`com.apple.itunesstored` holds both `BiometricState` and `BiometricStateEnabled`. Measured on
16.7.12:

| wrote | `-biometricState` | `-isBiometricStateEnabled` |
|---|---|---|
| `BiometricState = 0` only | `0` | **`YES`** |
| both keys `= 0` | `0` | `NO` |

`-[ISBiometricStore setBiometricState:]` is the only public setter and it writes the first key;
`-isBiometricStateEnabled`, which gates the biometric branch, reads the second. Nothing public
writes it, only the Settings opt-out via `ISBiometricOptInOperation _updateTouchIDSettingsForAccount:`.

Note `docs/GATES.md` records `isBiometricStateEnabled` as `biometricState == 2` from the 15.8.1
decompilation at `0x1ba753a78`. That may still hold there; the table above is a live read on 16.7.12.

## Running as root reads the wrong preferences

Two files exist, and only one matters:

```
/var/root/Library/Preferences/com.apple.itunesstored.plist      5 keys, created by our own tools
/var/mobile/Library/Preferences/com.apple.itunesstored.plist   90 keys, what the daemons read
```

`appstored`, `itunesstored` and `installcoordinationd` all run as **mobile**. A root process reading
`BiometricState` finds the key absent, returns `0`, and reports a clean bill of health for a domain
no daemon consults. This silently inverted a diagnosis until caught. Anything touching these prefs
must run as uid 501.

The purchase session is unaffected by this: it belongs to appstored and resolves identically from
any uid. Only in-process preference reads are per-uid.

## The client's own expiry check is not what gates a purchase

`+[SSAccountStore isExpiredForTokenType:]` is `now > LastAuthTime + 900.0` (the interval is a bare
`ldr d0` of the double at `0x192ba3d28`), and a missing `LastAuthTime` counts as expired.

Observed during a **successful** purchase: `isExpired` YES for token types 0, 1 and 2, with
`LastAuthTime` 32 hours stale. `resetExpirationForTokenType:` is what writes that key, and the AMS
payment-sheet auth path never calls it. So the client sits permanently "expired" while purchases
work fine on a separate, server-side clock. Do not use it as a health signal.

## Smaller things

- **`ASDPurchaseResult.itemID` is nil even on success.** Check `success`, then verify the install
  separately.
- **`notificationCenter:receivedProgress:` delivers an NSArray** of `ASDProgress`, despite the
  singular selector name.
- **`bagKey = "downloadProduct"` is the accountless path**, not a redownload. It routes to
  `downloaddispatch.itunes.apple.com/r/accountless` and fails with `13014
  MZFinance.DownloadProductRequestParseError`. For a redownload of an owned item, stay on
  `buyProduct`.
- **Binaries must live under `/var/jb`.** On palera1n rootless a binary in `/tmp` is SIGKILLed even
  ad-hoc signed — hello-world included. The identical file under `/var/jb/tmp/` runs.
- **`ASDJobManager` lists in-flight jobs only.** A 1 MB app can finish inside the first poll
  interval. Use the bundle on disk as ground truth for completion, and
  `ASDNotificationCenterProgressObserver` for progress.
- **The container directory name need not match the app.** Firefox installs to `Client.app`. Resolve
  installs through `iTunesMetadata.plist`'s `softwareVersionBundleId`, not the path.
- **`iTunesMetadata.plist` is written at placeholder-creation time**, so its presence proves nothing
  about the payload. A real install has the executable and `SC_Info/<App>.sinf`.
