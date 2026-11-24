#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <MobileVLCKit/VLCMedia.h>
#import <MobileVLCKit/VLCMediaPlayer.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^NICEVLCFrameHandler)(CVPixelBufferRef frame);

@interface NICEVLCFrameDelivery : NSObject
// Assigned before starting the local media. The decoder thread reads its
// track metadata once when negotiating a new video output format.
@property (atomic, strong, nullable) VLCMedia *sourceMedia;
@property (atomic, readonly) BOOL hasDeliveredFrame;
// Called on the main queue when retiring playback, before VLC stops asynchronously.
- (void)invalidate;
- (instancetype)init NS_UNAVAILABLE;
@end

// Creates the player through VLCKit's public native-instance initializer.
// The independent nativeReference must outlive the ObjC player and must be
// released on a background queue. No private selector or pointer lookup is used.
@interface NICEVLCPlayerConstruction : NSObject
@property (nonatomic, strong, readonly) VLCMediaPlayer *player;
@property (nonatomic, strong, readonly) NSObject *nativeReference;
@property (nonatomic, strong, readonly, nullable) NICEVLCFrameDelivery *frameDelivery;
- (nullable instancetype)initWithOptions:(NSArray<NSString *> *)options;
- (nullable instancetype)initWithOptions:(NSArray<NSString *> *)options
                           frameHandler:(nullable NICEVLCFrameHandler)handler NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
