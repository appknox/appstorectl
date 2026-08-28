# CLAUDE.md

Project-specific guidance for working in this repo.

## What this is

A CLI (`appstorectl`) that drives **appstored**'s real purchase pipeline over XPC to buy, install
and export App Store apps from a shell, plus a tweak (**AutoConfirmSheet**) that dismisses the one
dialog which would otherwise require a tap.

Source is split by concern: `appstorectl.m` owns purchase, install and dispatch; `export.m` packages
an installed app; `biometric.m` is the gate 2 pre-flight. `appstorectl.h` is the seam between them
and holds only what is genuinely shared. Keep it that way rather than growing `appstorectl.m`.

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

## The biometric pre-flight

`install` calls `biometricPreflight()` before spending a purchase. It exists because an account can
be opted into biometric purchase auth (`BiometricStateEnabled = 2`) on a device with no enrolled
identity — remove the passcode, and `+[ISBiometricStore shouldUseAutoEnrollment]` (URL-bag driven,
server rollout, observed **YES**) silently re-opts the account in on the next sign-in. The store then
demands an `X-Apple-TID-*` signature that cannot exist, answers with
`MZCommerce.ConfirmPaymentSheet.Auth`, and no amount of sheet-dismissing produces a credential.

Two constraints, both measured, both easy to undo by accident:

**Clear BOTH keys.** `-[ISBiometricStore setBiometricState:]` writes `BiometricState`; the gate that
matters, `-isBiometricStateEnabled`, reads `BiometricStateEnabled`, and nothing public writes it.
Clearing only the first leaves the biometric branch armed while looking fixed.

**Do it as uid 501.** These prefs live in mobile's domain. `appstorectl` runs as root, and as root
the same reads return `BiometricState 0` / `isBiometricStateEnabled NO` — a confident clean bill of
health for a domain no daemon consults. Hence the fork + `setuid(501)` + `execv` of the internal
`_biometric-preflight` subcommand. It is fork+**exec**, not a bare fork, because the process has
already touched ObjC, XPC and CoreFoundation.

It only ever clears an opt-in that is already impossible to satisfy: enabled **and**
`isIdentityMapValidForAccountIdentifier:` NO. An enrolled device keeps its biometric prompt. It never
enables biometric auth, and it never fails the install — `--no-preflight` skips it entirely.

## Export

`export` reconstructs a `.ipa` from the installed container. It does **not** copy a downloaded file,
because one never exists: `IXPromisedStreamingZipTransfer` extracts the archive while it is still
downloading, and `/var/mobile/Media/Downloads/` holds only the queue database.

What goes in: `Payload/<App>.app/` (with `SC_Info/` and `_CodeSignature/`) plus the container's
`iTunesMetadata.plist`. What stays out: `BundleMetadata.plist` and
`.com.apple.mobile_container_manager.metadata.plist`, which are device-local installd bookkeeping.

**Validate against `SinfPaths` AND `SinfReplicationPaths`.** `SC_Info/Manifest.plist` has both keys
and they differ. On Opera, `SinfPaths` lists one entry while `SinfReplicationPaths` lists all six
including every `PlugIns/*.appex`. Checking only the first passes an archive missing every
extension's sinf. On an app with no extensions the two are identical, which is exactly why this
never shows up until you test a plugin-bearing app.

**Zip with `-y`, and run zip inside the staging dir.** Without `-y` it follows symlinks inside the
bundle and silently inflates the archive with duplicated frameworks. It has to run with the staging
dir as cwd so paths come out rooted at `Payload/`, and since
`posix_spawn_file_actions_addchdir_np` is unavailable on iOS, that is a fork + `chdir` + `execv`.

Export never decrypts. `cryptid` stays 1. Do not add a decryption path here.

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
with `retry rejected by the store` followed by the full server payload. That looks like a broken
tweak and is not. Read `dialogId` in the payload to tell which gate:

| dialogId | gate |
|---|---|
| `MZCommerce.ConfirmPaymentSheet` | none, the tweak handles this |
| `MZCommerce.ConfirmPaymentSheet.Auth` | gate 2 armed but unsatisfiable |
| `MZCommerce.TID.SignatureRequired` | gate 2 armed and enrolled |

`authpref` with no arguments is a read and is safe. Passing a value **writes to the Apple ID
server-side** and prompts for a password once, so do not run the write on a device mid-automation.

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
