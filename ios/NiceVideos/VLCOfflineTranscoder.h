#import "VLCPickedFileInput.h"

NS_ASSUME_NONNULL_BEGIN

/// A single file-to-file conversion. run executes on a worker; cancel only
/// sets a flag, and never waits for a decoder, an encoder or a provider read.
@interface NICEVLCOfflineTranscoder : NSObject
@property (atomic, readonly) BOOL cancelled;
@property (nonatomic, readonly) double sourceSeconds;
@property (nonatomic, readonly) BOOL sourceHasAudio;

- (void)cancel;
- (nullable NSString *)runWithByteCount:(uint64_t)size
                               outputFD:(int)outputFD
                                  width:(unsigned)width
                                   read:(NICEVLCFileRead)read
                               progress:(void (^)(double))progress
    NS_SWIFT_NAME(run(byteCount:outputFD:width:read:progress:));
@end

NS_ASSUME_NONNULL_END
