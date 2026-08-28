# How a purchase actually flows

Firmware: iOS 15.8.1 / 19H380 / iPhone9,3. Addresses are file offsets in the extracted binaries.

## The short version

On the verified `appstorectl` path, the client hands an `ASDPurchase` to **appstored** over XPC.
Apple's daemons own the credentials, URL bag, anti-abuse headers, HTTPS request, download, FairPlay
SINF, and installation. **appstored** creates a Home Screen placeholder through
**installcoordinationd**, the archive is extracted while downloading, and **installd** stages the
bundle, validates the signature, injects the SINF, and registers it with LaunchServices.

The App Store app links the same client frameworks, which is consistent with this division of
work, but its GET-button path was not traced. Treat that connection as inference, not a verified
call path.

## The daemons

| daemon | user | sandbox | mach service |
|---|---|---|---|
| `itunesstored` | mobile | temporary-sandbox | `com.apple.itunesstored.xpc` |
| `appstored` | mobile | appstored | `com.apple.appstored.xpc*`, also hosts `com.apple.storekitservice` |
| `installcoordinationd` | mobile | temporary-sandbox | `com.apple.installcoordinationd` |
| `installd` | **`_installd`** | installd | `com.apple.mobile.installd` |

Two things commonly stated that are wrong:

- **`com.apple.iTunesStore.daemon.public` is not what StoreServices connects to.** It appears in
  itunesstored's launchd plist, but the string exists nowhere in the shared cache or in any of the
  four daemon binaries. Chasing the `initWithServiceName:` argument gives a CFString of length 26 at
  `0x192bc6000` = `com.apple.itunesstored.xpc`.
- **`com.apple.storekitservice` is hosted by appstored**, not itunesstored. Third-party StoreKit IAP
  lands there first.

## Client → appstored

`ASDPurchaseManager` (or the `ASDPurchaseServiceProtocol` proxy directly) sends the purchase.
Inside appstored:

```
-[PurchaseService startPurchase:withReplyHandler:]        0x100317408
    productType == "A"  -> StoreKit IAP service, not the app-install path
    otherwise           -> PurchaseManager processPurchases:

-[ASDPurchase purchase_purchaseInfoWithRequestToken:]     0x1000fce2c
    buyParameters -> AMSBuyParams
    bagKey == "downloadProduct" or isDSIDLess -> purchaseType 2 (accountless)
    isUpdate -> purchaseType 4;  else purchaseType 0
    itemID nil -> falls back to buyParams[salableAdamId]

-[PreparePurchaseTask main]                               0x1002451cc
    IXAppInstallCoordinator lib_coordinatorForAppWithBundleID:...   <- bundleID mandatory
    account nil -> ams_activeiTunesAccount
    thinning headers, ad-networks

-[PerformPurchaseTask main]                               0x1001e708c
    purchaseType 2 -> "No account required for AMSPurchaseTypeDownloadProduct"
    no account + not discretionary -> interactive PromptForAccountTask
    no account + discretionary     -> ASDErrorDomain 530
    logs the final string: "[%{public}@] Purchasing with parameters: %{public}@"
    enqueues on AMSPurchaseQueue
```

That log line is `%{public}@`, so the exact working buyParameters for any real purchase can be read
off a device with the unified log.

## appstored → itunesstored → the store

```
-[PurchaseOperation urlBagKey]                            0x10001be28   defaults to "buyProduct"
-[PurchaseOperation _purchaseType]                         0x10002489c
    buyProduct 0 | backgroundUpdateProduct 1 | downloadProduct 2
    p2-in-app-buy 3 | updateProduct 4
    also: redownloadProduct, paidRedownloadProduct, redownloadAllTones

-[PurchaseOperation _newRequestParameters]                 0x100021bfc
    buyParameters --[NSURL copyDictionaryForQueryString:]--> dict
    adds guid, serialNumber, is-background, caller, playback,
         icloud-backup-enabled, creditDisplay, afds/afdsv2 (anti-fraud score)
    strips isUpdateAll

-[PurchaseOperation _addFairPlayToRequestProperties:]      0x10001e3b0
    param  kbsync = base64(keybag sync blob)
    param  sbsync = base64(FairPlay subscription bag, transactionType 312)
    header X-Apple-AMD-M = base64(machine-ID / OTP data)
    header X-Apple-AMD   = base64(AMD anti-abuse blob)

-[ISStoreURLOperation _resolvedURLInBagContext:bagTrusted:]  0x1ba7723bc
    url = requestProperties.URL
       ?: requestProperties.URLBagURLBlock(ctx)
       ?: [bag urlForKey:requestProperties.URLBagKey]
```

Live, that resolves to `https://p26-buy.itunes.apple.com/WebObjects/MZBuy.woa/wa/buyProduct?guid=…`,
matching the regex embedded in `StoreServices`:

```
https?://(p\d{1,3}-)?buy[.]itunes[.]apple[.]com/WebObjects/MZBuy.woa/wa/.*buyProduct.*
```

A rejected purchase still returns **HTTP 200** — the refusal is in the payload, not the status.

## Download and install

Downloads for App Store apps run through appstored's job system (`ASDJob`, `ASDJobAsset` with
`assetURL`, `sinfs`, `isZipStreamable`), not itunesstored's `SSDownloadQueue`.

installd validates via `libmis.dylib`:

```
MISValidateSignatureAndCopyInfo(CFStringRef path, CFDictionaryRef options, CFDictionaryRef *outInfo)
    call site 0x10005f4c0
    normal install: validateResources = 1, performOnlineAuthorization = 1
    failure -> MIInstallerErrorDomain, userInfo["LibMISErrorNumber"] = raw libmis code
```

Then `MIFileManager stageURLByMoving:…settingUID:gid:dataProtectionClass:` writes the bundle, the
SINF is written to `SC_Info/<App>.sinf`, and the app is registered with LaunchServices. The
delivered binary carries `LC_ENCRYPTION_INFO_64` with `cryptid = 1`.

## buyParameters

Nothing on the device validates it. `-[AMSBuyParams _parseBuyParams:]` (`0x1842ff01c`) builds an
`NSURLComponents`, sets the string as `percentEncodedQuery` and walks `queryItems` into a
dictionary. No schema, no required keys, no error path. Every constraint is server-side.

Four keys are enough in practice:

```
salableAdamId=<id>&productType=C&price=0&pricingParameters=STDQ
```

`pricingParameters` values present in this firmware: `STDQ` (standard purchase), `STDRDL` (standard
redownload), `GAME` / `GAMEPRE` (Arcade), `STDQPRE` (pre-order).

Key spellings, resolved from the `AMSBuyParamProperty*` constants appstored links:

| constant | string |
|---|---|
| `ItemId` | `salableAdamId` |
| `PricingParameters` | `pricingParameters` |
| `BundleId` | `bundleID` |
| `BundleVersion` | `bvrs` |
| `Dsid` / `OwnerDsid` | `dsid` / `ownerDsid` |
| `AffiliateId` | `caller` |
| `AppExtVrsId` | `appExtVrsId` |
| `ExternalVersionId` | `externalVersionId` |
| `ExistingExternalVersionId` | `existingExternalVersionId` |
| `HasBeenAuthedForBuy` | `hasBeenAuthedForBuy` |
| `InstalledSoftwareRating` | `installedSoftwareRating` |
| `IsBackground` | `is-background` |
| `RequestType` | `requestType` |
| `SerialNumber` | `serialNumber` |
| `SinfData` | `existingSinf` |
| `VendorID` | `vid` |
