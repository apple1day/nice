#import "VLCFrameOutput.h"
#import <MobileVLCKit/vlc/libvlc.h>
#import <MobileVLCKit/vlc/libvlc_renderer_discoverer.h>
#import <MobileVLCKit/vlc/libvlc_picture.h>
#import <MobileVLCKit/vlc/libvlc_media.h>
#import <MobileVLCKit/vlc/libvlc_media_player.h>
#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <string.h>

@interface NICEVLCFrameDelivery ()
- (instancetype)initWithHandler:(NICEVLCFrameHandler)handler;
- (void)enqueue:(CVPixelBufferRef)frame forMedia:(id<NICEVLCTrackSource>)media;
- (void)recordBufferMissForMedia:(id<NICEVLCTrackSource>)media;
- (void)recordFormatSetupForMedia:(id<NICEVLCTrackSource>)media longEdge:(unsigned)longEdge limit:(unsigned)limit
                  panoramaLimit:(unsigned)panoramaLimit;
@end

@implementation NICEVLCFrameDelivery {
    NICEVLCFrameHandler _handler;
    CVPixelBufferRef _pending;
    BOOL _scheduled;
    id<NICEVLCTrackSource> _sourceMedia;
    NICEVLCFrameStats _frameStats;
}

- (instancetype)initWithHandler:(NICEVLCFrameHandler)handler {
    self = [super init];
    if (self) {
        _handler = [handler copy];
        _maximumLongEdge = 2560;
        // The two-plane path only applies to large 8K panoramas. An
        // untagged HD source's default matrix is independent of output scale.
        _panoramaYCbCrMatrix = (__bridge NSString *)kCVImageBufferYCbCrMatrix_ITU_R_709_2;
    }
    return self;
}

- (id<NICEVLCTrackSource>)sourceMedia {
    @synchronized (self) { return _sourceMedia; }
}

- (void)setSourceMedia:(id<NICEVLCTrackSource>)media {
    @synchronized (self) {
        _sourceMedia = media;
        _frameStats = (NICEVLCFrameStats){0};
        if (_pending) { CVPixelBufferRelease(_pending); }
        _pending = NULL;
    }
}

- (BOOL)hasDeliveredFrame {
    @synchronized (self) { return _frameStats.delivered != 0; }
}

- (NICEVLCFrameStats)frameStats {
    @synchronized (self) { return _frameStats; }
}

- (void)recordBufferMissForMedia:(id<NICEVLCTrackSource>)media {
    @synchronized (self) {
        if (_handler && media == _sourceMedia) { _frameStats.bufferMisses++; }
    }
}

- (void)recordFormatSetupForMedia:(id<NICEVLCTrackSource>)media longEdge:(unsigned)longEdge limit:(unsigned)limit
                  panoramaLimit:(unsigned)panoramaLimit {
    @synchronized (self) {
        if (_handler && media == _sourceMedia) {
            _frameStats.formatSetups++;
            _frameStats.outputLongEdge = longEdge;
            _frameStats.negotiatedLimit = limit;
            _frameStats.panoramaLimit = panoramaLimit;
        }
    }
}

- (void)enqueue:(CVPixelBufferRef)frame forMedia:(id<NICEVLCTrackSource>)media {
    @synchronized (self) {
        if (!_handler) { return; }
        if (media != _sourceMedia) {
            _frameStats.staleSource++;
            return;
        }
        _frameStats.offered++;
        if (_pending) {
            _frameStats.coalesced++;
            CVPixelBufferRelease(_pending);
        }
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
            if (handler && frameToDraw) { self->_frameStats.delivered++; }
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

typedef struct {
    unsigned width, height;
    double pixelAspect;
} NICEFrameGeometry;

static NICEFrameGeometry NICEVisibleGeometry(id<NICEVLCTrackSource> media, unsigned codedWidth, unsigned codedHeight) {
    // VLC 3 passes the codec allocation (e.g. 256x98 for a 256x96 movie)
    // to vmem. Its public track API separately exposes the visible dimensions.
    const NICEFrameGeometry fallback = { codedWidth, codedHeight, 1 };
    NICEFrameGeometry visible = fallback;
    unsigned bestPadding = UINT_MAX;
    for (NSDictionary *track in media.tracksInformation) {
        if (![track[VLCMediaTracksInformationType] isEqual:VLCMediaTracksInformationTypeVideo]) { continue; }
        unsigned w = [track[VLCMediaTracksInformationVideoWidth] unsignedIntValue];
        unsigned h = [track[VLCMediaTracksInformationVideoHeight] unsignedIntValue];
        unsigned sarW = [track[VLCMediaTracksInformationSourceAspectRatio] unsignedIntValue];
        unsigned sarH = [track[VLCMediaTracksInformationSourceAspectRatioDenominator] unsignedIntValue];
        if ([track[VLCMediaTracksInformationVideoOrientation] unsignedIntValue] >= VLCMediaOrientationLeftTop) {
            // vmem applies the track rotation before calling the setup callback.
            unsigned temp = w; w = h; h = temp;
            temp = sarW; sarW = sarH; sarH = temp;
        }
        // Match this vout, ignoring unrelated video tracks and metadata from a
        // different coded resolution if a stream changes dimensions mid-file.
        if (!w || !h || w > codedWidth || h > codedHeight ||
            codedWidth - w > 127 || codedHeight - h > 127) { continue; }
        unsigned padding = codedWidth - w + codedHeight - h;
        double par = (sarW && sarH) ? (double)sarW / sarH : 1;
        if (padding < bestPadding) {
            bestPadding = padding;
            visible = (NICEFrameGeometry){ w, h, par };
        } else if (padding == bestPadding && (visible.width != w || visible.height != h || visible.pixelAspect != par)) {
            visible = fallback;
        }
    }
    return visible;
}

// One instance per negotiated vout format. The VLC 3 vmem plugin runs its
// lock/unlock (Prepare), display and cleanup serially for this specific vout.
@interface NICEVLCFrameFormat : NSObject
- (void)describePlanesWithPitches:(unsigned *)pitches lines:(unsigned *)lines;
- (instancetype)initWithGeometry:(NICEFrameGeometry)geometry matrix:(NSString *)matrix source:(id<NICEVLCTrackSource>)source delivery:(NICEVLCFrameDelivery *)delivery;
- (void *)lockPlane:(void **)planes;
- (void)unlockPicture:(void *)picture;
- (void)displayPicture:(void *)picture;
@end

@implementation NICEVLCFrameFormat {
    NICEVLCFrameDelivery *_delivery;
    id<NICEVLCTrackSource> _source;
    CVPixelBufferPoolRef _pool;
    CVPixelBufferRef _scratch;
    BOOL _scratchLocked;
    unsigned _planeCount;
    unsigned _pitches[2];
    unsigned _lines[2];
    void *_scratchPlanes[2];
    CVPixelBufferRef _picture;
    NSDictionary *_poolLimits;
    NSDictionary *_displayDimensions;
    NSString *_ycbcrMatrix;
}

- (instancetype)initWithGeometry:(NICEFrameGeometry)geometry matrix:(NSString *)matrix source:(id<NICEVLCTrackSource>)source delivery:(NICEVLCFrameDelivery *)delivery {
    self = [super init];
    if (!self) { return nil; }
    _delivery = delivery;
    _source = source;
    unsigned width = geometry.width, height = geometry.height;
    _ycbcrMatrix = [matrix copy];
    BOOL biPlanar = _ycbcrMatrix != nil;
    _planeCount = biPlanar ? 2 : 1;
    _displayDimensions = @{
        (__bridge NSString *)kCVImageBufferDisplayWidthKey: @(width * geometry.pixelAspect),
        (__bridge NSString *)kCVImageBufferDisplayHeightKey: @(height)
    };
    NSDictionary *attributes = @{
        (__bridge NSString *)kCVPixelBufferWidthKey: @(width),
        (__bridge NSString *)kCVPixelBufferHeightKey: @(height),
        (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(biPlanar ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_32BGRA),
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
    _scratchLocked = YES;
    if (biPlanar && CVPixelBufferGetPlaneCount(_scratch) != 2) { return nil; }
    for (unsigned i = 0; i < _planeCount; i++) {
        void *base = biPlanar ? CVPixelBufferGetBaseAddressOfPlane(_scratch, i) : CVPixelBufferGetBaseAddress(_scratch);
        size_t pitch = biPlanar ? CVPixelBufferGetBytesPerRowOfPlane(_scratch, i) : CVPixelBufferGetBytesPerRow(_scratch);
        size_t rows = biPlanar ? CVPixelBufferGetHeightOfPlane(_scratch, i) : CVPixelBufferGetHeight(_scratch);
        // libvlc 3 vmem writes each plane using the pitches set during negotiation.
        if (!base || (uintptr_t)base % 32 || pitch % 32 || pitch > INT_MAX ||
            pitch < (size_t)width * (biPlanar ? 1 : 4) || rows != (i == 0 ? height : height / 2)) {
            return nil;
        }
        _scratchPlanes[i] = base;
        _pitches[i] = (unsigned)pitch;
        _lines[i] = (unsigned)rows;
    }
    // Two distinct frames can still be in GPU commands, a third is the latest
    // renderer frame, and a fourth is waiting for main-queue delivery. Leave
    // room for VLC to write the next picture as well as the reserved scratch.
    // This is a ceiling: Core Video allocates the sixth surface only on demand.
    _poolLimits = @{ (__bridge NSString *)kCVPixelBufferPoolAllocationThresholdKey: @6 };
    return self;
}

- (void)describePlanesWithPitches:(unsigned *)pitches lines:(unsigned *)lines {
    memcpy(pitches, _pitches, _planeCount * sizeof(*pitches));
    memcpy(lines, _lines, _planeCount * sizeof(*lines));
}

- (void *)lockPlane:(void **)planes {
    // Drop an undisplayed but already unlocked frame if VLC skips Display.
    if (_picture) { CVPixelBufferRelease(_picture); }
    _picture = NULL;
    memcpy(planes, _scratchPlanes, sizeof(void *) * _planeCount);
    CVPixelBufferRef candidate = NULL;
    if (CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(NULL, _pool, (__bridge CFDictionaryRef)_poolLimits,
                                                           &candidate) != kCVReturnSuccess) {
        [_delivery recordBufferMissForMedia:_source];
        return NULL;
    }
    if (CVPixelBufferLockBaseAddress(candidate, 0) == kCVReturnSuccess) {
        BOOL biPlanar = _planeCount == 2;
        BOOL valid = !biPlanar || CVPixelBufferGetPlaneCount(candidate) == 2;
        void *addresses[2];
        for (unsigned i = 0; valid && i < _planeCount; i++) {
            addresses[i] = biPlanar ? CVPixelBufferGetBaseAddressOfPlane(candidate, i) : CVPixelBufferGetBaseAddress(candidate);
            size_t pitch = biPlanar ? CVPixelBufferGetBytesPerRowOfPlane(candidate, i) : CVPixelBufferGetBytesPerRow(candidate);
            valid = addresses[i] && (uintptr_t)addresses[i] % 32 == 0 && pitch == _pitches[i];
        }
        if (valid) {
            _picture = candidate;
            memcpy(planes, addresses, sizeof(void *) * _planeCount);
            return candidate;
        }
        CVPixelBufferUnlockBaseAddress(candidate, 0);
    }
    CVPixelBufferRelease(candidate);
    [_delivery recordBufferMissForMedia:_source];
    return NULL;
}

- (void)unlockPicture:(void *)picture {
    if (picture) { CVPixelBufferUnlockBaseAddress((CVPixelBufferRef)picture, 0); }
}

- (void)displayPicture:(void *)picture {
    if (picture && picture == _picture) {
        CVBufferSetAttachment(_picture, kCVImageBufferDisplayDimensionsKey,
                              (__bridge CFDictionaryRef)_displayDimensions, kCVAttachmentMode_ShouldPropagate);
        if (_ycbcrMatrix) {
            CVBufferSetAttachment(_picture, kCVImageBufferYCbCrMatrixKey,
                                  (__bridge CFStringRef)_ycbcrMatrix, kCVAttachmentMode_ShouldPropagate);
        }
        [_delivery enqueue:_picture forMedia:_source];
        CVPixelBufferRelease(_picture);
        _picture = NULL;
    }
}

- (void)dealloc {
    if (_picture) { CVPixelBufferRelease(_picture); }
    if (_scratchLocked) { CVPixelBufferUnlockBaseAddress(_scratch, 0); }
    if (_scratch) { CVPixelBufferRelease(_scratch); }
    if (_pool) { CVPixelBufferPoolRelease(_pool); }
}
@end

static unsigned NICEFrameSetup(void **opaque, char *chroma, unsigned *width, unsigned *height,
                               unsigned *pitches, unsigned *lines) {
    @autoreleasepool {
        if (*width == 0 || *height == 0) { return 0; }
        NICEVLCFrameDelivery *delivery = (__bridge NICEVLCFrameDelivery *)*opaque;
        id<NICEVLCTrackSource> source = delivery.sourceMedia;
        NICEFrameGeometry geometry = NICEVisibleGeometry(source, *width, *height);
        // Bound the CPU color conversion and IOSurface allocations for 4K/8K sources.
        // Compute the panorama cap even in standard mode. The same VLC vout
        // can survive a projection change without negotiating another format.
        unsigned normalLimit = delivery.maximumLongEdge;
        // Two 4096x2048 equirectangular eyes pack into 8192x2048. They
        // need the panorama conversion budget just as an 8192x4096 pair does.
        BOOL largePanorama = MAX(geometry.width, geometry.height) >= 7680 && MIN(geometry.width, geometry.height) >= 1920;
        BOOL panoramaRequested = delivery.preferSmallerPanoramaFrames;
        unsigned panoramaLimit = largePanorama ? MIN(normalLimit, 1600u) : normalLimit;
        unsigned limit = panoramaRequested ? panoramaLimit : normalLimit;
        const double scale = MIN(1.0, (double)limit / MAX(geometry.width, geometry.height));
        *width = geometry.width = (unsigned)MAX(1.0, round(geometry.width * scale));
        *height = geometry.height = (unsigned)MAX(1.0, round(geometry.height * scale));
        // Keep both eyes packed. Let Metal perform YCbCr -> RGB when sampling;
        // converting the whole downscaled 8K movie to BGRA costs extra bandwidth.
        NSString *matrix = largePanorama && panoramaRequested &&
                           (*width % 2 == 0) && (*height % 2 == 0) && chroma[0] != 'J'
                           ? delivery.panoramaYCbCrMatrix : nil;
        NICEVLCFrameFormat *format = [[NICEVLCFrameFormat alloc] initWithGeometry:geometry matrix:matrix
                                                                           source:source delivery:delivery];
        if (!format && matrix) {
            matrix = nil;
            format = [[NICEVLCFrameFormat alloc] initWithGeometry:geometry matrix:nil source:source delivery:delivery];
        }
        if (!format) { return 0; }
        memcpy(chroma, matrix ? "NV12" : "BGRA", 4);
        [format describePlanesWithPitches:pitches lines:lines];
        *opaque = (void *)CFBridgingRetain(format);
        [delivery recordFormatSetupForMedia:source longEdge:MAX(*width, *height) limit:limit panoramaLimit:panoramaLimit];
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
