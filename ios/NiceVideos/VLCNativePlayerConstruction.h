#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import "VLCPickedFileInput.h"
#import <MobileVLCKit/VLCMedia.h>
#import <MobileVLCKit/VLCMediaPlayer.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^NICEVLCFrameHandler)(CVPixelBufferRef frame);

@protocol NICEVLCTrackSource <NSObject>
@property (nonatomic, readonly, copy) NSArray *tracksInformation;
@end
@interface VLCMedia (NICEVLCTrackSource) <NICEVLCTrackSource>
@end

typedef struct {
    uint64_t offered;
    uint64_t delivered;
    uint64_t coalesced;
    uint64_t bufferMisses;
} NICEVLCFrameStats;

@interface NICEVLCFrameDelivery : NSObject
// Assigned before starting the local media. The decoder thread reads its
// track metadata once when negotiating a new video output format.
@property (atomic, strong, nullable) id<NICEVLCTrackSource> sourceMedia;
@property (atomic, readonly) BOOL hasDeliveredFrame;
@property (atomic, readonly) NICEVLCFrameStats frameStats;
// Called on the main queue when retiring playback, before VLC stops asynchronously.
- (void)invalidate;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface NICEVLCNativeReference : NSObject
@property (nonatomic, readonly) int64_t lengthMilliseconds;
@property (nonatomic, readonly, nullable) NSString *videoStatistics;
- (BOOL)loadFileWithByteCount:(uint64_t)byteCount
                      options:(NSArray<NSString *> *)options
                         read:(NICEVLCFileRead)reader NS_SWIFT_NAME(loadFile(byteCount:options:read:));
@end

// Creates the player through VLCKit's public native-instance initializer.
// The independent nativeReference must outlive the ObjC player and must be
// released on a background queue. No private selector or pointer lookup is used.
@interface NICEVLCPlayerConstruction : NSObject
@property (nonatomic, strong, readonly) VLCMediaPlayer *player;
@property (nonatomic, strong, readonly) NICEVLCNativeReference *nativeReference;
@property (nonatomic, strong, readonly, nullable) NICEVLCFrameDelivery *frameDelivery;
- (nullable instancetype)initWithOptions:(NSArray<NSString *> *)options;
- (nullable instancetype)initWithOptions:(NSArray<NSString *> *)options
                           frameHandler:(nullable NICEVLCFrameHandler)handler NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
