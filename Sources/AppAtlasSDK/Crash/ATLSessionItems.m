#import "ATLSessionItems.h"

@implementation ATLSessionItems

+ (NSDictionary<NSString *, id> *)startedWithEventId:(NSString *)eventId sid:(NSString *)sid startedIso:(NSString *)startedIso {
    NSMutableDictionary *payload = [self baseWithEventId:eventId sid:sid status:@"ok" startedIso:startedIso];
    payload[@"init"] = @YES;

    return payload;
}

+ (NSDictionary<NSString *, id> *)erroredWithEventId:(NSString *)eventId sid:(NSString *)sid startedIso:(NSString *)startedIso {
    NSMutableDictionary *payload = [self baseWithEventId:eventId sid:sid status:@"ok" startedIso:startedIso];
    payload[@"errors"] = @1;

    return payload;
}

+ (NSDictionary<NSString *, id> *)endedWithEventId:(NSString *)eventId
                                                sid:(NSString *)sid
                                             status:(NSString *)status
                                         startedIso:(NSString *)startedIso
                                             errors:(NSInteger)errors
                                    durationSeconds:(NSTimeInterval)duration {
    NSMutableDictionary *payload = [self baseWithEventId:eventId sid:sid status:status startedIso:startedIso];
    payload[@"errors"] = @(errors);

    if (duration >= 0) {
        payload[@"duration"] = @((long long) duration);
    }

    return payload;
}

+ (NSMutableDictionary<NSString *, id> *)baseWithEventId:(NSString *)eventId sid:(NSString *)sid status:(NSString *)status
                                              startedIso:(NSString *)startedIso {
    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[@"eventId"] = eventId;
    payload[@"sid"] = sid;
    payload[@"status"] = status;

    if (startedIso != nil) {
        payload[@"started"] = startedIso;
    }

    return payload;
}

@end
