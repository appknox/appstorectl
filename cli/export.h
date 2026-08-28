// Reconstruct an IPA from an installed App Store app, optionally decrypting the staged images.
#import <Foundation/Foundation.h>

// outPath may be nil, in which case the archive lands in /var/jb/tmp/appstorectl-exports/ named
// <bundleID>_<version>_<externalVersionId>.ipa, or ..._decrypted.ipa when decrypt is YES.
//
// decrypt runs appstorectl-decrypt over the staged copy before packaging, turning cryptid 1
// images into cryptid 0. It launches the app to do it, and it is verified rather than trusted:
// the staged executable is re-read afterwards and the export fails if cryptid did not clear.
//
// Returns 0 on success, 65 if the install is still in flight, 66 if the app is not installed,
// 1 on any packaging failure, a failed decryption, or an incomplete export.
int cmdExport(NSString *bundleID, NSString *outPath, BOOL decrypt);
