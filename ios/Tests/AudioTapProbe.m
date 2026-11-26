#import "NiceVideosTests-Bridging-Header.h"
#import <MediaToolbox/MediaToolbox.h>
#import <stdatomic.h>

@implementation NICEAudioTapProbe {
    _Atomic(uint64_t) _audibleFrames;
}

static void tapInit(MTAudioProcessingTapRef tap, void *clientInfo, void **storage) {
    *storage = (void *)CFRetain((CFTypeRef)clientInfo);
}

static void tapFinalize(MTAudioProcessingTapRef tap) {
    CFRelease(MTAudioProcessingTapGetStorage(tap));
}

static void processAudio(MTAudioProcessingTapRef tap, CMItemCount requested,
                         MTAudioProcessingTapFlags flags, AudioBufferList *buffers,
                         CMItemCount *returned, MTAudioProcessingTapFlags *outputFlags) {
    *returned = 0;
    if (MTAudioProcessingTapGetSourceAudio(tap, requested, buffers, outputFlags, NULL, returned) != noErr ||
        *returned <= 0 || buffers->mNumberBuffers == 0) return;
    const AudioBuffer first = buffers->mBuffers[0];
    if (!first.mData) return;
    // The fixture is a mono sine wave. Inspect only a small prefix and leave
    // the real-time audio buffers intact. No locks, logs or allocations.
    const uint8_t *samples = first.mData;
    for (size_t i = 0; i < MIN(first.mDataByteSize, 1024); i++) {
        if (samples[i] != 0) {
            NICEAudioTapProbe *probe = (__bridge NICEAudioTapProbe *)MTAudioProcessingTapGetStorage(tap);
            atomic_fetch_add_explicit(&probe->_audibleFrames, (uint64_t)*returned, memory_order_relaxed);
            return;
        }
    }
}

- (uint64_t)audibleFrames {
    return atomic_load_explicit(&_audibleFrames, memory_order_relaxed);
}

- (BOOL)attachToItem:(AVPlayerItem *)item track:(AVAssetTrack *)track {
    MTAudioProcessingTapCallbacks callbacks = {0};
    callbacks.version = kMTAudioProcessingTapCallbacksVersion_0;
    callbacks.clientInfo = (__bridge void *)self;
    callbacks.init = tapInit;
    callbacks.finalize = tapFinalize;
    callbacks.process = processAudio;
    MTAudioProcessingTapRef tap = NULL;
    if (MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                   kMTAudioProcessingTapCreationFlag_PostEffects, &tap) != noErr || !tap) return NO;
    AVMutableAudioMixInputParameters *parameters = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:track];
    parameters.audioTapProcessor = tap;
    AVMutableAudioMix *mix = [AVMutableAudioMix audioMix];
    mix.inputParameters = @[parameters];
    item.audioMix = mix;
    CFRelease(tap);
    return YES;
}
@end
