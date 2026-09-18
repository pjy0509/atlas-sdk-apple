#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The `session` item in its three moments. The server keeps day totals, not
/// sessions, so each send says only what it adds: `init` counts a start, an
/// end state counts that end, and the first handled error counts once.
@interface ATLSessionItems : NSObject

+ (NSDictionary<NSString *, id> *)startedWithEventId:(NSString *)eventId sid:(NSString *)sid startedIso:(NSString *)startedIso;
+ (NSDictionary<NSString *, id> *)erroredWithEventId:(NSString *)eventId sid:(NSString *)sid startedIso:(NSString *)startedIso;

/// `status` is `crashed` or `abnormal`; a clean exit is never sent. A
/// negative duration is left out.
+ (NSDictionary<NSString *, id> *)endedWithEventId:(NSString *)eventId
                                                sid:(NSString *)sid
                                             status:(NSString *)status
                                         startedIso:(nullable NSString *)startedIso
                                             errors:(NSInteger)errors
                                    durationSeconds:(NSTimeInterval)duration;

@end

NS_ASSUME_NONNULL_END
