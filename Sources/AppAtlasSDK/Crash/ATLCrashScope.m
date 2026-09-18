#import "ATLCrashScope.h"

#import "ATLCore.h"
#import "ATLCrashFiles.h"

static const NSUInteger ATLScopeMaxKeys = 64;
static const NSUInteger ATLScopeMaxValueChars = 1024;
static const NSUInteger ATLScopeMaxBreadcrumbs = 100;
static const NSUInteger ATLScopeMaxLogChars = 64 * 1024;

static NSString *ATLClip(NSString *text, NSUInteger limit) {
    return text.length > limit ? [text substringToIndex:limit] : text;
}

@implementation ATLCrashScope {
    NSString *_userId;
    NSMutableDictionary<NSString *, NSString *> *_keys;
    NSMutableArray<NSDictionary *> *_ring;
    NSUInteger _written;
    NSMutableString *_log;
}

+ (NSUInteger)maxKeys {
    return ATLScopeMaxKeys;
}

+ (NSUInteger)maxBreadcrumbs {
    return ATLScopeMaxBreadcrumbs;
}

- (instancetype)init {
    self = [super init];

    if (self) {
        _keys = [NSMutableDictionary dictionary];
        _ring = [NSMutableArray arrayWithCapacity:ATLScopeMaxBreadcrumbs];
        _log = [NSMutableString string];
    }

    return self;
}

- (void)setUserId:(NSString *)userId {
    @synchronized (self) {
        _userId = userId.length == 0 ? nil : ATLClip(userId, 128);
    }
}

- (void)setKey:(NSString *)name value:(NSString *)value {
    if (name == nil) {
        return;
    }

    NSString *key = ATLClip(name, 64);

    @synchronized (self) {
        if (value == nil) {
            [_keys removeObjectForKey:key];
        } else if (_keys[key] != nil || _keys.count < ATLScopeMaxKeys) {
            _keys[key] = ATLClip(value, ATLScopeMaxValueChars);
        }
    }
}

- (void)leaveBreadcrumb:(NSString *)category message:(NSString *)message level:(NSString *)level at:(NSTimeInterval)epochSeconds {
    NSDictionary *crumb = @{
        @"ts": [ATLCore iso:epochSeconds],
        @"category": ATLClip(category ?: @"", 40),
        @"level": level == nil ? @"info" : ATLClip(level, 10),
        @"message": ATLClip(message ?: @"", 500),
    };

    @synchronized (self) {
        if (_ring.count < ATLScopeMaxBreadcrumbs) {
            [_ring addObject:crumb];
        } else {
            _ring[_written % ATLScopeMaxBreadcrumbs] = crumb;
        }

        _written++;
    }
}

/// A rolling log: the newest 64 KB of lines, the oldest dropped whole.
- (void)log:(NSString *)line at:(NSTimeInterval)epochSeconds {
    if (line == nil) {
        return;
    }

    @synchronized (self) {
        [_log appendFormat:@"%@ %@\n", [ATLCore iso:epochSeconds], ATLClip(line, 4096)];

        if (_log.length > ATLScopeMaxLogChars) {
            NSRange tail = NSMakeRange(_log.length - ATLScopeMaxLogChars, ATLScopeMaxLogChars);
            NSRange cut = [_log rangeOfString:@"\n" options:0 range:tail];
            NSUInteger keepFrom = cut.location == NSNotFound ? tail.location : cut.location + 1;
            [_log deleteCharactersInRange:NSMakeRange(0, keepFrom)];
        }
    }
}

- (void)writeTo:(NSMutableDictionary<NSString *, id> *)payload {
    @synchronized (self) {
        if (_userId != nil) {
            payload[@"user"] = @{@"id": _userId};
        }

        if (_keys.count > 0) {
            payload[@"keys"] = [_keys copy];
        }

        if (_written > 0) {
            // Oldest first, as they happened.
            NSMutableArray *crumbs = [NSMutableArray arrayWithCapacity:_ring.count];
            NSUInteger count = MIN(_written, ATLScopeMaxBreadcrumbs);

            for (NSUInteger i = _written - count; i < _written; i++) {
                [crumbs addObject:_ring[i % ATLScopeMaxBreadcrumbs]];
            }

            payload[@"breadcrumbs"] = crumbs;
        }

        if (_log.length > 0) {
            payload[@"log"] = [_log copy];
        }
    }
}

- (void)persistTo:(NSString *)path {
    NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
    [self writeTo:snapshot];

    NSData *bytes = [NSJSONSerialization dataWithJSONObject:snapshot options:0 error:NULL];

    if (bytes == nil) {
        return;
    }

    // Atomic: a crash mid-write never leaves a half snapshot. The file must
    // stay readable behind the lock screen, where crashes also happen.
    [bytes writeToFile:path atomically:YES];
    ATLCrashUnprotect(path);
}

+ (NSDictionary<NSString *, id> *)readFrom:(NSString *)path {
    NSData *bytes = [NSData dataWithContentsOfFile:path];

    if (bytes == nil || bytes.length > 256 * 1024) {
        return nil;
    }

    id parsed = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:NULL];

    return [parsed isKindOfClass:[NSDictionary class]] ? parsed : nil;
}

@end
