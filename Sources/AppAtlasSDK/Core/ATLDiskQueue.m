#import "ATLDiskQueue.h"

static NSString *const ATLQueueSuffix = @".envelope";
static const NSUInteger ATLQueueMaxFiles = 30;

@implementation ATLDiskQueue {
    NSString *_directory;
    unsigned long long _counter;
}

+ (NSUInteger)maxFiles {
    return ATLQueueMaxFiles;
}

- (instancetype)initWithDirectory:(NSString *)directory {
    self = [super init];

    if (self) {
        // No I/O here: the directory is made on first use, off the caller.
        _directory = [directory copy];
    }

    return self;
}

- (NSString *)offer:(NSData *)envelope {
    @synchronized (self) {
        NSFileManager *files = [NSFileManager defaultManager];
        [files createDirectoryAtPath:_directory withIntermediateDirectories:YES attributes:nil error:NULL];

        NSArray<NSString *> *present = [self list];

        for (NSInteger index = 0; index <= (NSInteger) present.count - (NSInteger) ATLQueueMaxFiles; index++) {
            [files removeItemAtPath:present[(NSUInteger) index] error:NULL];
        }

        long long stamp = (long long) ([[NSDate date] timeIntervalSince1970] * 1000.0);
        NSString *name = [NSString stringWithFormat:@"%013lld_%03llu%@", stamp, _counter++ % 1000, ATLQueueSuffix];
        NSString *path = [_directory stringByAppendingPathComponent:name];

        return [envelope writeToFile:path atomically:YES] ? path : nil;
    }
}

- (NSArray<NSString *> *)list {
    NSArray<NSString *> *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:_directory error:NULL];
    NSMutableArray<NSString *> *kept = [NSMutableArray array];

    for (NSString *name in [names sortedArrayUsingSelector:@selector(compare:)]) {
        if ([name hasSuffix:ATLQueueSuffix]) {
            [kept addObject:[_directory stringByAppendingPathComponent:name]];
        }
    }

    return kept;
}

@end
