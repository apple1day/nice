#import "VLCOfflineTranscoder.h"
#import <MobileVLCKit/MobileVLCKit.h>
#import <MobileVLCKit/vlc/libvlc.h>
#import <MobileVLCKit/vlc/libvlc_renderer_discoverer.h>
#import <MobileVLCKit/vlc/libvlc_picture.h>
#import <MobileVLCKit/vlc/libvlc_media.h>
#import <MobileVLCKit/vlc/libvlc_media_player.h>
#include <math.h>
#include <sys/stat.h>
#include <sys/mount.h>

@interface NICEVLCOfflineTranscoder ()
@property (atomic, readwrite) BOOL cancelled;
@property (atomic) BOOL readFailed;
@property (atomic) NSTimeInterval lastRead;
@end

@implementation NICEVLCOfflineTranscoder
- (void)cancel { self.cancelled = YES; }

- (NSString *)runWithByteCount:(uint64_t)size outputFD:(int)outputFD width:(unsigned)width
                          read:(NICEVLCFileRead)read progress:(void (^)(double))progress {
    if (self.cancelled) { return @"转换已取消。"; }
    __attribute__((objc_precise_lifetime)) VLCLibrary *library = [[VLCLibrary alloc] initWithOptions:@[
        @"--no-video-title-show", @"--no-metadata-network-access"
    ]];
    if (!library.instance) { return @"无法初始化本机转换器。"; }
    libvlc_media_t *media = NICECreatePickedMedia((libvlc_instance_t *)library.instance, size,
        ^NSInteger(void *buffer, NSInteger count, uint64_t offset) {
            if (self.cancelled) { return -1; }
            NSInteger bytes = read(buffer, count, offset);
            if (bytes < 0) { self.readFailed = YES; }
            if (bytes > 0) { self.lastRead = NSProcessInfo.processInfo.systemUptime; }
            return bytes;
        });
    if (!media) { return @"无法打开原片。"; }

    // The file sout has no real-time audio clock. VLC's transcode decoder
    // preserves reference pictures and the fps filter samples output on the
    // original media timeline. The fd access module duplicates our already
    // open, seekable staging descriptor; no filename is parsed as VLC syntax.
    NSString *chain = [NSString stringWithFormat:
        @":sout=#transcode{vcodec=h264,venc=avcodec{codec=h264_videotoolbox,options{allow_sw=1}},vb=6000,width=%u,maxheight=1920,fps=30,acodec=mp4a,ab=128,channels=2,samplerate=48000}:standard{access=fd,mux=mp4,dst=%d}",
        width, outputFD];
    libvlc_media_add_option(media, chain.UTF8String);
    libvlc_media_player_t *player = libvlc_media_player_new_from_media(media);
    NSString *error = nil;
    if (!player || libvlc_media_player_play(player) != 0) {
        error = @"无法启动本机视频转换。";
    } else {
        float lastProgress = 0;
        off_t lastWritten = 0;
        NSTimeInterval lastActivity = NSProcessInfo.processInfo.systemUptime;
        for (;;) {
            @autoreleasepool {
                if (self.cancelled || self.readFailed) { error = @"转换已中止或原文件无法读取。"; break; }
                libvlc_state_t state = libvlc_media_player_get_state(player);
                libvlc_time_t length = libvlc_media_player_get_length(player);
                if (length > 0) { _sourceSeconds = (double)length / 1000; }
                if (state == libvlc_Ended) { break; }
                if (state == libvlc_Error || state == libvlc_Stopped) {
                    error = @"VLC 无法完成此片源的解码或编码。";
                    break;
                }
                NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
                struct stat output;
                if (fstat(outputFD, &output) == 0 && output.st_size > lastWritten) {
                    lastWritten = output.st_size;
                    lastActivity = now;
                }
                lastActivity = MAX(lastActivity, self.lastRead);
                if (now - lastActivity > 120) {
                    error = @"转换器已连续两分钟没有读入或写出数据，请确认原文件可用和存储空间充足。";
                    break;
                }
                float position = libvlc_media_player_get_position(player);
                if (isfinite(position) && position >= lastProgress + 0.005f) {
                    lastProgress = position;
                    progress(MIN(0.98, position * 0.98));
                }
                [NSThread sleepForTimeInterval:0.15];
            }
        }
        libvlc_media_track_t **tracks = NULL;
        unsigned count = libvlc_media_tracks_get(media, &tracks);
        for (unsigned i = 0; i < count; ++i) {
            if (tracks[i]->i_type == libvlc_track_audio) { _sourceHasAudio = YES; }
        }
        if (count) { libvlc_media_tracks_release(tracks, count); }
        if (_sourceSeconds <= 0) { _sourceSeconds = (double)libvlc_media_get_duration(media) / 1000; }
    }
    // Join the transcoder and finalize the MP4 index on this worker before
    // the caller reads or publishes the staging file.
    if (player) {
        libvlc_media_player_stop(player);
        libvlc_media_player_release(player);
    }
    libvlc_media_release(media);
    if (error) {
        struct statfs volume;
        if (fstatfs(outputFD, &volume) == 0 && (uint64_t)volume.f_bavail * volume.f_bsize < 8 * 1024 * 1024) {
            return @"iPhone 的可用空间不足，无法生成完整副本。";
        }
    }
    if (self.readFailed) { return @"读取原片时出错，无法生成完整的副本。"; }
    return error;
}
@end
