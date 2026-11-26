#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/** Counts non-silent PCM frames in the real AVPlayerItem audio processing path. */
@interface NICEAudioTapProbe : NSObject
@property (nonatomic, readonly) uint64_t audibleFrames;
- (BOOL)attachToItem:(AVPlayerItem *)item track:(AVAssetTrack *)track NS_SWIFT_NAME(attach(to:track:));
@end

NS_ASSUME_NONNULL_END
