#import "VLCNativePlayerConstruction.h"
#import "VLCFrameOutput.h"
#import <MobileVLCKit/MobileVLCKit.h>
// The bundled C umbrella uses <vlc/...> includes which are not exposed through
// CocoaPods' framework search path. Import the shipped public headers directly.
#import <MobileVLCKit/vlc/libvlc.h>
#import <MobileVLCKit/vlc/libvlc_renderer_discoverer.h>
#import <MobileVLCKit/vlc/libvlc_picture.h>
#import <MobileVLCKit/vlc/libvlc_media.h>
#import <MobileVLCKit/vlc/libvlc_media_player.h>
#include <stdatomic.h>
#include <string.h>

@implementation VLCMedia (NICEVLCTrackSource)
@end

// vmem negotiates on the decoder thread, possibly before VLCKit has published
// its ObjC wrapper. Retain this descriptor to read the visible video geometry.
@interface NICEVLCPickedTracks : NSObject <NICEVLCTrackSource>
- (instancetype)initWithMedia:(libvlc_media_t *)media;
@end

@implementation NICEVLCPickedTracks {
    libvlc_media_t *_media;
}
- (instancetype)initWithMedia:(libvlc_media_t *)media {
    self = [super init];
    if (self) {
        libvlc_media_retain(media);
        _media = media;
    }
    return self;
}
- (NSArray *)tracksInformation {
    NSMutableArray *result = [NSMutableArray array];
    libvlc_media_track_t **tracks;
    unsigned count = libvlc_media_tracks_get(_media, &tracks);
    for (unsigned i = 0; i < count; i++) {
        libvlc_media_track_t *track = tracks[i];
        if (track->i_type != libvlc_track_video || !track->video) { continue; }
        const libvlc_video_track_t *video = track->video;
        [result addObject:@{
            VLCMediaTracksInformationType: VLCMediaTracksInformationTypeVideo,
            VLCMediaTracksInformationVideoWidth: @(video->i_width),
            VLCMediaTracksInformationVideoHeight: @(video->i_height),
            VLCMediaTracksInformationVideoOrientation: @(video->i_orientation),
            VLCMediaTracksInformationSourceAspectRatio: @(video->i_sar_num),
            VLCMediaTracksInformationSourceAspectRatioDenominator: @(video->i_sar_den)
        }];
    }
    if (count) { libvlc_media_tracks_release(tracks, count); }
    return result;
}
- (void)dealloc { libvlc_media_release(_media); }
@end

// libvlc's final release joins its decoder worker. Keep a separate C reference
// so the ObjC wrapper's dealloc only decrements the count, even if a late VLCKit
// idle-timer block is the wrapper's last owner on the main queue.
@interface NICEVLCNativeReference ()
- (instancetype)initWithPlayer:(libvlc_media_player_t *)player library:(VLCLibrary *)library
                 frameDelivery:(NICEVLCFrameDelivery *)delivery;
@end

typedef enum {
    NICEDecoderUnknown, NICEDecoderAVCodec, NICEDecoderVideoToolbox, NICEDecoderOther
} NICEDecoderModule;

static void NICEObserveVideoDecoder(void *opaque, int level, const libvlc_log_t *context,
                                    const char *format, va_list args) {
    // VLC 3 announces the selected module after successful initialization.
    // Do not format, retain or forward arbitrary messages from decoder threads.
    if (level != LIBVLC_DEBUG || strcmp(format, "using %s module \"%s\"") != 0) { return; }
    va_list values;
    va_copy(values, args);
    const char *capability = va_arg(values, const char *);
    const char *name = va_arg(values, const char *);
    va_end(values);
    if (strcmp(capability, "video decoder") != 0) { return; }
    NICEDecoderModule module = NICEDecoderOther;
    if (strcmp(name, "avcodec") == 0) { module = NICEDecoderAVCodec; }
    else if (strcmp(name, "videotoolbox") == 0) { module = NICEDecoderVideoToolbox; }
    atomic_store_explicit((atomic_int *)opaque, module, memory_order_relaxed);
}

@implementation NICEVLCNativeReference {
    libvlc_media_player_t *_player;
    VLCLibrary *_library;
    NICEVLCFrameDelivery *_delivery;
    atomic_int _observedVideoDecoder;
    BOOL _observesVideoDecoder;
}

- (instancetype)initWithPlayer:(libvlc_media_player_t *)player library:(VLCLibrary *)library
                 frameDelivery:(NICEVLCFrameDelivery *)delivery {
    self = [super init];
    if (self) {
        libvlc_media_player_retain(player);
        _player = player;
        atomic_init(&_observedVideoDecoder, NICEDecoderUnknown);
        // Keep the ObjC library's log teardown and instance release on the same
        // background path, after the native player's worker has finished.
        _library = library;
        _delivery = delivery;
    }
    return self;
}

- (void)observeVideoDecoderForNewInput {
    atomic_store_explicit(&_observedVideoDecoder, NICEDecoderUnknown, memory_order_relaxed);
    if (_observesVideoDecoder) { return; }
    _observesVideoDecoder = YES;
    libvlc_log_set((libvlc_instance_t *)_library.instance, NICEObserveVideoDecoder, &_observedVideoDecoder);
}

- (NSString *)observedVideoDecoder {
    switch (atomic_load_explicit(&_observedVideoDecoder, memory_order_relaxed)) {
        case NICEDecoderAVCodec: return @"avcodec";
        case NICEDecoderVideoToolbox: return @"videotoolbox";
        case NICEDecoderOther: return @"other";
        default: return nil;
    }
}

- (int64_t)timeMilliseconds { return libvlc_media_player_get_time(_player); }

- (void)seekToMilliseconds:(int64_t)milliseconds { libvlc_media_player_set_time(_player, milliseconds); }

- (int64_t)lengthMilliseconds { return libvlc_media_player_get_length(_player); }

- (NSString *)videoTrackDescriptionWithFrameRate:(double *)rate {
    *rate = 0;
    libvlc_media_t *media = libvlc_media_player_get_media(_player);
    if (!media) { return nil; }
    libvlc_media_track_t **tracks = NULL;
    unsigned count = libvlc_media_tracks_get(media, &tracks);
    libvlc_media_release(media);
    if (!count) { return nil; }

    int activeID = libvlc_video_get_track(_player);
    libvlc_media_track_t *selected = NULL;
    unsigned videoCount = 0;
    for (unsigned i = 0; i < count; ++i) {
        libvlc_media_track_t *track = tracks[i];
        if (track->i_type != libvlc_track_video || !track->video) { continue; }
        ++videoCount;
        if (track->i_id == activeID) { selected = track; break; }
        selected = track;
    }
    NSString *result = nil;
    if (selected && (selected->i_id == activeID || videoCount == 1)) {
        libvlc_video_track_t *video = selected->video;
        if (video->i_width && video->i_height) {
            NSMutableString *details = [NSMutableString stringWithFormat:@"%u×%u", video->i_width, video->i_height];
            const char *codec = libvlc_media_get_codec_description(libvlc_track_video, selected->i_codec);
            if (codec && *codec) { [details appendFormat:@" · %s", codec]; }
            if (video->i_frame_rate_num && video->i_frame_rate_den) {
                *rate = (double)video->i_frame_rate_num / video->i_frame_rate_den;
                [details appendFormat:@" · %.2f fps", *rate];
            }
            if (selected->i_bitrate) { [details appendFormat:@" · %.2f Mb/s", selected->i_bitrate / 1e6]; }
            result = details;
        }
    }
    libvlc_media_tracks_release(tracks, count);
    return result;
}


- (NICEVLCVideoStats)videoStatistics {
    const NICEVLCVideoStats unavailable = { -1, -1, -1 };
    libvlc_media_t *media = libvlc_media_player_get_media(_player);
    if (!media) { return unavailable; }
    libvlc_media_stats_t stats = {0};
    int available = libvlc_media_get_stats(media, &stats);
    libvlc_media_release(media);
    if (!available) { return unavailable; }
    return (NICEVLCVideoStats){ stats.i_decoded_video, stats.i_displayed_pictures, stats.i_lost_pictures };
}

- (BOOL)loadFileWithByteCount:(uint64_t)byteCount options:(NSArray<NSString *> *)options read:(NICEVLCFileRead)reader {
    libvlc_media_t *media = NICECreatePickedMedia((libvlc_instance_t *)_library.instance, byteCount, reader);
    if (!media) { return NO; }
    for (NSString *option in options) { libvlc_media_add_option(media, option.UTF8String); }
    if (_delivery) { _delivery.sourceMedia = [[NICEVLCPickedTracks alloc] initWithMedia:media]; }
    libvlc_media_player_set_media_async(_player, media);
    libvlc_media_release(media);
    return YES;
}

- (void)dealloc {
    if (_observesVideoDecoder) {
        // This public API joins in-flight log callbacks before freeing their storage.
        libvlc_log_unset((libvlc_instance_t *)_library.instance);
    }
    libvlc_media_player_release(_player);
    // libvlc joins its vout in the final release. Only now may the opaque
    // pointer originally passed to libvlc_video_set_callbacks be destroyed.
    _delivery = nil;
    _library = nil;
}
@end

@implementation NICEVLCPlayerConstruction

- (nullable instancetype)initWithOptions:(NSArray<NSString *> *)options {
    return [self initWithOptions:options frameHandler:nil];
}

- (nullable instancetype)initWithOptions:(NSArray<NSString *> *)options
                           frameHandler:(NICEVLCFrameHandler)handler {
    self = [super init];
    if (!self) { return nil; }

    VLCLibrary *library = [[VLCLibrary alloc] initWithOptions:options];
    if (!library || !library.instance) { return nil; }
    libvlc_media_player_t *native = libvlc_media_player_new((libvlc_instance_t *)library.instance);
    if (!native) { return nil; }

    // In pinned VLCKit 3.7.3 this public initializer adopts the initial native
    // reference without retaining it. The wrapper releases that reference in
    // dealloc; NICEVLCNativeReference owns exactly one additional retain.
    _player = [[VLCMediaPlayer alloc] initWithLibVLCInstance:native andLibrary:library];
    if (!_player) {
        libvlc_media_player_release(native);
        return nil;
    }
    if (handler) {
        _frameDelivery = NICEInstallVLCFrameOutput(native, handler);
    }
    _nativeReference = [[NICEVLCNativeReference alloc] initWithPlayer:native library:library
                                                        frameDelivery:_frameDelivery];
    return self;
}
@end
