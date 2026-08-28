// export — reconstruct an IPA from an installed App Store app.
//
// No complete IPA was found on disk in the observed install path. IXPromisedStreamingZipTransfer
// extracts while downloading, and /var/mobile/Media/Downloads held only the queue database, so
// export reconstructs from the installed application container.
//
// Layout produced, matching what the store ships:
//     Payload/<App>.app/          including SC_Info/ and _CodeSignature/
//     iTunesMetadata.plist
//
// Excluded deliberately: BundleMetadata.plist (an MIBundleMetadata keyed archive holding install
// date and install build) and .com.apple.mobile_container_manager.metadata.plist are device-local
// installd bookkeeping, not part of the archive.
//
// With decrypt:YES the staged copy is run through appstorectl-decrypt and encrypted images come out
// at cryptid 0. With decrypt:NO they retain the installed FairPlay payload at cryptid 1. The
// installed bundle is never touched either way. The result is not byte-identical to Apple's: zip
// ordering differs, the .sinf is this Apple ID's (installd rewrites it at install time), and the
// store already thinned the slice server-side.
#import <CommonCrypto/CommonDigest.h>
#import <Foundation/Foundation.h>
#import <errno.h>
#import <fcntl.h>
#import <string.h>
#import <libkern/OSByteOrder.h>
#import <mach-o/fat.h>
#import <mach-o/loader.h>
#import <sys/wait.h>
#import <unistd.h>

#import "appstorectl.h"
#import "log.h"
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

// Every Mach-O under `root` carrying LC_ENCRYPTION_INFO, keyed by bundle-relative path.
//
// A bundle holds far more than the main executable: appex binaries, embedded frameworks and loose
// dylibs each have their own encryption command and their own cryptid. Reporting only the main one
// is how a partial decryption passes for a complete one, so enumerate the lot and let the caller
// print a before/after for each.
//
// Cost is one open plus a 4-byte read per regular file, because machoEncryptionInfo rejects on
// magic before it allocates anything. That is cheap enough to run over a 286 MB bundle twice.
static NSDictionary<NSString *, NSNumber *> *encryptedImages(NSString *root) {
    NSMutableDictionary<NSString *, NSNumber *> *out = [NSMutableDictionary dictionary];
    NSDirectoryEnumerator *e = [NSFileManager.defaultManager enumeratorAtPath:root];
    for (NSString *rel in e) {
        @autoreleasepool {
            if (![e.fileAttributes.fileType isEqualToString:NSFileTypeRegular]) continue;
            EncryptionInfo i = machoEncryptionInfo([root stringByAppendingPathComponent:rel]);
            if (i.found) out[rel] = @(i.cryptid);
        }
    }
    return out;
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
// Spawn appstorectl-decrypt over the staged copy. Its `into` mode decrypts in place and does not
// package, so everything below this point (metadata, sinf validation, naming, sha256) is
// unchanged from the encrypted path.
//
// It is a separate binary because it needs task_for_pid-allow, com.apple.private.cs.debugger and
// no-sandbox, which this tool has no reason to carry. Same fork/exec shape as runZip: no shell,
// so nothing here can be word-split.
//
// Decryption works by running the app, so expect the target to launch on the device and expect
// this to take appreciably longer than a plain export.
// Pulls key="value" out of one @evt record. Returns nil when the key is absent, which is the
// normal case for most records.
static NSString *evtAttr(NSString *line, NSString *key) {
    NSString *needle = [key stringByAppendingString:@"=\""];
    NSRange k = [line rangeOfString:needle];
    if (k.location == NSNotFound) return nil;
    NSUInteger start = k.location + k.length;
    NSRange close = [line rangeOfString:@"\"" options:0
                                  range:NSMakeRange(start, line.length - start)];
    if (close.location == NSNotFound) return nil;
    return [line substringWithRange:NSMakeRange(start, close.location - start)];
}

// Records why an image never launched, so a failure can be reported with its cause instead of just
// "still encrypted". Deliberately NOT a claim that the image is undecryptable: an earlier version
// treated a declared minimum OS above this device as permanent and was wrong about it.
static void noteLaunchFailure(NSString *line,
                              NSMutableDictionary<NSString *, NSString *> *out) {
    if (!out || ![line containsString:@"event=target.failed"]) return;
    NSString *main = evtAttr(line, @"main");
    if (!main.length) return;
    NSString *minOS = evtAttr(line, @"min_os");
    out[main] = minOS.length
        ? [NSString stringWithFormat:@"did not launch (declares iOS %@)", minOS]
        : @"did not launch";
}

static int runDecrypt(NSString *bundleID, NSString *srcApp, NSString *dstApp,
                      NSMutableDictionary<NSString *, NSString *> *launchFailures) {
    const char *tool = "/var/jb/usr/bin/appstorectl-decrypt";
    if (![NSFileManager.defaultManager isExecutableFileAtPath:@(tool)]) {
        warnf(@"appstorectl-decrypt is not installed at %s", tool);
        return -1;
    }

    const char *bid = bundleID.UTF8String;
    const char *src = srcApp.fileSystemRepresentation;
    const char *dst = dstApp.fileSystemRepresentation;

    // The exact argv, because reproducing a decrypt by hand later is the first thing anyone tries
    // and reconstructing it from prose never quite matches.
    logLine(@"exec %s into %@ %@ %@", tool, bundleID, srcApp, dstApp);

    // Capture the helper's output rather than letting it inherit our terminal.
    //
    // It writes structured `@evt event=... level=... msg="..."` records, which are genuinely useful
    // but do not look anything like the rest of this tool's output, so they turned an export into a
    // wall of two different formats. They go to the log verbatim instead; the per-image before/after
    // table this function prints afterwards is the part a human wants.
    int fds[2];
    if (pipe(fds) != 0) { warnf(@"pipe failed: %s", strerror(errno)); return -1; }

    pid_t pid = fork();
    if (pid < 0) {
        close(fds[0]); close(fds[1]);
        logLine(@"fork failed: %s", strerror(errno));
        return -1;
    }
    if (pid == 0) {
        close(fds[0]);
        dup2(fds[1], STDOUT_FILENO);
        dup2(fds[1], STDERR_FILENO);
        close(fds[1]);
        // -v unconditionally: the helper's output never reaches the terminal, only the log, and the
        // log is the thing that has to explain a failed image months later. Its debug records are
        // suppressed without this, which hid the image inventory entirely.
        char *const args[] = {
            (char *)"appstorectl-decrypt", (char *)"-v", (char *)"into",
            (char *)bid, (char *)src, (char *)dst, NULL
        };
        execv(tool, args);
        _exit(127);
    }

    // Drain before waitpid: the helper emits more than a pipe buffer holds on a bundle with several
    // images, and waiting first would deadlock it on a full pipe.
    close(fds[1]);
    NSMutableData *pending = [NSMutableData data];
    char buf[4096];
    ssize_t n;
    while ((n = read(fds[0], buf, sizeof buf)) > 0) {
        [pending appendBytes:buf length:(NSUInteger)n];
        for (;;) {
            NSRange nl = [pending rangeOfData:[NSData dataWithBytes:"\n" length:1]
                                      options:0 range:NSMakeRange(0, pending.length)];
            if (nl.location == NSNotFound) break;
            NSString *line = [[NSString alloc] initWithData:[pending subdataWithRange:
                                NSMakeRange(0, nl.location)] encoding:NSUTF8StringEncoding];
            if (line.length) {
                logLine(@"decrypt| %@", line);
                noteLaunchFailure(line, launchFailures);
            }
            [pending replaceBytesInRange:NSMakeRange(0, nl.location + 1) withBytes:NULL length:0];
        }
    }
    if (pending.length) {   // last line without a trailing newline
        NSString *line = [[NSString alloc] initWithData:pending encoding:NSUTF8StringEncoding];
        if (line.length) {
            logLine(@"decrypt| %@", line);
            noteLaunchFailure(line, launchFailures);
        }
    }
    close(fds[0]);

    int status = 0;
    waitpid(pid, &status, 0);

    // Distinguish the three outcomes. A signalled helper looks identical to a nonzero exit at the
    // call site, and 127 specifically means execv never ran.
    if (WIFSIGNALED(status)) {
        logLine(@"appstorectl-decrypt killed by signal %d", WTERMSIG(status));
        return -1;
    }
    int rc = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    logLine(@"appstorectl-decrypt pid %d exited %d%s", pid, rc,
            rc == 127 ? "  (execv failed)" : "");
    return rc;
}

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
int cmdExport(NSString *bundleID, NSString *outPath, BOOL decrypt) {
    NSFileManager *fm = NSFileManager.defaultManager;

    logLine(@"export: begin bundle=%@ decrypt=%d out=%@", bundleID, decrypt, outPath ?: @"(default)");

    NSString *container = installedContainerPath(bundleID);
    NSString *appPath   = bundleInContainer(container);
    logLine(@"export: container=%@ app=%@", container ?: @"(none)", appPath ?: @"(none)");
    if (!appPath) {
        warnf(@"%@ is not installed", bundleID);
        return 66;
    }
    if (!isFullyInstalled(appPath)) {
        warnf(@"%@ has no sinf yet — the install is still in progress", bundleID);
        return 65;
    }

    NSDictionary *md = [NSDictionary dictionaryWithContentsOfFile:
                        [container stringByAppendingPathComponent:@"iTunesMetadata.plist"]];
    logLine(@"export: metadata version=%@ externalVersionId=%@ bundleId=%@",
            md[@"bundleShortVersionString"] ?: @"(none)",
            md[@"softwareVersionExternalIdentifier"] ?: @"(none)",
            md[@"softwareVersionBundleId"] ?: @"(none)");

    note(@"[+] container   %@", container);
    long long appBytes = directorySizeAt(appPath);
    note(@"[+] bundle      %@   %@", appPath.lastPathComponent, humanBytes(appBytes));

    // Staging copies the bundle before zipping it, so peak usage is the tree plus the archive.
    NSString *work   = @"/var/jb/tmp/appstorectl-export";
    long long needed = appBytes * 2;
    long long avail  = freeBytesAt(@"/var/jb/tmp");
    logLine(@"export: bundleBytes=%lld need=%lld availOnTmp=%lld", appBytes, needed, avail);
    if (avail > 0 && avail < needed) {
        warnf(@"not enough space: need ~%@, have %@", humanBytes(needed), humanBytes(avail));
        return 1;
    }

    NSArray *declared = declaredSinfPaths(appPath);
    // The manifest's own list, verbatim. The terminal only ever reports a count and the misses.
    logLine(@"export: manifest declares %lu sinf path(s): %@",
            (unsigned long)declared.count,
            declared.count ? [declared componentsJoinedByString:@", "] : @"(none)");
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
        warnf(@"could not create staging dir: %@", err.localizedDescription);
        return 1;
    }
    logLine(@"export: staging to %@", payload);
    if (![fm copyItemAtPath:appPath
                     toPath:[payload stringByAppendingPathComponent:appPath.lastPathComponent]
                      error:&err]) {
        warnf(@"staging copy failed: %@", err.localizedDescription);
        [fm removeItemAtPath:work error:NULL];
        return 1;
    }
    logLine(@"export: staging copy done");
    [fm copyItemAtPath:[container stringByAppendingPathComponent:@"iTunesMetadata.plist"]
                toPath:[work stringByAppendingPathComponent:@"iTunesMetadata.plist"]
                 error:NULL];

    // Decrypt the staged copy in place, before packaging. The installed bundle is never touched.
    if (decrypt) {
        NSString *stagedApp = [payload stringByAppendingPathComponent:appPath.lastPathComponent];
        // Says "this will pause" on purpose: the helper's own progress now goes to the log, so a
        // bundle with several extensions sits silent here for a minute or so.
        note(@"[+] decrypt     launching %@ to dump plaintext images (this takes a moment)",
             bundleID);

        NSMutableDictionary<NSString *, NSString *> *launchFailures = [NSMutableDictionary dictionary];
        int drc = runDecrypt(bundleID, appPath, stagedApp, launchFailures);
        if (drc != 0) {
            warnf(@"decryption failed (exit %d)", drc);
            [fm removeItemAtPath:work error:NULL];
            return 1;
        }

        // Verify rather than trust, and report every image rather than just the main executable.
        // The helper exits 0 on a partial run, and "0 framework(s) decrypted" is ambiguous on its
        // own: it means the same thing whether they were never encrypted, were skipped, or were
        // missed. Comparing the source bundle against the staged copy answers that per image.
        NSDictionary<NSString *, NSNumber *> *before = encryptedImages(appPath);
        NSDictionary<NSString *, NSNumber *> *after  = encryptedImages(stagedApp);

        NSMutableArray<NSString *> *wasEncrypted = [NSMutableArray array];
        NSUInteger shippedPlain = 0;
        for (NSString *rel in before) {
            if (before[rel].unsignedIntValue != 0) [wasEncrypted addObject:rel];
            else shippedPlain++;
        }
        [wasEncrypted sortUsingSelector:@selector(compare:)];

        NSMutableArray<NSString *> *stillEncrypted = [NSMutableArray array];
        // Full paths, untruncated, in both the debug log and terminal result.
        logLine(@"images: %lu encrypted, %lu shipped plain",
                (unsigned long)wasEncrypted.count, (unsigned long)shippedPlain);
        for (NSString *rel in before)
            logLine(@"  image %@ cryptid %@ -> %@", rel, before[rel], after[rel] ?: @"(absent)");

        note(@"[+] decrypt     %lu encrypted image(s)", (unsigned long)wasEncrypted.count);
        for (NSString *rel in wasEncrypted) {
            NSNumber *now = after[rel];
            // A missing entry means the staged file lost its encryption command entirely, which is
            // not something decryption does. Treat it as unresolved rather than as success.
            unsigned nowID = now ? now.unsignedIntValue : 1;
            BOOL ok = (now != nil && nowID == 0);
            if (!ok) [stillEncrypted addObject:rel];
            // Why it failed, when the helper knew. Never a claim that it cannot be decrypted at
            // all: spawn failures here are usually transient, and the helper already retries.
            NSString *why = ok ? nil : launchFailures[rel.lastPathComponent];
            if (why)
                note(@"      [!] %@ %u -> %u  (%@)", rel,
                     before[rel].unsignedIntValue, nowID, why);
            else
                note(@"      %@ %@ %u -> %u", ok ? @"[+]" : @"[!]", rel,
                     before[rel].unsignedIntValue, nowID);
        }
        if (shippedPlain) {
            note(@"[=] decrypt     %lu image(s) shipped unencrypted, left alone",
                 (unsigned long)shippedPlain);
        }

        if (stillEncrypted.count) {
            warnf(@"decryption reported success but %lu image(s) are still encrypted: %@",
                  (unsigned long)stillEncrypted.count,
                  [stillEncrypted componentsJoinedByString:@", "]);
            [fm removeItemAtPath:work error:NULL];
            return 1;
        }
    }

    // externalVersionId is in the name because one shortVersion can ship as several builds, and for
    // archival that is exactly the distinction worth keeping.
    if (!outPath.length) {
        NSString *safeID  = [bundleID stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
        NSString *version = md[@"bundleShortVersionString"] ?: @"unknown";
        id externalID     = md[@"softwareVersionExternalIdentifier"] ?: @"0";
        NSString *dir     = @"/var/jb/tmp/appstorectl-exports";
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        // The suffix is not cosmetic: an encrypted and a decrypted export of the same build are
        // otherwise the same filename, and telling them apart afterwards means re-reading cryptid
        // out of the archive.
        outPath = [dir stringByAppendingPathComponent:
                   [NSString stringWithFormat:@"%@_%@_%@%@.ipa", safeID, version, externalID,
                    decrypt ? @"_decrypted" : @""]];
    }
    [fm removeItemAtPath:outPath error:NULL];

    logLine(@"export: zip %@ -> %@", work, outPath);
    int rc = runZip(work, outPath);
    [fm removeItemAtPath:work error:NULL];
    if (rc != 0) {
        // 127 means execv never ran, i.e. /var/jb/usr/bin/zip is missing, which is a different
        // problem from zip itself refusing.
        warnf(@"zip failed (exit %d)%s", rc, rc == 127 ? "  — is /var/jb/usr/bin/zip installed?" : "");
        return 1;
    }

    long long size = (long long)[fm attributesOfItemAtPath:outPath error:NULL].fileSize;
    if (size <= 0) {
        warnf(@"export produced no archive");
        return 1;
    }

    note(@"[+] wrote       %@   %@", outPath, humanBytes(size));
    note(@"[+] sha256      %@", sha256OfFile(outPath) ?: @"(unavailable)");
    logLine(@"export: done bytes=%lld path=%@", size, outPath);

    if (missing.count) {
        warnf(@"warning: %lu declared sinf path(s) missing — export is incomplete",
              (unsigned long)missing.count);
        return 1;
    }
    return 0;
}
