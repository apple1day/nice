#import <Foundation/Foundation.h>
#import <MobileVLCKit/VLCMediaPlayer.h>

NS_ASSUME_NONNULL_BEGIN

// Creates the player through VLCKit's public native-instance initializer.
// The independent nativeReference must outlive the ObjC player and must be
// released on a background queue. No private selector or pointer lookup is used.
@interface NICEVLCPlayerConstruction : NSObject
@property (nonatomic, strong, readonly) VLCMediaPlayer *player;
@property (nonatomic, strong, readonly) NSObject *nativeReference;
- (nullable instancetype)initWithOptions:(NSArray<NSString *> *)options NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
