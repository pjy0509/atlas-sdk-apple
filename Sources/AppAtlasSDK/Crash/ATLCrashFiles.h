#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The crash state lives behind the lock screen too: a crash while the
/// device is locked must still be able to open its own files. Every path the
/// module writes is dropped to NSFileProtectionNone, by name, so the same
/// source builds for a macOS floor that predates the constants.
static inline void ATLCrashUnprotect(NSString *path) {
    [[NSFileManager defaultManager] setAttributes:@{@"NSFileProtectionKey": @"NSFileProtectionNone"}
                                     ofItemAtPath:path error:NULL];
}

static inline void ATLCrashEnsureDirectory(NSString *directory) {
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES
                                               attributes:@{@"NSFileProtectionKey": @"NSFileProtectionNone"}
                                                    error:NULL];
}

NS_ASSUME_NONNULL_END
