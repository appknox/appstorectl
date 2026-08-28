<div align="center">

# appstorectl

**An on-device App Store CLI for jailbroken iOS.**

[![Jailbreak](https://img.shields.io/badge/jailbreak-rootless-5865F2?style=flat-square)](#requirements)
[![Built with Theos](https://img.shields.io/badge/built%20with-Theos-FF6B35?style=flat-square)](https://theos.dev)

[Requirements](#requirements) · [Install](#install) · [Usage](#usage) · [Export](#export-and-decryption) · [Documentation](#documentation)

</div>

Installation uses the device's signed-in App Store account and Apple's own `appstored` purchase pipeline. Export rebuilds an IPA from the installed app and decrypts its Mach-O images by default.

Verified on iOS 15.8.1 (19H380) and iOS 16.7.12 (20H364). Other iOS 15 and 16 releases have not been tested.

```console
$ appstorectl install com.netflix.Speedtest
[+] com.netflix.Speedtest  ->  adamId 1133348139   (FAST Speed Test, 0 USD, minOS 7.0)
[+] force-dismiss armed (AutoConfirmSheet tweak will dismiss the sheet)
[+] purchasing com.netflix.Speedtest (adamId 1133348139)
[+] purchased, waiting for install
[+] installed: /var/containers/Bundle/Application/BA34E858-47C5-4731-8EC8-7D2D1161BA40/FAST.app
[+] decrypt     1 encrypted image(s)
      [+] FAST 1 -> 0
[+] wrote       /var/jb/tmp/appstorectl-exports/com.netflix.Speedtest_1.1.1_831172220_decrypted.ipa   468.8 KB
```

An install can run unattended once the account and device authorization state allow it. The first login for an Apple ID on a device requires a verification code. A device with enrolled biometric purchase authorization still prompts for Face ID or Touch ID.

## Requirements

- Rootless jailbreak on a device running a compatible iOS release
- A signed-in App Store account
- Theos for building
- ElleKit, `com.autopear.installipa`, and `zip` on the device

Tested configurations:

| Device | iOS | Build | Jailbreak |
|---|---|---|---|
| iPhone9,3 | 15.8.1 | 19H380 | palera1n |
| iPhone10,3 | 16.7.12 | 20H364 | palera1n |

The project uses private Apple interfaces and may need updates for other OS versions.

## Install

```sh
export THEOS=~/theos
make do THEOS_DEVICE_IP=<device-ip>
```

`make do` builds, packages, installs over SSH, and restarts PassbookUIService so the tweak loads. Set `THEOS_DEVICE_PORT` when SSH is not on port 22.

To install a built package manually:

```sh
scp packages/*.deb root@<device-ip>:/var/jb/tmp/
ssh root@<device-ip> 'apt install /var/jb/tmp/com.appknox.appstorectl_*.deb && killall -9 PassbookUIService'
```

Uninstall with:

```sh
ssh root@<device-ip> 'dpkg -r com.appknox.appstorectl'
```

## Usage

```sh
appstorectl install   <bundle-id> [--adam <id>] [-o <path>] [-q]
appstorectl export    <bundle-id> [-o <path>]
appstorectl resolve   <bundle-id>
appstorectl uninstall <bundle-id>
appstorectl jobs
appstorectl version

appstorectl accounts
appstorectl login     <apple-id> [--password-file <path>] [--show-password] [--no-bootstrap]
appstorectl logout    <apple-id> [--force]

authpref [free|paid] [always|sometimes|never]
```

`install` purchases a free app, waits for installation, exports it, and decrypts the export. Use these options to narrow that default flow:

| Option | Effect |
|---|---|
| `--no-export` | Install without creating an IPA. |
| `--no-decrypt` | Keep exported images FairPlay-encrypted at `cryptid 1`. |
| `--no-dismiss` | Do not arm AutoConfirmSheet; dismiss the confirmation sheet manually. |
| `--no-preflight` | Skip the biometric-state preflight. |
| `--adam <id>` | Skip metadata lookup and use this `adamId`. |
| `-o <path>` | Set the export path. The default directory is `/var/jb/tmp/appstorectl-exports/`. |
| `-q` | Print only errors. Persistent logging remains enabled. |

`login` reads the password from `--password-file`, then `APPSTORECTL_PASSWORD`, then a terminal prompt. Do not pass a password directly on the command line. `--show-password` echoes terminal input, and `--no-bootstrap` fails instead of requesting the first-login verification code. `logout --force` permits removal of the active account. Account behavior is documented in [docs/ACCOUNTS.md](docs/ACCOUNTS.md).

`authpref` with no arguments only reads the current settings. Supplying a value writes an Apple ID setting and may prompt for the account password.

## Export and decryption

```sh
appstorectl export com.reddit.Reddit
```

The resulting archive contains:

```text
Payload/<App>.app/
iTunesMetadata.plist
```

No complete persisted IPA was found during the observed installs; appstored extracted the package while downloading it. `export` therefore reconstructs the archive from the installed container. The result is not byte-identical to Apple's archive: ZIP ordering differs, installd may rewrite the SINF, and the store may deliver a device-thinned slice.

Decryption launches the app or extension and reads the FairPlay-decrypted pages from its process. It operates on a staged copy and never modifies the installed bundle. Afterward, export re-reads every staged image and fails if an encrypted image still has `cryptid 1`. The helper also rejects plaintext that is unchanged or entirely zero and verifies written bytes by reading them back.

Known limitations:

- Only free-app purchases have been implemented and tested.
- On-Demand Resource asset packs are not present in the installed bundle and cannot be exported.
- Decryption requires the target to launch far enough for its encrypted image to be mapped.
- The decrypt helper is arm64. It can drive arm64e targets.
- Staging needs roughly the installed app's size in additional free space.

See [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md) for the complete flow and validation details.

## Authorization and AutoConfirmSheet

Three independent conditions can require interaction:

1. The Apple ID password policy for free downloads. `authpref free never` can change it, but this is an optimization rather than an installation prerequisite.
2. Biometric purchase authorization. The preflight only clears an enabled state that has no valid enrolled identity. It leaves a working Face ID or Touch ID configuration alone.
3. The ordinary purchase confirmation sheet. AutoConfirmSheet dismisses this sheet; it never approves or authorizes a payment.

`--force-dismiss`, enabled by default, creates `/var/jb/tmp/.autoconfirm`. The tweak accepts a flag for at most five minutes and consumes it when the first matching sheet appears. It acts only inside PassbookUIService and only on `PKPaymentAuthorizationRemoteAlertViewController`. The CLI removes the flag when the purchase call ends normally.

See [docs/GATES.md](docs/GATES.md) when an install still requests a password or biometric approval.

## Logs and privacy

`appstorectl` appends to `/var/jb/var/log/appstorectl.log` with mode `0600`. The log can contain account identifiers, store error payloads, and raw purchase parameters. `-q` affects terminal output only; it does not disable this log. Remove it when no longer needed:

```sh
rm /var/jb/var/log/appstorectl.log
```

AutoConfirmSheet writes its decisions to `/var/jb/tmp/autoconfirm.log`.

## Troubleshooting

**The install stalls at `percentComplete -1`.** Check the app's minimum OS with `appstorectl resolve <bundle-id>`. Use `appstorectl jobs` to inspect stuck jobs.

**Every purchase requests a password or biometric approval.** Check the returned `dialogId`, then use [docs/GATES.md](docs/GATES.md) to identify the remaining authorization condition.

**`zip failed`.** Install the dependency with `apt install zip`. Use `apt install` for the project package so its declared dependencies are resolved.

## Documentation

- [How it works](docs/HOW-IT-WORKS.md)
- [Purchase pipeline](docs/PIPELINE.md)
- [Authorization gates](docs/GATES.md)
- [Account commands](docs/ACCOUNTS.md)
- [Authentication internals](docs/AUTH-INTERNALS.md)
- [Implementation findings](docs/FINDINGS.md)
- [Development notes](DEVELOPING.md)

## License

MIT. See [LICENSE](LICENSE).

## Credits

Thanks to [londek/ipadecrypt](https://github.com/londek/ipadecrypt) for prior work that informed this decryptor.
