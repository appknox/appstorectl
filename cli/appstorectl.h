// The handful of appstorectl.m helpers that other translation units need. Everything else in
// appstorectl.m stays static — this is the seam, not a general-purpose utility header.
#import <Foundation/Foundation.h>

#import "log.h"

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
