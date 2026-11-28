#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

struct libvlc_instance_t;
struct libvlc_media_t;
typedef NSInteger (^NICEVLCFileRead)(void *buffer, NSInteger count, uint64_t offset);

// Each libvlc input (including a replacement VR decoder) gets its own cursor.
// The returned descriptor owns the read block until its final native release.
struct libvlc_media_t * _Nullable NICECreatePickedMedia(
    struct libvlc_instance_t *instance, uint64_t byteCount, NICEVLCFileRead read);

NS_ASSUME_NONNULL_END
