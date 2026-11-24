#import "VLCPickedFileInput.h"
#import <MobileVLCKit/vlc/libvlc.h>
#import <MobileVLCKit/vlc/libvlc_renderer_discoverer.h>
#import <MobileVLCKit/vlc/libvlc_picture.h>
#import <MobileVLCKit/vlc/libvlc_media.h>
#import <MobileVLCKit/vlc/libvlc_events.h>
#include <string.h>

@interface NICEVLCFileSource : NSObject
@property (nonatomic) uint64_t size;
@property (nonatomic, copy) NICEVLCFileRead read;
@end
@implementation NICEVLCFileSource
@end

// VLC calls read/seek serially for an open access instance. Other opens on
// the same source are independent, even while an old decoder is stopping.
@interface NICEVLCFileCursor : NSObject
@property (nonatomic) uint64_t offset;
- (instancetype)initWithSource:(NICEVLCFileSource *)source;
- (ssize_t)readInto:(unsigned char *)buffer count:(size_t)count;
@end
@implementation NICEVLCFileCursor {
    NICEVLCFileSource *_source;
    NSMutableData *_cache;
    uint64_t _cacheStart;
    size_t _validBytes;
}

- (instancetype)initWithSource:(NICEVLCFileSource *)source {
    self = [super init];
    if (self) {
        _source = source;
        // Amortize file-provider coordination when VLC requests many small reads.
        _cache = [NSMutableData dataWithLength:512 * 1024];
        if (!_cache) { return nil; }
    }
    return self;
}

- (ssize_t)readInto:(unsigned char *)buffer count:(size_t)count {
    if (!count || _offset >= _source.size) { return 0; }
    if (_offset < _cacheStart || _offset - _cacheStart >= _validBytes) {
        _cacheStart = _offset;
        _validBytes = 0;
        NSInteger requested = (NSInteger)MIN(_source.size - _offset, _cache.length);
        NSInteger n = _source.read(_cache.mutableBytes, requested, _offset);
        if (n <= 0 || n > requested) { return -1; } // unexpected EOF or provider error
        _validBytes = (size_t)n;
    }
    size_t skip = (size_t)(_offset - _cacheStart);
    size_t n = MIN(count, _validBytes - skip);
    memcpy(buffer, (const uint8_t *)_cache.bytes + skip, n);
    _offset += n;
    return (ssize_t)n;
}
@end

static int NICEOpenFile(void *opaque, void **data, uint64_t *size) {
    @autoreleasepool {
        NICEVLCFileSource *source = (__bridge NICEVLCFileSource *)opaque;
        NICEVLCFileCursor *cursor = [[NICEVLCFileCursor alloc] initWithSource:source];
        if (!cursor) { return -1; }
        *size = source.size;
        *data = (void *)CFBridgingRetain(cursor);
        return 0;
    }
}

static ssize_t NICEReadFile(void *opaque, unsigned char *buffer, size_t count) {
    @autoreleasepool { return [(__bridge NICEVLCFileCursor *)opaque readInto:buffer count:count]; }
}

static int NICESeekFile(void *opaque, uint64_t offset) {
    // Seeking past EOF is valid for a regular file; the next read returns zero.
    ((__bridge NICEVLCFileCursor *)opaque).offset = offset;
    return 0;
}

static void NICECloseFile(void *opaque) {
    @autoreleasepool { (void)CFBridgingRelease(opaque); }
}

static void NICEFileMediaFreed(const libvlc_event_t *event, void *opaque) {
    @autoreleasepool { (void)CFBridgingRelease(opaque); }
}

libvlc_media_t *NICECreatePickedMedia(libvlc_instance_t *instance, uint64_t byteCount, NICEVLCFileRead read) {
    NICEVLCFileSource *source = [NICEVLCFileSource new];
    source.size = byteCount;
    source.read = read;
    libvlc_media_t *media = libvlc_media_new_callbacks(instance, NICEOpenFile, NICEReadFile, NICESeekFile,
                                                       NICECloseFile, (__bridge void *)source);
    if (!media) { return NULL; }
    // A media descriptor can outlive the player, close asynchronously, or be
    // destroyed before its first open. Balance this retain in all three cases.
    void *owner = (void *)CFBridgingRetain(source);
    if (libvlc_event_attach(libvlc_media_event_manager(media), libvlc_MediaFreed, NICEFileMediaFreed, owner)) {
        (void)CFBridgingRelease(owner);
        libvlc_media_release(media);
        return NULL;
    }
    return media;
}
