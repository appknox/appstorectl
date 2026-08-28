// Package an installed App Store app back into an encrypted .ipa. See export.m for why this
// reconstructs rather than copies.
#import <Foundation/Foundation.h>

// outPath may be nil, in which case the archive lands in /var/jb/tmp/appstorectl-exports/ named
// <bundleID>_<version>_<externalVersionId>.ipa.
//
// Returns 0 on success, 65 if the install is still in flight, 66 if the app is not installed,
// 1 on any packaging failure or an incomplete export.
int cmdExport(NSString *bundleID, NSString *outPath);
