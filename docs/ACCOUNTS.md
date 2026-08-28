# Signing Apple IDs in and out

`appstorectl` can sign an Apple ID in to the iTunes Store from a shell, list what the device holds,
and remove an account again. Useful for a device that has to switch between accounts, or reach a
storefront the current account does not own.

```sh
appstorectl accounts
appstorectl login  <apple-id> [--password-file <path>] [--show-password] [--no-bootstrap]
appstorectl logout <apple-id> [--force]
```

## The one manual step

**The first sign-in for an Apple ID on a device needs a verification code typed by a human.** After
that, every sign-in for that pair is unattended.

That is not a limitation of this tool. The store's own authentication path never presents a
two-factor challenge; it just refuses. The prompt exists only in AuthKit, which reads the code from
stdin. `login` drives both, so it is one command rather than two, but somebody still has to be at a
terminal the first time.

For a fleet, plan on one interactive step per (device, Apple ID) at provisioning.

```
first time, on a terminal              every time after, unattended
──────────────────────────             ────────────────────────────
$ appstorectl login me@example.com     $ appstorectl login me@example.com
Apple ID password: ******              [*] password: 14 characters, from environment
[*] signing in ...                     [*] signing in me@example.com ...
[*] me@example.com is not trusted      [+] signed in me@example.com  storefront 143441-1,29
    on this device yet. ...
Enter second factor code: 123456
[+] two-factor trust established
[*] retrying the store sign-in ...
[+] signed in me@example.com
```

## Passwords

Never on the command line — `ps` shows it to every process on the device. `login` reads it, in
order, from:

1. `--password-file <path>`
2. `$APPSTORECTL_PASSWORD`
3. an interactive prompt, if stdin is a terminal

It always prints the length and the source before contacting Apple:

```
[*] password: 14 characters, from prompt
```

That one line separates a wrong credential from a mis-read one, which the server reports
identically. `--show-password` echoes what you type if you need to see it.

> [!NOTE]
> `getpass()` truncates silently at 128 characters. `login` warns when you are near that; use
> `--password-file` for anything longer.

## Exit codes

Every path sets one deliberately, so a script can branch without parsing prose.

| code | meaning |
|---|---|
| `0` | done |
| `10` | the store rejected the credentials |
| `11` | authentication failed some other way |
| `12` | the daemon never replied |
| `13` | reported success, but re-reading the account store disagreed |
| `20` | no account matches that Apple ID |
| `21` | a safety guard declined |
| `22` | removal reported failure |
| `64` | usage |
| `65` | no password source, and no terminal to ask on |
| `66` | a verification code is needed and there is no terminal |
| `67` | AuthKit signed in from cache without a challenge, so no trust was established |
| `68` | the password itself is wrong |

`--no-bootstrap` makes `login` return `10` instead of trying the interactive step. Use it for
unattended callers that have nobody to type a code.

## logout

There is **no UI for this**. Settings → Media & Purchases lists only the *active* store account, so
an account signed in by `login` and left inactive is invisible there and can only be removed here.

Three guards:

- the `local` pseudo-account can never be removed
- the **active** account needs `--force` as well
- the result is verified against the account store rather than trusted from the completion

## Troubleshooting

**`the server rejected the credentials`, and the password is definitely right.**

That is the expected first response for an Apple ID this device has never completed a verification
code for. Run `login` on a terminal and it will ask for one. If you are already on a terminal and it
still fails, the AuthKit error printed underneath is the real answer.

**`AKAuthenticationError -7006` / `M2 missing (bad password)`.**

The password is wrong. No code was sent.

**`AuthKit signed in ... but was NOT challenged for a code`.**

AuthKit answered from identity the device already had, which establishes no store trust, so the
store will keep refusing. Seen when the Apple ID is already used for iCloud on that device. There is
no known way to force a challenge from here.

**`not AuthKit-entitled`.**

The binary is missing `com.apple.authkit.client.private` / `.internal`. Theos caches code
signatures, so a Makefile change alone is not enough — delete the built binary, rebuild, and check
with `ldid -e /var/jb/usr/bin/appstorectl`.

## Entitlements these commands need

Beyond `com.apple.itunesstored.private`, which gates everything else in this tool:

| entitlement | needed for |
|---|---|
| `com.apple.authkit.client.private` | the two-factor bootstrap |
| `com.apple.authkit.client.internal` | either one works; both are signed in |
| `com.apple.private.accounts.allaccounts` | `logout` |

Without the AuthKit pair the request is shipped to `itunesstored` over XPC instead of running in
process, and a challenge can be neither presented nor answered. Without the accounts one, `logout`
gets `com.apple.accounts` code 7, *"The application is not permitted to delete iTunes Store
accounts"*.

## Caveats

- **Only one account is active at a time**, and the device storefront follows it. Signing a second
  account in does not switch to it.
- These commands do **not** need to run as `mobile`, unlike the biometric pre-flight. Accounts live
  in `accountsd`, which is system-wide, not in mobile's preference domain.
- An AuthKit sign-in for an Apple ID the device also uses for iCloud can create a lot of service
  accounts (Find My, CloudKit, CalDAV, Mail, Game Center). For a fresh Apple ID it creates almost
  nothing. Know which you are doing before running it on a personal device.

See [AUTH-INTERNALS.md](AUTH-INTERNALS.md) for why any of this works.
