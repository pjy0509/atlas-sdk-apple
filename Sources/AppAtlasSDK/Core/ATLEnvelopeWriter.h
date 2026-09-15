#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Builds the wire bytes the server's parser reads (common/envelope.py) and
/// tests/envelope_cases.json pins for every SDK. Every item declares its byte
/// length, so payloads may carry whatever whitespace NSJSONSerialization
/// happens to emit.
@interface ATLEnvelopeWriter : NSObject

/// `context` rides the header once per envelope — the device and app facts
/// every item shares (the crash module reads the same block). May be nil.
- (instancetype)initWithSDKName:(NSString *)sdkName
                        version:(NSString *)version
                         sentAt:(NSString *)sentAtIso
                      installId:(NSString *)installId
                        context:(nullable NSDictionary<NSString *, id> *)context;

/// One item: a type-plus-length header line, then the payload bytes.
- (ATLEnvelopeWriter *)add:(NSString *)type payload:(NSDictionary<NSString *, id> *)payload;

- (NSData *)bytes;

@end

NS_ASSUME_NONNULL_END
