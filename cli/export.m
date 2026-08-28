// export — package an installed App Store app back into an encrypted .ipa.
//
// A store .ipa is never written to disk: IXPromisedStreamingZipTransfer extracts the archive while
// it is still downloading (docs/PIPELINE.md), and /var/mobile/Media/Downloads holds only the queue
// database. There is no downloaded file to copy, so this reconstructs the package from the
// installed container instead.
//
// Layout produced, matching what the store ships:
//     Payload/<App>.app/          including SC_Info/ and _CodeSignature/
//     iTunesMetadata.plist
//
// Excluded deliberately: BundleMetadata.plist (an MIBundleMetadata keyed archive holding install
// date and install build) and .com.apple.mobile_container_manager.metadata.plist are device-local
// installd bookkeeping, not part of the archive.
//
// The result is a genuine FairPlay-encrypted ipa — cryptid stays 1, nothing here decrypts. It is
// not byte-identical to Apple's: zip ordering differs, the .sinf is this Apple ID's (installd
// rewrites it at install time) and the store already thinned the slice server-side.
#import <CommonCrypto/CommonDigest.h>
#import <Foundation/Foundation.h>
#import <fcntl.h>
#import <libkern/OSByteOrder.h>
#import <mach-o/fat.h>
#import <mach-o/loader.h>
#import <sys/wait.h>
#import <unistd.h>

#import "appstorectl.h"
#import "export.h"

#pragma mark - Bundle inspection

// CFBundleExecutable rather than the bundle name: the two differ often enough that guessing from
// the .app name picks a file that is not there.
static NSString *bundleExecutableName(NSString *appPath) {
    NSString *info = [appPath stringByAppendingPathComponent:@"Info.plist"];
    NSString *exe  = [NSDictionary dictionaryWithContentsOfFile:info][@"CFBundleExecutable"];
    return exe.length ? exe : appPath.lastPathComponent.stringByDeletingPathExtension;
}

typedef struct {
    BOOL     found;
    uint32_t cryptid;
    uint64_t cryptoff;
    uint64_t cryptsize;
} EncryptionInfo;

// Walk the load commands for LC_ENCRYPTION_INFO[_64]. Reported rather than enforced: an app that
// legitimately ships unencrypted has cryptid 0 and is still a valid export.
static EncryptionInfo machoEncryptionInfo(NSString *path) {
    EncryptionInfo out = (EncryptionInfo){0};
    int fd = open(path.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) return out;

    uint32_t magic = 0;
    if (pread(fd, &magic, sizeof magic, 0) != (ssize_t)sizeof magic) { close(fd); return out; }

    // Store binaries arrive thinned, but a universal build is still legal here.
    off_t slice = 0;
    if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
        struct fat_header fh;
        if (pread(fd, &fh, sizeof fh, 0) != (ssize_t)sizeof fh) { close(fd); return out; }
        uint32_t count = OSSwapBigToHostInt32(fh.nfat_arch);
        for (uint32_t i = 0; i < count && !slice; i++) {
            struct fat_arch fa;
            off_t at = (off_t)sizeof fh + (off_t)i * (off_t)sizeof fa;
            if (pread(fd, &fa, sizeof fa, at) != (ssize_t)sizeof fa) break;
            if (OSSwapBigToHostInt32(fa.cputype) == CPU_TYPE_ARM64) {
                slice = OSSwapBigToHostInt32(fa.offset);
            }
        }
        if (!slice) { close(fd); return out; }
    }

    struct mach_header_64 mh;
    if (pread(fd, &mh, sizeof mh, slice) != (ssize_t)sizeof mh) { close(fd); return out; }
    if (mh.magic != MH_MAGIC_64) { close(fd); return out; }

    uint8_t *cmds = malloc(mh.sizeofcmds);
    if (!cmds) { close(fd); return out; }
    if (pread(fd, cmds, mh.sizeofcmds, slice + (off_t)sizeof mh) != (ssize_t)mh.sizeofcmds) {
        free(cmds); close(fd); return out;
    }
    close(fd);

    uint32_t offset = 0;
    for (uint32_t i = 0; i < mh.ncmds && offset + sizeof(struct load_command) <= mh.sizeofcmds; i++) {
        struct load_command *lc = (struct load_command *)(cmds + offset);
        if (lc->cmdsize < sizeof(struct load_command)) break;
        if (offset + lc->cmdsize > mh.sizeofcmds) break;

        if (lc->cmd == LC_ENCRYPTION_INFO_64 &&
            lc->cmdsize >= sizeof(struct encryption_info_command_64)) {
            struct encryption_info_command_64 *e = (struct encryption_info_command_64 *)lc;
            out = (EncryptionInfo){ YES, e->cryptid, e->cryptoff, e->cryptsize };
            break;
        }
        if (lc->cmd == LC_ENCRYPTION_INFO &&
            lc->cmdsize >= sizeof(struct encryption_info_command)) {
            struct encryption_info_command *e = (struct encryption_info_command *)lc;
            out = (EncryptionInfo){ YES, e->cryptid, e->cryptoff, e->cryptsize };
            break;
        }
        offset += lc->cmdsize;
    }
    free(cmds);
    return out;
}

// SC_Info/Manifest.plist is installd's own record of where the FairPlay blobs belong, and checking
// against it is what catches a partial export that would otherwise look fine.
//
// Both keys matter, and SinfPaths alone is a trap. On Opera (5 extensions) SinfPaths lists only
// SC_Info/Opera.sinf while SinfReplicationPaths lists all six including every PlugIns/*.appex —
// so validating against SinfPaths would pass an archive missing every extension's sinf. On an app
// with no extensions the two keys are identical. Take the union and require all of it.
static NSArray<NSString *> *declaredSinfPaths(NSString *appPath) {
    NSString *manifestPath = [appPath stringByAppendingPathComponent:@"SC_Info/Manifest.plist"];
    NSDictionary *manifest = [NSDictionary dictionaryWithContentsOfFile:manifestPath];

    NSMutableSet<NSString *> *declared = [NSMutableSet set];
    for (NSString *key in @[@"SinfPaths", @"SinfReplicationPaths"]) {
        NSArray *paths = manifest[key];
        if (![paths isKindOfClass:NSArray.class]) continue;
        for (NSString *rel in paths) {
            if ([rel isKindOfClass:NSString.class]) [declared addObject:rel];
        }
    }
    return [declared.allObjects sortedArrayUsingSelector:@selector(compare:)];
}

static NSArray<NSString *> *appExtensionNames(NSString *appPath) {
    NSString *plugIns = [appPath stringByAppendingPathComponent:@"PlugIns"];
    NSMutableArray *found = [NSMutableArray array];
    for (NSString *e in [NSFileManager.defaultManager contentsOfDirectoryAtPath:plugIns error:NULL]) {
        if ([e hasSuffix:@".appex"]) [found addObject:e];
    }
    return found;
}

#pragma mark - Filesystem helpers

static long long directorySizeAt(NSString *path) {
    NSDirectoryEnumerator *e = [NSFileManager.defaultManager enumeratorAtPath:path];
    long long total = 0;
    for (NSString *entry in e) { (void)entry; total += (long long)e.fileAttributes.fileSize; }
    return total;
}

static long long freeBytesAt(NSString *path) {
    NSDictionary *a = [NSFileManager.defaultManager attributesOfFileSystemForPath:path error:NULL];
    return [a[NSFileSystemFreeSize] longLongValue];
}

static NSString *sha256OfFile(NSString *path) {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return nil;

    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    while (YES) {
        @autoreleasepool {
            NSData *chunk = [fh readDataOfLength:1 << 20];
            if (!chunk.length) break;
            CC_SHA256_Update(&ctx, chunk.bytes, (CC_LONG)chunk.length);
        }
    }
    [fh closeFile];

    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

// zip stores paths relative to its working directory, so it has to run inside the staging dir for
// the archive to come out rooted at Payload/ rather than /var/jb/tmp/...
//
// posix_spawn_file_actions_addchdir_np is marked unavailable on iOS, and chdir() in the parent is
// process-global — it would corrupt any relative path another thread touched. So fork, chdir in the
// child, exec. Only async-signal-safe calls happen between fork and execv.
//
// -y matters: without it zip follows symlinks inside the bundle and silently inflates the archive
// with duplicated frameworks. -X drops uid/gid extras that are only device-local noise. No shell is
// involved, so nothing here can be word-split, matching how cmdUninstall spawns ipainstaller.
static int runZip(NSString *workDir, NSString *outPath) {
    const char *tool = "/var/jb/usr/bin/zip";
    const char *dir  = workDir.fileSystemRepresentation;
    const char *out  = outPath.fileSystemRepresentation;

    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        if (chdir(dir) != 0) _exit(127);
        char *const args[] = {
            (char *)"zip", (char *)"-qryX", (char *)out,
            (char *)"Payload", (char *)"iTunesMetadata.plist", NULL
        };
        execv(tool, args);
        _exit(127);
    }

    int status = 0;
    waitpid(pid, &status, 0);
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

#pragma mark - Command

// Every interesting failure here is silent — an ODR app packages "successfully" while missing half
// its resources — so the run prints what it actually found rather than only what it wrote.
int cmdExport(NSString *bundleID, NSString *outPath) {
    NSFileManager *fm = NSFileManager.defaultManager;

    NSString *container = installedContainerPath(bundleID);
    NSString *appPath   = bundleInContainer(container);
    if (!appPath) {
        fprintf(stderr, "%s is not installed\n", bundleID.UTF8String);
        return 66;
    }
    if (!isFullyInstalled(appPath)) {
        fprintf(stderr, "%s has no sinf yet — the install is still in progress\n",
                bundleID.UTF8String);
        return 65;
    }

    NSDictionary *md = [NSDictionary dictionaryWithContentsOfFile:
                        [container stringByAppendingPathComponent:@"iTunesMetadata.plist"]];

    note(@"[+] container   %@", container);
    long long appBytes = directorySizeAt(appPath);
    note(@"[+] bundle      %@   %@", appPath.lastPathComponent, humanBytes(appBytes));

    // Staging copies the bundle before zipping it, so peak usage is the tree plus the archive.
    NSString *work   = @"/var/jb/tmp/appstorectl-export";
    long long needed = appBytes * 2;
    long long avail  = freeBytesAt(@"/var/jb/tmp");
    if (avail > 0 && avail < needed) {
        fprintf(stderr, "not enough space: need ~%s, have %s\n",
                humanBytes(needed).UTF8String, humanBytes(avail).UTF8String);
        return 1;
    }

    NSArray *declared = declaredSinfPaths(appPath);
    NSMutableArray *missing = [NSMutableArray array];
    for (NSString *rel in declared) {
        if (![fm fileExistsAtPath:[appPath stringByAppendingPathComponent:rel]]) {
            [missing addObject:rel];
        }
    }
    note(@"[%@] sinf        %lu of %lu present",
         missing.count ? @"!" : @"+",
         (unsigned long)(declared.count - missing.count), (unsigned long)declared.count);
    for (NSString *rel in missing) note(@"[!] sinf        MISSING %@", rel);

    NSString *executable = [appPath stringByAppendingPathComponent:bundleExecutableName(appPath)];
    EncryptionInfo enc = machoEncryptionInfo(executable);
    if (!enc.found) {
        note(@"[!] encryption  no LC_ENCRYPTION_INFO in %@", executable.lastPathComponent);
    } else {
        note(@"[+] encryption  cryptid %u  (off %llu, size %llu)",
             enc.cryptid, enc.cryptoff, enc.cryptsize);
        if (enc.cryptid == 0) note(@"[!] encryption  cryptid 0 — this binary ships unencrypted");
    }

    NSArray *appex = appExtensionNames(appPath);
    note(@"[%@] plugins     %@", appex.count ? @"+" : @"!",
         appex.count ? [appex componentsJoinedByString:@", "] : @"none");

    // ODR asset packs are fetched separately and never live in the bundle, so an app that uses them
    // exports incomplete and the archive alone gives no hint. Warn; there is nothing to fix here.
    if ([fm fileExistsAtPath:[appPath stringByAppendingPathComponent:@"OnDemandResources.plist"]]) {
        note(@"[!] ODR         app uses On-Demand Resources — asset packs are NOT in this export");
    }

    [fm removeItemAtPath:work error:NULL];
    NSString *payload = [work stringByAppendingPathComponent:@"Payload"];
    NSError *err = nil;
    if (![fm createDirectoryAtPath:payload
       withIntermediateDirectories:YES attributes:nil error:&err]) {
        fprintf(stderr, "could not create staging dir: %s\n",
                err.localizedDescription.UTF8String);
        return 1;
    }
    if (![fm copyItemAtPath:appPath
                     toPath:[payload stringByAppendingPathComponent:appPath.lastPathComponent]
                      error:&err]) {
        fprintf(stderr, "staging copy failed: %s\n", err.localizedDescription.UTF8String);
        [fm removeItemAtPath:work error:NULL];
        return 1;
    }
    [fm copyItemAtPath:[container stringByAppendingPathComponent:@"iTunesMetadata.plist"]
                toPath:[work stringByAppendingPathComponent:@"iTunesMetadata.plist"]
                 error:NULL];

    // externalVersionId is in the name because one shortVersion can ship as several builds, and for
    // archival that is exactly the distinction worth keeping.
    if (!outPath.length) {
        NSString *safeID  = [bundleID stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
        NSString *version = md[@"bundleShortVersionString"] ?: @"unknown";
        id externalID     = md[@"softwareVersionExternalIdentifier"] ?: @"0";
        NSString *dir     = @"/var/jb/tmp/appstorectl-exports";
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        outPath = [dir stringByAppendingPathComponent:
                   [NSString stringWithFormat:@"%@_%@_%@.ipa", safeID, version, externalID]];
    }
    [fm removeItemAtPath:outPath error:NULL];

    int rc = runZip(work, outPath);
    [fm removeItemAtPath:work error:NULL];
    if (rc != 0) {
        fprintf(stderr, "zip failed (exit %d)\n", rc);
        return 1;
    }

    long long size = (long long)[fm attributesOfItemAtPath:outPath error:NULL].fileSize;
    if (size <= 0) {
        fprintf(stderr, "export produced no archive\n");
        return 1;
    }

    note(@"[+] wrote       %@   %@", outPath, humanBytes(size));
    note(@"[+] sha256      %@", sha256OfFile(outPath) ?: @"(unavailable)");

    if (missing.count) {
        fprintf(stderr, "warning: %lu declared sinf path(s) missing — export is incomplete\n",
                (unsigned long)missing.count);
        return 1;
    }
    return 0;
}
