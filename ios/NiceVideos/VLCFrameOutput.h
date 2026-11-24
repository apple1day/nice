#import "VLCNativePlayerConstruction.h"

struct libvlc_media_player_t;

// Configure the public libvlc vmem API before starting this player.
NICEVLCFrameDelivery * _Nonnull NICEInstallVLCFrameOutput(
    struct libvlc_media_player_t * _Nonnull player, NICEVLCFrameHandler _Nonnull handler);
