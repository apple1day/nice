#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Single-queue pull reader. The asset provides compressed samples in decode order.
@interface DirectHEVCReader : NSObject
- (instancetype)initWithTrack:(AVAssetTrack *)track asset:(AVAsset *)asset
              requireHardware:(BOOL)requireHardware NS_SWIFT_NAME(init(track:asset:requireHardware:));
/// Returns the newest available picture due at this media time, or nil during preroll.
@property(nonatomic, readonly, nullable) NSError *error;
- (nullable CMSampleBufferRef)copyPictureAt:(double)seconds CF_RETURNS_RETAINED NS_SWIFT_NAME(copyPicture(at:));
- (void)close;
@end

NS_ASSUME_NONNULL_END
