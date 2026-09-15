#import "ATLEnvelopeWriter.h"

@implementation ATLEnvelopeWriter {
    NSMutableData *_out;
}

- (instancetype)initWithSDKName:(NSString *)sdkName
                        version:(NSString *)version
                         sentAt:(NSString *)sentAtIso
                      installId:(NSString *)installId
                        context:(NSDictionary<NSString *, id> *)context {
    self = [super init];

    if (self) {
        _out = [NSMutableData data];

        NSMutableDictionary *header = [NSMutableDictionary dictionary];
        header[@"sdk"] = @{@"name": sdkName, @"version": version};
        header[@"sentAt"] = sentAtIso;
        header[@"installId"] = installId;

        if (context != nil) {
            [header addEntriesFromDictionary:context];
        }

        [self appendLine:[ATLEnvelopeWriter jsonBytes:header]];
    }

    return self;
}

- (ATLEnvelopeWriter *)add:(NSString *)type payload:(NSDictionary<NSString *, id> *)payload {
    NSData *body = [ATLEnvelopeWriter jsonBytes:payload];

    [self appendLine:[ATLEnvelopeWriter jsonBytes:@{@"type": type, @"length": @(body.length)}]];
    [_out appendData:body];
    [self appendNewline];

    return self;
}

- (NSData *)bytes {
    return [_out copy];
}

- (void)appendLine:(NSData *)bytes {
    [_out appendData:bytes];
    [self appendNewline];
}

- (void)appendNewline {
    static const char newline = '\n';
    [_out appendBytes:&newline length:1];
}

+ (NSData *)jsonBytes:(id)value {
    // Foundation owns the escaping; a value the SDK itself assembled cannot
    // fail to serialize, so the fallback is an empty object, never a throw.
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:NULL];

    return data ?: [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
}

@end
