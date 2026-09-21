#import "ATLRunState.h"

#import "ATLCore.h"
#import "ATLCrashFiles.h"

#include <TargetConditionals.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <sys/sysctl.h>
#include <sys/time.h>

#include "atl_crash_capture.h"

@implementation ATLRunState {
    NSString *_path;
    NSMutableDictionary<NSString *, id> *_state;
}

- (instancetype)initWithPath:(NSString *)path sessionId:(NSString *)sessionId startedAt:(NSTimeInterval)startedAt {
    self = [super init];

    if (self) {
        _path = [path copy];
        _previous = [self readPrevious];
        NSDate *modified = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL][NSFileModificationDate];
        _previousEndedAt = _previous != nil && modified != nil ? modified.timeIntervalSince1970 : 0;

        NSBundle *bundle = [NSBundle mainBundle];
        _state = [NSMutableDictionary dictionary];
        _state[@"sessionId"] = sessionId;
        _state[@"startedAt"] = @(startedAt);
        _state[@"appVersion"] = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
        _state[@"appBuild"] = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"";
        _state[@"osVersion"] = [NSProcessInfo processInfo].operatingSystemVersionString ?: @"";
        _state[@"executableUUID"] = [ATLRunState executableUUID];
        _state[@"bootTime"] = @([ATLRunState bootTime]);
        _state[@"debugger"] = @(atl_crash_debugger_attached() != 0);
        _state[@"simulator"] = @([ATLRunState isSimulator]);
        _state[@"extension"] = @([ATLRunState isExtension]);
        _state[@"prewarmed"] = @([ATLRunState isPrewarmed]);
        // Unknown until the app says so: a launch that dies before its first
        // DidBecomeActive is not called an OOM.
        _state[@"active"] = @NO;
        _state[@"foreground"] = @NO;
        _state[@"cleanExit"] = @NO;
        _state[@"hanging"] = @NO;
    }

    return self;
}

- (NSDictionary<NSString *, id> *)readPrevious {
    NSData *bytes = [NSData dataWithContentsOfFile:_path];

    if (bytes == nil || bytes.length > 1024 * 1024) {
        return nil;
    }

    id parsed = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:NULL];

    return [parsed isKindOfClass:[NSDictionary class]] ? parsed : nil;
}

- (NSString *)previousKillType {
    NSDictionary *last = _previous;

    if (last == nil) {
        return nil;
    }

    // Every one of these is a reason the death was not a foreground kill.
    if ([last[@"cleanExit"] boolValue]) return nil;
    if ([last[@"debugger"] boolValue] || [last[@"simulator"] boolValue] || [last[@"extension"] boolValue]) return nil;
    if (![last[@"active"] boolValue] || ![last[@"foreground"] boolValue]) return nil;
    if (![last[@"appVersion"] isEqual:_state[@"appVersion"]] || ![last[@"appBuild"] isEqual:_state[@"appBuild"]]) return nil;
    if (![last[@"executableUUID"] isEqual:_state[@"executableUUID"]]) return nil;
    if (![last[@"osVersion"] isEqual:_state[@"osVersion"]]) return nil;
    if (![last[@"bootTime"] isEqual:_state[@"bootTime"]]) return nil;

    return [last[@"hanging"] boolValue] ? @"WatchdogTermination" : @"OutOfMemory";
}

- (NSArray *)previousHangFrames {
    id frames = _previous[@"hangFrames"];

    return [frames isKindOfClass:[NSArray class]] ? frames : nil;
}

- (void)setActive:(BOOL)active {
    @synchronized (self) {
        _state[@"active"] = @(active);
    }
}

- (void)setForeground:(BOOL)foreground {
    @synchronized (self) {
        _state[@"foreground"] = @(foreground);
    }
}

- (void)setHanging:(BOOL)hanging frames:(NSArray *)frames {
    @synchronized (self) {
        _state[@"hanging"] = @(hanging);

        if (hanging && frames != nil) {
            _state[@"hangFrames"] = frames;
        }
    }
}

- (void)setMemoryPressure:(NSString *)level {
    @synchronized (self) {
        _state[@"memoryPressure"] = level;
    }
}

- (BOOL)isForeground {
    @synchronized (self) {
        return [_state[@"foreground"] boolValue];
    }
}

- (NSString *)previousMemoryPressure {
    id level = _previous[@"memoryPressure"];

    return [level isKindOfClass:[NSString class]] && ![level isEqualToString:@"normal"] ? level : nil;
}

- (void)noteCleanExit {
    @synchronized (self) {
        _state[@"cleanExit"] = @YES;
    }
}

- (void)persist {
    NSData *bytes;

    @synchronized (self) {
        _state[@"facts"] = [ATLRunState facts];
        bytes = [NSJSONSerialization dataWithJSONObject:_state options:0 error:NULL];
    }

    if (bytes != nil && [bytes writeToFile:_path atomically:YES]) {
        ATLCrashUnprotect(_path);
    }
}

// --- facts ------------------------------------------------------------------------------

+ (NSMutableDictionary<NSString *, id> *)facts {
    NSMutableDictionary *facts = [NSMutableDictionary dictionary];
    NSProcessInfo *process = [NSProcessInfo processInfo];

    facts[@"memoryTotalBytes"] = @(process.physicalMemory);

    // iOS 13+: what the app may still allocate before jetsam; probed by name
    // because the floor is 12.
    size_t (*available)(void) = (size_t (*)(void)) dlsym(RTLD_DEFAULT, "os_proc_available_memory");

    if (available != NULL) {
        facts[@"memoryAvailableBytes"] = @((unsigned long long) available());
    }

    vm_statistics64_data_t vm;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;

    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t) &vm, &count) == KERN_SUCCESS) {
        facts[@"memoryFreeBytes"] = @((unsigned long long) (vm.free_count + vm.inactive_count) * (unsigned long long) vm_kernel_page_size);
    }

    // What this process is really charged for, and how much more it may
    // take before jetsam: the two numbers an out-of-memory kill is read by.
    task_vm_info_data_t vm_info;
    mach_msg_type_number_t vm_count = TASK_VM_INFO_COUNT;

    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t) &vm_info, &vm_count) == KERN_SUCCESS) {
        if (vm_count >= TASK_VM_INFO_REV1_COUNT) {
            facts[@"memoryFootprintBytes"] = @((unsigned long long) vm_info.phys_footprint);
        }
#if defined(TASK_VM_INFO_REV4_COUNT)
        if (vm_count >= TASK_VM_INFO_REV4_COUNT && vm_info.limit_bytes_remaining > 0) {
            facts[@"memoryLimitRemainingBytes"] = @((unsigned long long) vm_info.limit_bytes_remaining);
        }
#endif
    }

    NSDictionary *volume = [[NSFileManager defaultManager] attributesOfFileSystemForPath:NSHomeDirectory() error:NULL];

    if (volume[NSFileSystemFreeSize] != nil) {
        facts[@"diskFreeBytes"] = volume[NSFileSystemFreeSize];
    }

    facts[@"bootTime"] = [ATLCore iso:[self bootTime]];
    facts[@"processUptimeMs"] = @((long long) ([[NSDate date] timeIntervalSince1970] * 1000.0 - [self processStartMs]));

    if (@available(iOS 9.0, macOS 12.0, *)) {
        facts[@"lowPowerMode"] = @(process.isLowPowerModeEnabled);
    }

    static NSString *const thermal[] = {@"nominal", @"fair", @"serious", @"critical"};
    NSInteger state = process.thermalState;
    facts[@"thermalState"] = state >= 0 && state < 4 ? thermal[state] : @"unknown";

    facts[@"jailbroken"] = @([self isJailbroken]);
    facts[@"simulator"] = @([self isSimulator]);
    facts[@"extension"] = @([self isExtension]);
    facts[@"prewarmed"] = @([self isPrewarmed]);
    facts[@"testFlight"] = @([self isTestFlight]);
    facts[@"debugger"] = @(atl_crash_debugger_attached() != 0);

    return facts;
}

+ (double)processStartMs {
    struct kinfo_proc info;
    size_t size = sizeof(info);
    int name[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    memset(&info, 0, sizeof(info));

    if (sysctl(name, 4, &info, &size, NULL, 0) != 0) {
        return 0;
    }

    return info.kp_proc.p_starttime.tv_sec * 1000.0 + info.kp_proc.p_starttime.tv_usec / 1000.0;
}

+ (NSTimeInterval)bootTime {
    struct timeval boot = {0, 0};
    size_t size = sizeof(boot);
    int name[2] = {CTL_KERN, KERN_BOOTTIME};

    if (sysctl(name, 2, &boot, &size, NULL, 0) != 0) {
        return 0;
    }

    return (NSTimeInterval) boot.tv_sec;
}

+ (BOOL)isSimulator {
#if TARGET_OS_SIMULATOR
    return YES;
#else
    return getenv("SIMULATOR_DEVICE_NAME") != NULL;
#endif
}

+ (BOOL)isExtension {
    NSBundle *bundle = [NSBundle mainBundle];

    return [bundle objectForInfoDictionaryKey:@"NSExtension"] != nil || [bundle.bundlePath hasSuffix:@".appex"];
}

+ (BOOL)isPreview {
    return getenv("XCODE_RUNNING_FOR_PREVIEWS") != NULL;
}

+ (BOOL)isTesting {
    return getenv("XCTestConfigurationFilePath") != NULL;
}

+ (BOOL)isPrewarmed {
    const char *flag = getenv("ActivePrewarm");

    return flag != NULL && strcmp(flag, "1") == 0;
}

+ (BOOL)isTestFlight {
    return [[NSBundle mainBundle].appStoreReceiptURL.lastPathComponent isEqualToString:@"sandboxReceipt"];
}

+ (BOOL)isJailbroken {
#if TARGET_OS_OSX || TARGET_OS_SIMULATOR
    return NO;
#else
    static const char *const marks[] = {
        "/Applications/Cydia.app", "/Applications/Sileo.app", "/Library/MobileSubstrate/MobileSubstrate.dylib",
        "/bin/bash", "/usr/sbin/sshd", "/etc/apt", "/private/var/lib/apt/", "/var/jb",
    };

    for (size_t i = 0; i < sizeof(marks) / sizeof(marks[0]); i++) {
        if (access(marks[i], F_OK) == 0) {
            return YES;
        }
    }

    // The sandbox forbids this write; a jailbreak that lifts it is a jailbreak.
    NSString *probe = @"/private/atlas-jb-probe";

    if ([@"" writeToFile:probe atomically:NO encoding:NSUTF8StringEncoding error:NULL]) {
        [[NSFileManager defaultManager] removeItemAtPath:probe error:NULL];

        return YES;
    }

    return NO;
#endif
}

+ (NSString *)executableUUID {
    // Image 0 is always the main executable.
    const struct mach_header *header = _dyld_get_image_header(0);

    if (header == NULL || header->magic != MH_MAGIC_64) {
        return @"";
    }

    const uint8_t *cursor = (const uint8_t *) header + sizeof(struct mach_header_64);

    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *command = (const struct load_command *) cursor;

        if (command->cmd == LC_UUID) {
            const uint8_t *uuid = ((const struct uuid_command *) command)->uuid;
            NSMutableString *hex = [NSMutableString stringWithCapacity:32];

            for (int b = 0; b < 16; b++) {
                [hex appendFormat:@"%02x", uuid[b]];
            }

            return hex;
        }

        cursor += command->cmdsize;
    }

    return @"";
}

@end
