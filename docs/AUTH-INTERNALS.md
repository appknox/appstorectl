# How sign-in works underneath

Reference for [ACCOUNTS.md](ACCOUNTS.md). Addresses are from **iOS 16.7.12 (20H364)** binaries.
Private API throughout, so re-verify before assuming any of it holds on another release.

## Two systems that look like one

| | AuthKit | StoreServices |
|---|---|---|
| entry point | `AKAppleIDAuthenticationController` | `SSAuthenticateRequest` |
| gives you | Apple ID identity, GrandSlam tokens, **device trust** | an authenticated **iTunes Store account** |
| can present a two-factor prompt | **yes**, reads the code from stdin | **no**, ever |

They do not substitute for each other. An AuthKit sign-in returns a real altDSID, DSID and GrandSlam
tokens and still leaves the store account signed out. Feeding those tokens to the store as a
password-equivalent token is rejected outright with `SSServerErrorDomain -5000`.

## What `-5000` means

Not "wrong password". **It means this device holds no two-factor-established trust for this Apple
ID.**

Measured on one account, same password, same code path, inside an hour:

| state | store login |
|---|---|
| after an AuthKit sign-in **that was challenged**, code entered | works, repeatedly |
| after an AuthKit sign-in that **succeeded but was not challenged** | `-5000` |
| no AuthKit sign-in at all | `-5000` |

The middle row is what makes it conclusive rather than circumstantial: AuthKit fully succeeded,
returned the correct DSID and both GrandSlam tokens, and the store still refused, because the device
already held cached identity for that Apple ID and so was never challenged.

`AKDidShowServerUI = 1` is present in the results dictionary **only** when the server actually
presented a challenge. That single key is the difference between a sign-in that establishes trust
and one that changes nothing, and `authkit.m` checks it rather than trusting a bare success.

What is still unknown: *where* the trust is kept (a local artifact or a server-side device record),
how long it lasts, and what revokes it. The operational rule is settled; the mechanism is not.

## The store path

`-[SSAuthenticateRequest startWithAuthenticateResponseBlock:]` at `0x1a1a31120`.

```
├─ ROUTE A, out to itunesstored over XPC. Taken when ANY of:
│     ctx.forceDaemonAuthentication
│     !+[SSAuthenticateRequest _isAuthkitEntitled]        0x1a19dcd4c
│     the host bundle is com.apple.appstored
│
└─ ROUTE B, in process. What this tool takes.
   ├─ acct = +_accountToAuthenticateWithAuthenticationContext:      0x1a1a328d0
   ├─ gate: -_shouldRunAuthenticationForAccount:                    0x1a1a34d5c
   ├─ gate passes -> [SSAccountStore updateAccountWithAuthKit:store:options:]
   └─ gate fails   -> returns type 4 HAVING CONTACTED NOBODY
```

### Two traps in that diagram

**A reported success can mean nothing.** When the `promptStyle` gate declines, the skip branch fills
in `setAuthenticatedAccount:` and `authenticateResponseType = 4` without any network call. That is
why `login` re-reads the account store instead of trusting the response.

**`promptStyle` decides whether anything happens at all.** From `_shouldRunAuthenticationForAccount:`:

| `promptStyle` | behaviour |
|---|---|
| account is nil | authenticate |
| **1** | **authenticate, unconditionally** |
| 1000 | never |
| 1001 | only when `!isAuthenticated` |
| anything else, **0 included** | only when the token type is expired, else only when `!isAuthenticated` |

The default is 0. `login` sets 1.

## How an account gets picked, or created

`+_accountToAuthenticateWithAuthenticationContext:` resolves through
`-[AMSAccountStore ams_iTunesAccountWithAltDSID:DSID:username:]`, then branches. Apple's own log
strings:

| case | behaviour |
|---|---|
| a match exists | "Found an existing account." |
| no match, username given | **"...since we were given a username (%@), we'll create one."** |
| no match, no username | "...The user will be prompted to enter their username and password." |

So signing in an Apple ID the device has never seen is the *designed* path, not an edge case.
`login` therefore leaves `altDSID` and `requiredUniqueIdentifier` **unset**: with only a username, a
miss lands in the create branch. Supplying an altDSID risks matching an unrelated local record.

> [!WARNING]
> That lookup is **case-sensitive**. `Me@example.com` will not match a stored `me@example.com`; it
> misses, takes the create branch, and then `AMSAccountNotificationPlugin` refuses the save with
> `com.apple.accounts` code 5, *"Only a single 'iTunes Store' account is allowed to be saved."*
> `findAccount()` in `account.m` compares case-insensitively, which can hide this.

## Credentials the store accepts

The same function ends by copying exactly two things onto the account:

```objc
if (context.password)                [account setRawPassword:context.password];
if (context.passwordEquivalentToken) [account setPasswordEquivalentToken:context...Token];
```

Nothing else crosses over, and only the password is reachable by a caller. A store PET is an
`ACAccountCredential` item on the account itself — `-[SSAccount passwordEquivalentToken]` reads
`[[[self _backingAccount] credential] credentialItemForKey:]` — and the one API that would fetch one
for another account,
`-[SSAccountStore _passwordEquivalentTokenFromAlternateAccountWithAltDSID:DSID:username:]` at
`0x1a1a49088`, is a stub on iOS:

```asm
MOV  X0, #0
RET
```

## The credential ladder

`updateAccountWithAuthKit:store:options:` builds four promises and combines them with
`+[SSPromise promiseWithAny:]`. That reads like a race and is not one:
`_configureAnyPromise:withPomises:currentPromiseIndex:` attaches to index N, cancels everything after
it on success, and recurses with N+1 on error. A sequential fallback chain, tried in this order:

| order | rung | `credentialSource` on success |
|---|---|---|
| 1st | SilentPETAuth | 4 (own PET) or 2 (alternate-account PET) |
| 2nd | SilentPasswordAuth | 5 |
| 3rd | SilentAuth | 3 |
| 4th | PromptAuth | 1 |

`credentialSource` is weaker evidence than it looks: the outer
`updateAccountWithAuthKit:store:options:` can set it straight from
`options["SSAccountStoreAuthKitCredentialSource"]` regardless of which rung ran. Treat it as
informational.

## Removal

`-[SSAccountStore removeAccount:completion:]` at `0x1a1a3f890` delegates to
`-[ACAccountStore removeAccount:withCompletionHandler:]`.

`accountsd` gates it in `-[ACDAccountStoreFilter _isClientPermittedToRemoveAccount:]`
(`0x1e9d7abd4` in AccountsDaemon), which allows a removal on any of: one type-independent
entitlement, one of two type-specific ones, or **the client owning the account**. An account created
through `SSAuthenticateRequest` is not ours, so the entitlement is required. Bisected on device to
`com.apple.private.accounts.allaccounts`.

> [!NOTE]
> Do **not** use the synchronous `-[SSAccountStore removeAccount:error:]` (`0x1a1a3f514`). It blocks
> on a semaphore with a five second timeout, so if the completion lands on the queue you are
> blocking it deadlocks into *"Timed out while trying to remove %@"* — a threading mistake that
> reads as a failed removal.

## The stale-cache trap, which bites every one of these

Both the sign-in and the removal completions fire **before** `accountsd`'s accounts-changed Darwin
notification is delivered, and `reloadAccounts` keeps serving the cached snapshot until it lands.
Reading once, immediately, reports a successful removal as a failure and a freshly created account as
absent.

The notification is only delivered on a runloop turn, so the wait has to spin the runloop rather than
sleep. `waitForAccount()` in `account.m` does that; nothing here should call
`sleepForTimeInterval:`.

## Switching the active account

Not exposed as a command yet, but the reversing is done and it matters for multi-region work.

Do **not** call `-[SSAccountStore setActiveAccount:]` (`0x1a1a4c98c`). It calls `saveAccount:error:`,
which hardcodes `verifyCredentials:1` and cannot be told otherwise — the call that raises
`AMSErrorDomain 11`. Its own nil path logs the alternative:

> *"`-[SSAccountStore setActiveAccount:]` is deprecated. The caller should get the active account, set
> its active property to NO, and save it."*

which in practice is:

```objc
[previous setActive:NO];  [store saveAccount:previous verifyCredentials:NO error:&e];
[target   setActive:YES]; [store saveAccount:target   verifyCredentials:NO error:&e];
```

Both saves come back clean. The device storefront then follows the active account.

> [!CAUTION]
> Deactivating the only authenticated account leaves the device with none, and it cannot bootstrap
> back out of that from a shell — it takes a normal sign-in through Settings. Deactivate only as part
> of activating something else, and only when the target is already authenticated.
