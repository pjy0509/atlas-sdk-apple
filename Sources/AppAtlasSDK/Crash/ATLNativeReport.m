#import "ATLNativeReport.h"

#import "ATLCore.h"
#import "ATLCrashReport.h"

#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>

/// libc++abi's demangler, by name: an app that links no C++ must not have
/// to link it for us.
static char *(*ATLDemangle)(const char *, char *, size_t *, int *);

@implementation ATLNativeReport

+ (NSMutableDictionary<NSString *, id> *)readFile:(NSString *)path crashedAt:(NSTimeInterval *)at {
    NSData *bytes = [NSData dataWithContentsOfFile:path];

    if (bytes == nil || bytes.length == 0 || bytes.length > 4 * 1024 * 1024) {
        return nil;
    }

    // Lossy on purpose: a reason that carries a stray byte must not cost the
    // whole report.
    NSString *text = [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding]
        ?: [[NSString alloc] initWithData:bytes encoding:NSISOLatin1StringEncoding];

    if (text == nil) {
        return nil;
    }

    NSString *kind = nil;
    NSString *typeName = nil;
    NSString *cxxType = nil;
    NSString *message = nil;
    NSString *exceptionName = nil;
    NSString *reason = nil;
    NSMutableDictionary *native = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *crashInfo = [NSMutableArray array];
    NSMutableArray<NSMutableDictionary *> *threads = [NSMutableArray array];
    NSMutableDictionary *current = nil;
    NSString *registers = nil;
    NSTimeInterval crashedAt = [[NSDate date] timeIntervalSince1970];
    BOOL stackOverflow = NO;
    BOOL whole = NO;
    BOOL recrash = NO;

    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
        NSString *head = parts.firstObject;

        if ([head isEqualToString:@"time"] && parts.count >= 2) {
            crashedAt = parts[1].doubleValue > 0 ? parts[1].doubleValue : crashedAt;
        } else if ([head isEqualToString:@"kind"] && parts.count >= 2) {
            kind = parts[1];
        } else if ([head isEqualToString:@"mach"] && parts.count >= 5) {
            // mach <NAME> <type> <code> <fault>
            typeName = parts[1];
            native[@"exception"] = parts[1];
            native[@"code"] = [self machCodeName:parts[1] code:parts[3]];
            native[@"faultAddress"] = [@"0x" stringByAppendingString:parts[4]];
        } else if ([head isEqualToString:@"signal"] && parts.count >= 5) {
            // signal <NAME> <signo> <code> <fault>
            typeName = parts[1];
            native[@"signal"] = parts[1];
            native[@"code"] = parts[3];
            native[@"faultAddress"] = [@"0x" stringByAppendingString:parts[4]];
        } else if ([head isEqualToString:@"exception"]) {
            exceptionName = line.length > 10 ? [line substringFromIndex:10] : @"NSException";
        } else if ([head isEqualToString:@"reason"]) {
            reason = line.length > 7 ? [line substringFromIndex:7] : @"";
        } else if ([head isEqualToString:@"stackoverflow"]) {
            stackOverflow = YES;
        } else if ([head isEqualToString:@"cxxexception"] && parts.count >= 2) {
            cxxType = [self demangle:parts[1]];
        } else if ([head isEqualToString:@"crashinfo"] && line.length > 10) {
            [crashInfo addObject:[line substringFromIndex:10]];
        } else if ([head isEqualToString:@"thread"] && parts.count >= 4) {
            // thread <index> <id> <crashed> <name…>
            current = [NSMutableDictionary dictionary];
            current[@"name"] = parts.count >= 5 ? [[parts subarrayWithRange:NSMakeRange(4, parts.count - 4)] componentsJoinedByString:@" "] : @"thread";
            current[@"crashed"] = @([parts[3] isEqualToString:@"1"]);
            current[@"frames"] = [NSMutableArray array];
            [threads addObject:current];
        } else if ([head isEqualToString:@"registers"]) {
            registers = line.length > 10 ? [line substringFromIndex:10] : nil;
        } else if ([head isEqualToString:@"frame"] && parts.count >= 5 && current != nil) {
            [current[@"frames"] addObject:[self frameFromParts:parts]];
        } else if ([head isEqualToString:@"recrash"]) {
            recrash = YES;
        } else if ([head isEqualToString:@"end"]) {
            whole = YES;
        }
    }

    NSMutableDictionary *crashed = nil;

    for (NSMutableDictionary *thread in threads) {
        if ([thread[@"crashed"] boolValue]) {
            crashed = thread;
            break;
        }
    }

    if (!whole || kind == nil || crashed == nil) {
        return nil;
    }

    NSString *type;
    NSString *mechanism = [self mechanismOfKind:kind];

    if ([kind isEqualToString:@"exception"]) {
        type = exceptionName.length > 0 ? exceptionName : @"NSException";
        message = reason ?: @"";
    } else if (typeName != nil) {
        type = typeName;
        NSString *where = native[@"faultAddress"] ?: @"0x0";

        if (stackOverflow) {
            message = [NSString stringWithFormat:@"Stack overflow (%@ at %@)", typeName, where];
        } else if (native[@"exception"] != nil) {
            message = [NSString stringWithFormat:@"%@ (%@) at %@", typeName, native[@"code"], where];
        } else {
            message = [NSString stringWithFormat:@"Fatal signal %@ (code %@) at %@", typeName, native[@"code"], where];
        }

        // What the runtime said as it died (abort()'s reason, a Swift
        // fatalError, an uncaught-exception banner) beats an address.
        if (crashInfo.count > 0) {
            message = [NSString stringWithFormat:@"%@ (%@)", [crashInfo componentsJoinedByString:@" | "], message];
        }

        // A C++ exception nobody caught: its type is what groups it, not
        // the SIGABRT every one of them ends in.
        if (cxxType.length > 0) {
            type = cxxType;
            native[@"cxxException"] = cxxType;
        }
    } else {
        return nil;
    }

    if (stackOverflow) {
        native[@"stackOverflow"] = @YES;
    }
    if (recrash) {
        native[@"recrash"] = @YES;
    }

    // Names for the frames the server cannot resolve on its own: the
    // system's libraries, which carry their symbols and never a dSYM.
    [self nameFramesOf:threads];

    NSMutableDictionary *payload = [ATLCrashReport payloadWithEventId:[ATLCore newEventId]
                                                            crashedAt:[ATLCore iso:crashedAt]
                                                            sessionId:nil
                                                            mechanism:mechanism
                                                              handled:NO
                                                                 type:type
                                                              message:message
                                                               frames:crashed[@"frames"]];
    payload[@"mechanism"][@"native"] = native;
    payload[@"threads"] = threads;

    NSMutableDictionary *context = [NSMutableDictionary dictionary];

    if (registers != nil) {
        context[@"registers"] = registers.length > 1024 ? [registers substringToIndex:1024] : registers;
    }
    if (crashInfo.count > 0) {
        NSString *joined = [crashInfo componentsJoinedByString:@"\n"];
        context[@"crashInfo"] = joined.length > 1024 ? [joined substringToIndex:1024] : joined;
    }

    payload[@"context"] = context;

    if (at != NULL) {
        *at = crashedAt;
    }

    return payload;
}

+ (NSTimeInterval)peekCrashedAt:(NSString *)path {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];

    if (handle == nil) {
        return -1;
    }

    NSData *head = [handle readDataOfLength:128];
    [handle closeFile];
    NSString *text = [[NSString alloc] initWithData:head encoding:NSUTF8StringEncoding] ?: @"";

    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"time "]) {
            return [line substringFromIndex:5].doubleValue;
        }
    }

    return -1;
}

+ (NSString *)mechanismOfKind:(NSString *)kind {
    if ([kind isEqualToString:@"mach"]) return ATLMechanismMach;
    if ([kind isEqualToString:@"exception"]) return ATLMechanismUncaught;

    return ATLMechanismSignal;
}

// frame <pc> <relative|-> <uuid|-> <path|->
+ (NSDictionary *)frameFromParts:(NSArray<NSString *> *)parts {
    unsigned long long address = 0;
    unsigned long long relative = 0;
    [[NSScanner scannerWithString:parts[1]] scanHexLongLong:&address];

    BOOL located = ![parts[2] isEqualToString:@"-"];

    if (located) {
        [[NSScanner scannerWithString:parts[2]] scanHexLongLong:&relative];
    }

    NSString *path = [parts[4] isEqualToString:@"-"] ? nil
        : [[parts subarrayWithRange:NSMakeRange(4, parts.count - 4)] componentsJoinedByString:@" "];

    return [ATLCrashReport nativeFrameWithAddress:(uintptr_t) address
                                         relative:(uintptr_t) relative
                                             uuid:[parts[3] isEqualToString:@"-"] ? nil : parts[3]
                                             path:located ? path : nil
                                         function:nil];
}

// --- what the process can still tell about a report from a previous run ------------------

/// The frames of `threads`, named where the image is loaded again now with
/// the same UUID: the address is re-slid into this process and asked of
/// dladdr. Trusted without limit for the system's own libraries, whose
/// symbol tables are whole; for anything else only within a page of the
/// symbol, since a stripped app keeps only its exports and the nearest one
/// may be a different function entirely.
+ (void)nameFramesOf:(NSArray<NSMutableDictionary *> *)threads {
    NSDictionary<NSString *, NSNumber *> *loaded = [self loadedImages];

    for (NSMutableDictionary *thread in threads) {
        NSMutableArray *named = [NSMutableArray array];

        for (NSDictionary *frame in thread[@"frames"]) {
            [named addObject:[self nameFrame:frame loaded:loaded]];
        }

        thread[@"frames"] = named;
    }
}

+ (NSDictionary *)nameFrame:(NSDictionary *)frame loaded:(NSDictionary<NSString *, NSNumber *> *)loaded {
    NSString *uuid = frame[@"buildId"];
    NSString *path = frame[@"image"];
    NSNumber *load = uuid != nil ? loaded[uuid] : nil;

    if (load == nil || path == nil || ![frame[@"function"] hasPrefix:@"0x"]) {
        return frame;
    }

    unsigned long long relative = 0;
    [[NSScanner scannerWithString:frame[@"relativeAddr"] ?: @""] scanHexLongLong:&relative];

    Dl_info info;
    uintptr_t address = (uintptr_t) load.unsignedLongLongValue + (uintptr_t) relative;

    if (dladdr((const void *) address, &info) == 0 || info.dli_sname == NULL || info.dli_saddr == NULL) {
        return frame;
    }

    BOOL system = [path hasPrefix:@"/usr/lib/"] || [path hasPrefix:@"/System/"] || [path hasPrefix:@"/Developer/"]
        || [path hasPrefix:@"/private/preboot/"] || [path hasPrefix:@"/Library/Apple/"];
    uintptr_t distance = address - (uintptr_t) info.dli_saddr;

    if (strcmp(info.dli_sname, "_mh_execute_header") == 0 || (!system && distance > 4096)) {
        return frame;
    }

    NSMutableDictionary *named = [frame mutableCopy];
    NSString *symbol = [NSString stringWithUTF8String:info.dli_sname] ?: @"";
    named[@"function"] = [symbol hasPrefix:@"_Z"] ? [self demangle:symbol] : symbol;

    return named;
}

/// Every image loaded now, by UUID: what a report from a previous run can
/// still be resolved against, since the system's libraries and the app's
/// own binary are the same files at the same UUIDs, only slid.
+ (NSDictionary<NSString *, NSNumber *> *)loadedImages {
    NSMutableDictionary *images = [NSMutableDictionary dictionary];
    uint32_t count = _dyld_image_count();

    for (uint32_t i = 0; i < count; i++) {
        const struct mach_header *header = _dyld_get_image_header(i);

        if (header == NULL || header->magic != MH_MAGIC_64) {
            continue;
        }

        const uint8_t *cursor = (const uint8_t *) header + sizeof(struct mach_header_64);

        for (uint32_t c = 0; c < ((const struct mach_header_64 *) header)->ncmds; c++) {
            const struct load_command *command = (const struct load_command *) cursor;

            if (command->cmd == LC_UUID) {
                const uint8_t *uuid = ((const struct uuid_command *) command)->uuid;
                NSMutableString *hex = [NSMutableString stringWithCapacity:32];

                for (int b = 0; b < 16; b++) {
                    [hex appendFormat:@"%02x", uuid[b]];
                }

                images[hex] = @((unsigned long long) (uintptr_t) header);
                break;
            }

            cursor += command->cmdsize;
        }
    }

    return images;
}

/// A C++ mangled name (a symbol with its `_Z`, or a type_info name without)
/// back to source, when libc++abi is here to ask; the name itself otherwise.
+ (NSString *)demangle:(NSString *)name {
    if (name.length == 0) {
        return name;
    }

    if (ATLDemangle == NULL) {
        ATLDemangle = (char *(*)(const char *, char *, size_t *, int *)) dlsym(RTLD_DEFAULT, "__cxa_demangle");
    }

    if (ATLDemangle == NULL) {
        return name;
    }

    // A type_info name has no _Z prefix; the demangler wants one. Held in a
    // local, because a temporary's UTF8String dies with the temporary.
    NSString *mangled = [name hasPrefix:@"_Z"] ? name : [@"_Z" stringByAppendingString:name];
    int status = -1;
    char *readable = ATLDemangle(mangled.UTF8String, NULL, NULL, &status);
    NSString *result = status == 0 && readable != NULL ? [NSString stringWithUTF8String:readable] : name;

    if (readable != NULL) {
        free(readable);
    }

    return result;
}

+ (NSString *)machCodeName:(NSString *)exception code:(NSString *)code {
    NSInteger value = code.integerValue;

    if ([exception isEqualToString:@"EXC_BAD_ACCESS"]) {
        if (value == 1) return @"KERN_INVALID_ADDRESS";
        if (value == 2) return @"KERN_PROTECTION_FAILURE";
    } else if ([exception isEqualToString:@"EXC_BAD_INSTRUCTION"]) {
        if (value == 1) return @"EXC_ARM_UNDEFINED";
    } else if ([exception isEqualToString:@"EXC_BREAKPOINT"]) {
        if (value == 1) return @"EXC_ARM_BREAKPOINT";
    } else if ([exception isEqualToString:@"EXC_ARITHMETIC"]) {
        if (value == 1) return @"EXC_ARM_FP_UNDEFINED";
    } else if ([exception isEqualToString:@"EXC_GUARD"]) {
        // The guard type rides the top bits of the code: 1 a mach port, 2 a
        // file descriptor, 3 a user guard, 4 a vnode, 5 a virtual memory guard.
        switch ((value >> 61) & 0x7) {
            case 1: return @"GUARD_TYPE_MACH_PORT";
            case 2: return @"GUARD_TYPE_FD";
            case 3: return @"GUARD_TYPE_USER";
            case 4: return @"GUARD_TYPE_VN";
            case 5: return @"GUARD_TYPE_VIRT_MEMORY";
            default: break;
        }
    }

    return code;
}

@end
