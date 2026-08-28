// The handful of appstorectl.m helpers that other translation units need. Everything else in
// appstorectl.m stays static — this is the seam, not a general-purpose utility header.
#import <Foundation/Foundation.h>

#pragma mark - Output

// Set by -q. note() honours it; errors go to stderr regardless.
extern BOOL gQuiet;

void note(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

NSString *humanBytes(long long bytes);

#pragma mark - Installed bundle discovery

// Apps are located by scanning /var/containers/Bundle/Application/*/iTunesMetadata.plist for a
// matching softwareVersionBundleId. LSApplicationWorkspace would be tidier, but it costs a
// LaunchServices round trip and this runs as root with direct access to the containers anyway.

// The container directory, holding <App>.app and iTunesMetadata.plist as siblings.
NSString *installedContainerPath(NSString *bundleID);

// The .app inside a container, or nil if it holds no bundle yet.
NSString *bundleInContainer(NSString *container);

BOOL isFullyInstalled(NSString *appPath);
