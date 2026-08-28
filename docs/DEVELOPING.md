# Development notes

appstorectl is a Theos aggregate project with three components:

- `cli/`: purchase, account, install, export, and logging commands
- `decrypt/`: separately entitled helper for reading decrypted process memory
- `tweak/`: AutoConfirmSheet injection for PassbookUIService

The decrypt helper must remain separate from the CLI. It needs `task_for_pid-allow`,
`com.apple.private.cs.debugger`, and `no-sandbox`; the store client does not need those
entitlements.

## Build

```sh
export THEOS=~/theos
make package
make do THEOS_DEVICE_IP=<device-ip>
make -C decrypt test-host
```

Each subproject sets `TARGET` and `ARCHS` explicitly because Theos subprojects do not inherit them
from the aggregate Makefile. Rootless binaries must be installed below `/var/jb`; binaries copied
to `/tmp` are killed on the tested palera1n devices.

## Purchase path

Read [cli/ASDPrivate.h](cli/ASDPrivate.h) and [docs/PIPELINE.md](docs/PIPELINE.md) before changing
the purchase path. These constraints are easy to break silently:

- `ASDPurchase.purchaseID` must be nonzero. A zero ID leaves the install job parked at phase 9.
- Acquire one purchase-service proxy and hold it for the entire request. Opening another proxy can
  invalidate the active reply connection.
- Private completion-block arity is undocumented. Existing zero-argument blocks deliberately ignore
  unknown register arguments and verify results by re-reading state.
- Daemon cache invalidation requires a run-loop turn. Use `runUntilDate:` while polling account
  state, not `sleepForTimeInterval:`.
- `promptStyle = 1` is required for a real sign-in. The default can report a skipped authentication
  as success.
- `SSServerErrorDomain -5000` means the device lacks two-factor-established store trust for that
  Apple ID. AuthKit bootstrap requires a verification code once for that device/account pair.
- Do not replace the active-account sequence with `setActiveAccount:`. The working path is
  `setActive:` followed by `saveAccount:verifyCredentials:NO`.

Account behavior and the cache timing are documented in
[docs/AUTH-INTERNALS.md](docs/AUTH-INTERNALS.md).

## Biometric preflight

The preflight repairs only an enabled biometric purchase state with no valid enrolled identity.
Two implementation details are required:

- Clear both `BiometricState` and `BiometricStateEnabled`; Apple's public setter changes only the
  first key.
- Read and write the preference domain as mobile (uid 501). Root sees a different preference view.
  Re-exec after dropping privileges because the parent has already initialized Objective-C, XPC,
  and CoreFoundation state.

A valid enrolled identity is left untouched. See [docs/GATES.md](docs/GATES.md).

## Export and decrypt

Export operates on a staged copy. Include `Payload/<App>.app/` and `iTunesMetadata.plist`; exclude
the device-local container metadata files. Validate the union of `SinfPaths` and
`SinfReplicationPaths`, because plugin SINF entries may appear only in the latter.

Run `zip` inside the staging directory and keep `-y` so bundle symlinks are stored as links rather
than followed. After decryption, re-read every staged image and fail if any encrypted image still
has `cryptid 1`; the helper can return success after a partial run.

Important decrypt constraints:

- Dump the main image before advancing a ptrace-stopped process into dyld startup.
- Wait for a stable nonzero dyld image count before remote calls.
- Use a canonical remote-call sentinel such as `0xDEAD0000`; non-canonical values can fail PAC on
  arm64e.
- Restore thread state and reply to the Mach exception before issuing another remote call.
- SBS-launched targets require `pid_resume()` to clear xpcproxy's process-level hold.
- Resolve loader symbols from libdyld, then libSystem, then dyld. `_dlopen` was in
  `/usr/lib/system/libdyld.dylib` on iOS 16.7.12.
- Treat `min_os` as diagnostic context, not proof that an image cannot be mapped. Images declaring
  a newer minimum OS have still yielded plaintext on older tested devices.

## AutoConfirmSheet

The tweak may dismiss the purchase-confirmation controller; it must never confirm or authorize a
payment. Keep all three gates:

1. PassbookUIService process filter
2. `PKPaymentAuthorizationRemoteAlertViewController` class match
3. Fresh, one-shot `/var/jb/tmp/.autoconfirm` flag

If `cmdInstall` gains an early return after arming, call `disarm()`. The five-minute expiry is only
a crash fallback.

The dismissal selector is version-dependent and must remain runtime-probed:

| Tested release | Selector |
|---|---|
| iOS 15.8.1 | `dismissWithRemoteOrigination:` |
| iOS 16.7.12 | `askForDismissalWithReason:error:completion:` |

## Logging and validation

`note()` writes to the terminal and persistent log; `logLine()` writes only to the log. `-q`
suppresses terminal output, not `/var/jb/var/log/appstorectl.log`. Keep server payloads and raw
purchase parameters out of normal terminal output.

Before a release:

```sh
make clean package
make -C decrypt test-host
```

Purchase verification requires a jailbroken device and a free app. `appstorectl resolve` is a safe
metadata check; `appstorectl install` creates a real purchase-history entry when the app is absent.

The private interfaces are confirmed only on iOS 15.8.1 and 16.7.12. Re-verify selectors, payload
shape, and daemon behavior on another release.
