#import "VLCNativePlayerConstruction.h"
#import <MobileVLCKit/MobileVLCKit.h>
// The bundled C umbrella uses <vlc/...> includes which are not exposed through
// CocoaPods' framework search path. Import the shipped public headers directly.
#import <MobileVLCKit/vlc/libvlc.h>
#import <MobileVLCKit/vlc/libvlc_renderer_discoverer.h>
#import <MobileVLCKit/vlc/libvlc_picture.h>
#import <MobileVLCKit/vlc/libvlc_media.h>
#import <MobileVLCKit/vlc/libvlc_media_player.h>

// libvlc's final release joins its decoder worker. Keep a separate C reference
// so the ObjC wrapper's dealloc only decrements the count, even if a late VLCKit
// idle-timer block is the wrapper's last owner on the main queue.
@interface NICEVLCNativeReference : NSObject
- (instancetype)initWithPlayer:(libvlc_media_player_t *)player library:(VLCLibrary *)library;
@end

@implementation NICEVLCNativeReference {
    libvlc_media_player_t *_player;
    VLCLibrary *_library;
}

- (instancetype)initWithPlayer:(libvlc_media_player_t *)player library:(VLCLibrary *)library {
    self = [super init];
    if (self) {
        libvlc_media_player_retain(player);
        _player = player;
        // Keep the ObjC library's log teardown and instance release on the same
        // background path, after the native player's worker has finished.
        _library = library;
    }
    return self;
}

- (void)dealloc {
    libvlc_media_player_release(_player);
    _library = nil;
}
@end

@implementation NICEVLCPlayerConstruction

- (nullable instancetype)initWithOptions:(NSArray<NSString *> *)options {
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
    _nativeReference = [[NICEVLCNativeReference alloc] initWithPlayer:native library:library];
    return self;
}
@end
