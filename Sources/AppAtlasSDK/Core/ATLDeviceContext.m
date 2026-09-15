#import "ATLDeviceContext.h"

#import <sys/sysctl.h>

@implementation ATLDeviceContext

+ (NSDictionary<NSString *, id> *)snapshot {
    NSOperatingSystemVersion version = [NSProcessInfo processInfo].operatingSystemVersion;

    // The common keys come first, in the order every SDK writes them.
    NSMutableDictionary *device = [NSMutableDictionary dictionary];
    device[@"os"] = [ATLDeviceContext os];
    device[@"osVersion"] = [NSString stringWithFormat:@"%ld.%ld.%ld",
                            (long) version.majorVersion, (long) version.minorVersion, (long) version.patchVersion];
    device[@"model"] = [ATLDeviceContext machineModel];
    device[@"arch"] = [ATLDeviceContext arch];
    device[@"locale"] = [NSLocale currentLocale].localeIdentifier ?: @"";
    device[@"timezone"] = [NSTimeZone localTimeZone].name ?: @"";

    NSBundle *bundle = [NSBundle mainBundle];
    NSMutableDictionary *app = [NSMutableDictionary dictionary];
    NSString *shortVersion = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    NSString *build = [bundle objectForInfoDictionaryKey:(NSString *) kCFBundleVersionKey];

    if (shortVersion != nil) app[@"version"] = shortVersion;
    if (build != nil) app[@"build"] = build;

    return @{@"device": device, @"app": app};
}

/// One binary serves both families; the OS it reports is the one it runs on.
+ (NSString *)os {
#if TARGET_OS_OSX
    return @"macos";
#else
    return @"ios";
#endif
}

/// The slice this binary was built for; the model above names the machine.
+ (NSString *)arch {
#if defined(__arm64__)
    return @"arm64";
#elif defined(__x86_64__)
    return @"x86_64";
#elif defined(__arm__)
    return @"arm";
#else
    return @"unknown";
#endif
}

/// "iPhone16,2" and the like: what crash symbolication and device breakdowns
/// key on. Simulators answer x86_64/arm64 — truthful, so kept.
+ (NSString *)machineModel {
    char buffer[64] = {0};
    size_t size = sizeof(buffer) - 1;

    if (sysctlbyname("hw.machine", buffer, &size, NULL, 0) != 0) {
        return @"unknown";
    }

    return [NSString stringWithUTF8String:buffer] ?: @"unknown";
}

@end
