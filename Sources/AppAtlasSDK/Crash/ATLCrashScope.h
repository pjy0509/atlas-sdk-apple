#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// What the app told us about its own state: a user id, custom keys, a ring
/// of breadcrumbs and a rolling log. Bounded everywhere, because it rides
/// every report. A native crash is read only at the next start, from a
/// process that is gone, so the scope also goes to disk within a second of
/// every change (ATLCrash debounces the writes).
@interface ATLCrashScope : NSObject

+ (NSUInteger)maxKeys;
+ (NSUInteger)maxBreadcrumbs;

- (void)setUserId:(nullable NSString *)userId;
- (void)setKey:(NSString *)name value:(nullable NSString *)value;
- (void)leaveBreadcrumb:(NSString *)category message:(NSString *)message level:(nullable NSString *)level at:(NSTimeInterval)epochSeconds;
- (void)log:(NSString *)line at:(NSTimeInterval)epochSeconds;

/// Copies the scope into a report payload; absent parts are left out.
- (void)writeTo:(NSMutableDictionary<NSString *, id> *)payload;

/// The scope as JSON at `path`, atomically. Off the caller's thread.
- (void)persistTo:(NSString *)path;

/// What a dead process last persisted, or nil.
+ (nullable NSDictionary<NSString *, id> *)readFrom:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
