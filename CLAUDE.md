# CLAUDE.md

Project-specific guidance for working in this repo.

## What this is

A CLI (`appstorectl`) that drives **appstored**'s real purchase pipeline over XPC to buy and install
App Store apps from a shell, plus a tweak (**AutoConfirmSheet**) that dismisses the one dialog which
would otherwise require a tap.

It is not a store-protocol reimplementation. Everything goes through Apple's own daemons. When
something fails, the cause is almost always a daemon-side rule, not our code.

Read [`cli/ASDPrivate.h`](cli/ASDPrivate.h) before touching either tool — it documents the
non-obvious constraints inline.

## Build and deploy

```sh
export THEOS=~/theos
make do THEOS_DEVICE_IP=<device-ip>     # build + package + install + bounce PassbookUIService
make package                            # package only
```

Theos aggregate project: `cli/` (tool.mk) and `tweak/` (tweak.mk). **Subprojects do not inherit
`TARGET`/`ARCHS` from the root Makefile** — `common.mk` resets them and the default is armv7, which
fails to link. Both sub-Makefiles set them explicitly. Do not remove those lines.

## Non-negotiable constraints

These each cost hours to find. Breaking one produces a confusing failure, not a clear error.

**Binaries must live under `/var/jb`.** On palera1n rootless a binary in `/tmp` is SIGKILLed even
when ad-hoc signed — hello-world included. `_INSTALL_PATH = /usr/bin` resolves to `/var/jb/usr/bin`.

**One entitlement: `com.apple.itunesstored.private`.** Every `com.apple.appstored.*` entitlement
returns `ASDErrorDomain 505 "Not entitled for this service."` Verified by bisecting one at a time.
`appstorectl_CODESIGN_FLAGS = -Sentitlements.plist` applies it at build time.

**`ASDPurchase.purchaseID` must be nonzero.** It defaults to 0, and with 0 the purchase *succeeds*
but the job is never correlated to it, parks at phase 9 (`percentComplete -1`, `orderKey nil`,
`failureError nil`) and never downloads. No error is raised anywhere.

**Fetch the purchase service proxy once and hold it.** Requesting a second proxy while a
`startPurchase:` is in flight kills the first one's reply with `NSCocoaErrorDomain 4099`.

**Private reply blocks: declare with NO arguments.** class-dump gives no argument types. Wrong arity
is a SIGBUS inside `objc_retain` (ARC retains a scalar slot). *Probing* the slots is also unsafe —
a bad pointer raises SIGSEGV and `@try` catches ObjC exceptions, not signals. Declare zero
arguments, then verify by re-reading state. To genuinely discover an arity, build non-ARC,
over-declare as four `void *`, print the raw registers.

**Use `runUntilDate:`, never `sleepForTimeInterval:`, when waiting for daemon state.** Cache
invalidation arrives as a Darwin notification (`com.apple.itunesstored.accountschanged`), delivered
only on a runloop turn. Sleeping blocks the thread, the notification never lands, and every re-read
returns the same stale object forever — no amount of polling helps.

## The tweak's safety contract

AutoConfirmSheet only ever **dismisses** — see `dismissSheet()` for the per-version selectors.
**It must never confirm or authorize anything.** Dismissal is sufficient: the rejection carries a
`confirmedPaymentUUID` that the CLI replays. Any new candidate added to `dismissSheet()` must be a
dismissal, never a confirmation.

Three conditions gate it. Do not relax any of them:

1. process is PassbookUIService (bundle filter)
2. controller is `PKPaymentAuthorizationRemoteAlertViewController`
3. `/var/jb/tmp/.autoconfirm` exists — created by `--force-dismiss`, removed on **every** exit path

If you add an early return to `cmdInstall`, make sure `disarm()` runs on it. Leaving the flag set
would arm the tweak against unrelated payment sheets.

## Testing

Only meaningful on a real jailbroken device. **Purchases are real and permanent** — they land in the
Apple ID's purchase history and uninstalling does not undo that. Use free apps.

```sh
appstorectl resolve <bundle-id>     # safe: adamId, price, minOS. No purchase.
appstorectl jobs                    # in-flight jobs
cat /var/jb/tmp/autoconfirm.log     # every tweak decision
```

`install` is **not** a status check — for a missing app it starts a real purchase. Do not use it to
query state.

Known-good test targets: `com.netflix.Speedtest` (~1 MB, fast), `com.duckduckgo.mobile.ios`
(180 MB, exercises progress reporting).

Clearing gates 1 and 2 is a prerequisite for `--force-dismiss`. With a password or biometric check
still active the sheet is an *auth prompt*, dismissing it yields no usable UUID, and the retry fails
with `retry rejected` — which looks like a broken tweak but is not.

## Debugging

There is **no `/usr/bin/log` on iOS**, so the unified log cannot be streamed on device. The tweak
writes to `/var/jb/tmp/autoconfirm.log` for exactly this reason. Prefer file-based tracing over
`NSLog` for anything inside an injected process.

`appstored` logs the exact working buyParameters as a `%{public}@` field
(`"[%{public}@] Purchasing with parameters: %{public}@"`), readable with a log archive pulled from
`/var/db/diagnostics` if you need ground truth.

A stalled install (incompatible minOS, etc.) is cleared with `cancelJobsWithIDs:`, which removes the
job *and* its placeholder container.

## Conventions

- Comments explain **why**, especially where the code looks wrong but isn't (the runloop wait, the
  zero-argument blocks, the single service proxy). Those comments are load-bearing — do not tidy
  them away.
- Imports at the top of the file. No inline imports.
- Guard clauses and early returns over nesting.
- Private interfaces belong in `ASDPrivate.h`, annotated, not scattered across `.m` files.

## Background

Deeper reverse-engineering notes live in `docs/`: [PIPELINE.md](docs/PIPELINE.md) for the request
flow with addresses, [GATES.md](docs/GATES.md) for the three authorization gates and how each was
identified, [FINDINGS.md](docs/FINDINGS.md) for everything non-obvious.

All addresses are file offsets in iOS 15.8.1 / 19H380 binaries. Private API throughout — expect
breakage on other releases and re-verify before assuming anything still holds.

## Version-fragile APIs

Two things differ between iOS releases and are already handled adaptively. Do not "simplify" either
back to a single hardcoded case.

**Sheet dismissal selector** — probe with `respondsToSelector:`, never hardcode:

| iOS | selector |
|---|---|
| 15.8.1 (19H380) | `dismissWithRemoteOrigination:` |
| 16.7.12 (20H364) | `askForDismissalWithReason:error:completion:` |

On 16.7 the 15.x selector **and** `_dismiss` are both gone; calling either throws unrecognized
selector. See `dismissSheet()` in `tweak/Tweak.x`.

**Server payload location** — check the dictionary first, then the string:

| iOS | userInfo key | type |
|---|---|---|
| 15.8.1 | `AMSServerPayload_desc` | description string |
| 16.7.12 | `AMSServerPayload` | NSDictionary |

`confirmBuyParamsFromError()` reads `dialog.okButtonAction.buyParams` structurally when the
dictionary is present and falls back to scraping any `AMSServerPayload*` string. Getting this wrong
is silent: the extractor returns nil, no retry happens, and the install just fails with a full error
dump.

Verified working on **15.8.1** and **16.7.12**.
