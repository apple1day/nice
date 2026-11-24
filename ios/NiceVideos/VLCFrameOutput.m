#import "VLCFrameOutput.h"
#import <MobileVLCKit/vlc/libvlc.h>
#import <MobileVLCKit/vlc/libvlc_renderer_discoverer.h>
#import <MobileVLCKit/vlc/libvlc_picture.h>
#import <MobileVLCKit/vlc/libvlc_media.h>
#import <MobileVLCKit/vlc/libvlc_media_player.h>
#include <math.h>
#include <stdint.h>
#include <string.h>

@interface NICEVLCFrameDelivery ()
- (instancetype)initWithHandler:(NICEVLCFrameHandler)handler;
- (void)enqueue:(CVPixelBufferRef)frame;
@end

@implementation NICEVLCFrameDelivery {
    NICEVLCFrameHandler _handler;
    CVPixelBufferRef _pending;
    BOOL _scheduled;
}

- (instancetype)initWithHandler:(NICEVLCFrameHandler)handler {
    self = [super init];
    if (self) { _handler = [handler copy]; }
    return self;
}

- (void)enqueue:(CVPixelBufferRef)frame {
    @synchronized (self) {
        if (!_handler) { return; }
        if (_pending) { CVPixelBufferRelease(_pending); }
        _pending = CVPixelBufferRetain(frame);
        if (_scheduled) { return; }
        _scheduled = YES;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        CVPixelBufferRef frameToDraw;
        NICEVLCFrameHandler handler;
        @synchronized (self) {
            frameToDraw = self->_pending;
            self->_pending = NULL;
            self->_scheduled = NO;
            handler = self->_handler;
        }
        if (frameToDraw) {
            if (handler) { handler(frameToDraw); }
            CVPixelBufferRelease(frameToDraw);
        }
    });
}

- (void)invalidate {
    @synchronized (self) {
        _handler = nil;
        if (_pending) { CVPixelBufferRelease(_pending); }
        _pending = NULL;
    }
}

- (void)dealloc {
    if (_pending) { CVPixelBufferRelease(_pending); }
}
@end

// One instance per negotiated vout format. The VLC 3 vmem plugin runs its
// lock/unlock (Prepare), display and cleanup serially for this specific vout.
@interface NICEVLCFrameFormat : NSObject
@property (nonatomic, readonly) size_t pitch;
- (instancetype)initWithWidth:(unsigned)width height:(unsigned)height delivery:(NICEVLCFrameDelivery *)delivery;
- (void *)lockPlane:(void **)planes;
- (void)unlockPicture:(void *)picture;
- (void)displayPicture:(void *)picture;
@end

@implementation NICEVLCFrameFormat {
    NICEVLCFrameDelivery *_delivery;
    CVPixelBufferPoolRef _pool;
    CVPixelBufferRef _scratch;
    void *_scratchBase;
    CVPixelBufferRef _picture;
    NSDictionary *_poolLimits;
}

- (instancetype)initWithWidth:(unsigned)width height:(unsigned)height delivery:(NICEVLCFrameDelivery *)delivery {
    self = [super init];
    if (!self) { return nil; }
    _delivery = delivery;
    NSDictionary *attributes = @{
        (__bridge NSString *)kCVPixelBufferWidthKey: @(width),
        (__bridge NSString *)kCVPixelBufferHeightKey: @(height),
        (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (__bridge NSString *)kCVPixelBufferBytesPerRowAlignmentKey: @64,
        (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    if (CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attributes, &_pool) != kCVReturnSuccess) {
        return nil;
    }
    // vmem requires a writable plane even if Metal is still using all available
    // buffers. This reserved surface receives dropped frames under pressure.
    if (CVPixelBufferPoolCreatePixelBuffer(NULL, _pool, &_scratch) != kCVReturnSuccess ||
        CVPixelBufferLockBaseAddress(_scratch, 0) != kCVReturnSuccess) {
        return nil;
    }
    _scratchBase = CVPixelBufferGetBaseAddress(_scratch);
    _pitch = CVPixelBufferGetBytesPerRow(_scratch);
    _poolLimits = @{ (__bridge NSString *)kCVPixelBufferPoolAllocationThresholdKey: @5 }; // includes scratch
    if (!_scratchBase || (uintptr_t)_scratchBase % 32 || _pitch % 32 || _pitch < width * 4) {
        CVPixelBufferUnlockBaseAddress(_scratch, 0);
        _scratchBase = NULL;
        return nil;
    }
    return self;
}

- (void *)lockPlane:(void **)planes {
    // Drop an undisplayed but already unlocked frame if VLC skips Display.
    if (_picture) { CVPixelBufferRelease(_picture); }
    _picture = NULL;
    planes[0] = _scratchBase;
    CVPixelBufferRef candidate = NULL;
    if (CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(NULL, _pool, (__bridge CFDictionaryRef)_poolLimits,
                                                           &candidate) != kCVReturnSuccess) {
        return NULL;
    }
    if (CVPixelBufferLockBaseAddress(candidate, 0) == kCVReturnSuccess) {
        void *base = CVPixelBufferGetBaseAddress(candidate);
        if (base && (uintptr_t)base % 32 == 0 && CVPixelBufferGetBytesPerRow(candidate) == _pitch) {
            _picture = candidate;
            planes[0] = base;
            return candidate;
        }
        CVPixelBufferUnlockBaseAddress(candidate, 0);
    }
    CVPixelBufferRelease(candidate);
    return NULL;
}

- (void)unlockPicture:(void *)picture {
    if (picture) { CVPixelBufferUnlockBaseAddress((CVPixelBufferRef)picture, 0); }
}

- (void)displayPicture:(void *)picture {
    if (picture && picture == _picture) {
        [_delivery enqueue:_picture];
        CVPixelBufferRelease(_picture);
        _picture = NULL;
    }
}

- (void)dealloc {
    if (_picture) { CVPixelBufferRelease(_picture); }
    if (_scratchBase) { CVPixelBufferUnlockBaseAddress(_scratch, 0); }
    if (_scratch) { CVPixelBufferRelease(_scratch); }
    if (_pool) { CVPixelBufferPoolRelease(_pool); }
}
@end

static unsigned NICEFrameSetup(void **opaque, char *chroma, unsigned *width, unsigned *height,
                               unsigned *pitches, unsigned *lines) {
    @autoreleasepool {
        if (*width == 0 || *height == 0) { return 0; }
        // Bound the CPU color conversion and IOSurface allocations for 4K/8K sources.
        const double scale = MIN(1.0, 2560.0 / MAX(*width, *height));
        *width = (unsigned)MAX(1.0, round(*width * scale));
        *height = (unsigned)MAX(1.0, round(*height * scale));
        NICEVLCFrameFormat *format = [[NICEVLCFrameFormat alloc] initWithWidth:*width height:*height
                                                                     delivery:(__bridge NICEVLCFrameDelivery *)*opaque];
        if (!format) { return 0; }
        memcpy(chroma, "BGRA", 4);
        pitches[0] = (unsigned)format.pitch;
        lines[0] = *height;
        *opaque = (void *)CFBridgingRetain(format);
        return 1;
    }
}

static void NICEFrameCleanup(void *opaque) {
    @autoreleasepool { (void)CFBridgingRelease(opaque); }
}

static void *NICEFrameLock(void *opaque, void **planes) {
    @autoreleasepool { return [(__bridge NICEVLCFrameFormat *)opaque lockPlane:planes]; }
}

static void NICEFrameUnlock(void *opaque, void *picture, void *const *planes) {
    [(__bridge NICEVLCFrameFormat *)opaque unlockPicture:picture];
}

static void NICEFrameDisplay(void *opaque, void *picture) {
    @autoreleasepool { [(__bridge NICEVLCFrameFormat *)opaque displayPicture:picture]; }
}

NICEVLCFrameDelivery *NICEInstallVLCFrameOutput(libvlc_media_player_t *player, NICEVLCFrameHandler handler) {
    NICEVLCFrameDelivery *delivery = [[NICEVLCFrameDelivery alloc] initWithHandler:handler];
    libvlc_video_set_callbacks(player, NICEFrameLock, NICEFrameUnlock, NICEFrameDisplay, (__bridge void *)delivery);
    libvlc_video_set_format_callbacks(player, NICEFrameSetup, NICEFrameCleanup);
    return delivery;
}
