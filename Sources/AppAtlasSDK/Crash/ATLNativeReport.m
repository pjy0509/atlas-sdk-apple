#import "ATLNativeReport.h"

#import "ATLCore.h"
#import "ATLCrashReport.h"

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

        // What the runtime said as it died — abort()'s reason, a Swift
        // fatalError, an uncaught-exception banner — beats an address.
        if (crashInfo.count > 0) {
            message = [NSString stringWithFormat:@"%@ — %@", [crashInfo componentsJoinedByString:@" | "], message];
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
    }

    return code;
}

@end
