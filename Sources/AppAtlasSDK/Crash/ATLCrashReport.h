#import <Foundation/Foundation.h>

#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// FROZEN once shipped: the mechanism strings. The server keys issue kinds on
/// them, and a rename regroups every open issue.
extern NSString *const ATLMechanismUncaught;   // uncaughtExceptionHandler: an NSException nobody caught
extern NSString *const ATLMechanismRecorded;   // recordError
extern NSString *const ATLMechanismSignal;     // signalHandler
extern NSString *const ATLMechanismMach;       // machException
extern NSString *const ATLMechanismAnr;        // anr: the main thread stopped answering
extern NSString *const ATLMechanismExitInfo;   // exitInfo: a death the OS knew about and we only inferred or were told
extern NSString *const ATLMechanismMetricKit;  // metricKit: a non-fatal diagnostic the OS delivered

/// The `crash` / `error` item the server groups on (the server repo's
/// docs/sdk-crash.md §3), built from what each hook hands over. Frames carry
/// the platform-neutral vocabulary plus, for native code, the raw address,
/// the address relative to its image and the image's UUID — what the server
/// needs to look the symbol up in a dSYM, and nothing it does not.
@interface ATLCrashReport : NSObject

+ (NSMutableDictionary<NSString *, id> *)headWithEventId:(NSString *)eventId
                                               crashedAt:(NSString *)crashedAtIso
                                               sessionId:(nullable NSString *)sessionId
                                               mechanism:(NSString *)mechanism
                                                 handled:(BOOL)handled;

/// A payload with one exception: type, message and frames as given.
+ (NSMutableDictionary<NSString *, id> *)payloadWithEventId:(NSString *)eventId
                                                  crashedAt:(NSString *)crashedAtIso
                                                  sessionId:(nullable NSString *)sessionId
                                                  mechanism:(NSString *)mechanism
                                                    handled:(BOOL)handled
                                                       type:(NSString *)type
                                                    message:(nullable NSString *)message
                                                     frames:(NSArray *)frames;

/// Frames for addresses of this very process: located against the image
/// cache, named through dladdr when the symbol is exported (a stripped
/// release names nothing, and the server fills the rest from the dSYM).
/// `topIsPC` says the first address was sampled, not returned to.
+ (NSArray<NSDictionary *> *)framesForAddresses:(const uintptr_t *)addresses count:(NSUInteger)count topIsPC:(BOOL)topIsPC;

/// The calling thread's own stack, minus `skip` frames of ours.
+ (NSArray<NSDictionary *> *)currentFramesSkipping:(NSUInteger)skip;

/// A native frame as the wire wants it.
+ (NSDictionary<NSString *, id> *)nativeFrameWithAddress:(uintptr_t)address
                                                relative:(uintptr_t)relative
                                                    uuid:(nullable NSString *)uuid
                                                    path:(nullable NSString *)path
                                                function:(nullable NSString *)function;

/// An NSError as a type the server groups on: domain and code.
+ (NSString *)typeForError:(NSError *)error;

@end

NS_ASSUME_NONNULL_END
