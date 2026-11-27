#import "DirectHEVCReader.h"
#import <VideoToolbox/VideoToolbox.h>
#import <math.h>

static NSError *DecodeError(NSString *stage, OSStatus code) {
    return [NSError errorWithDomain:@"NiceVideos.DirectHEVC" code:code
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ (%d)", stage, (int)code]}];
}

// AVAssetReader returns compressed media timestamps and may attach an edit
// mapping. AVPlayer's clock and all seek/presentation decisions use output time.
static CMTime OutputPTS(CMSampleBufferRef sample) {
    CMTime time = CMSampleBufferGetOutputPresentationTimeStamp(sample);
    return CMTIME_IS_NUMERIC(time) ? time : CMSampleBufferGetPresentationTimeStamp(sample);
}

static CMTime OutputDTS(CMSampleBufferRef sample) {
    CMTime time = CMSampleBufferGetOutputDecodeTimeStamp(sample);
    return CMTIME_IS_NUMERIC(time) ? time : OutputPTS(sample);
}

static BOOL IsSync(CMSampleBufferRef sample) {
    CMBlockBufferRef data = CMSampleBufferGetDataBuffer(sample);
    if (!data || CMSampleBufferGetNumSamples(sample) != 1) return NO;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, false);
    if (attachments && CFArrayGetCount(attachments)) {
        CFDictionaryRef flags = CFArrayGetValueAtIndex(attachments, 0);
        if (CFDictionaryGetValue(flags, kCMSampleAttachmentKey_NotSync) != kCFBooleanTrue) return YES;
    }
    // Some unrecognised HEVC sample entries have incomplete dependency flags.
    // Inspect NAL headers only; IRAP access units start an independent decode.
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample);
    if (!format) return NO;
    NSDictionary *atoms = (__bridge NSDictionary *)CMFormatDescriptionGetExtension(format,
                              kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms);
    NSData *config = atoms[@"hvcC"];
    if (![config isKindOfClass:NSData.class] || config.length < 23) {
        return CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC && !attachments;
    }
    const uint8_t *record = config.bytes;
    size_t header = (record[21] & 3) + 1;
    size_t at = 0, total = CMBlockBufferGetDataLength(data);
    for (int i = 0; i < 256 && at + header + 2 <= total; i++) {
        uint8_t prefix[6];
        if (CMBlockBufferCopyDataBytes(data, at, header + 2, prefix) != noErr) return NO;
        size_t size = 0;
        for (size_t j = 0; j < header; j++) size = (size << 8) | prefix[j];
        at += header;
        if (size < 2 || size > total - at) return NO;
        unsigned type = (prefix[header] >> 1) & 63;
        if (type < 32) return type >= 16 && type <= 21;
        at += size;
    }
    return NO;
}

// hev1 can carry additional parameter sets in-band. Preserve its NAL units unchanged.
// Only build an hvc1 description from an actual HEVC configuration record containing
// VPS/SPS/PPS. CoreMedia validates those parameter sets and derives dimensions.
static CMVideoFormatDescriptionRef CopyDecoderFormat(CMVideoFormatDescriptionRef source) {
    FourCharCode codec = CMFormatDescriptionGetMediaSubType(source);
    if (codec == kCMVideoCodecType_HEVC) return (CMVideoFormatDescriptionRef)CFRetain(source);
    if (codec != 'hev1') return NULL;
    NSDictionary *extensions = (__bridge NSDictionary *)CMFormatDescriptionGetExtensions(source);
    NSData *config = extensions[(__bridge NSString *)kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms][@"hvcC"];
    if (![config isKindOfClass:NSData.class] || config.length < 23) return NULL;
    const uint8_t *p = config.bytes;
    if (p[0] != 1) return NULL;
    int headerLength = (p[21] & 3) + 1;
    size_t at = 23, count = 0;
    const uint8_t *sets[64];
    size_t sizes[64];
    int types = 0;
    for (int i = 0; i < p[22]; i++) {
        if (at + 3 > config.length) return NULL;
        int type = p[at++] & 63;
        int n = (p[at] << 8) | p[at+1];
        at += 2;
        for (int j = 0; j < n; j++) {
            if (at + 2 > config.length) return NULL;
            size_t length = (p[at] << 8) | p[at+1];
            at += 2;
            if (length < 2 || length > config.length - at || ((p[at] >> 1) & 63) != type) return NULL;
            if (type >= 32 && type <= 34) {
                if (count >= 64) return NULL;
                sets[count] = p + at;
                sizes[count++] = length;
                types |= 1 << (type - 32);
            }
            at += length;
        }
    }
    if (types != 7) return NULL;
    CMVideoFormatDescriptionRef result = NULL;
    NSMutableDictionary *color = [NSMutableDictionary dictionary];
    for (NSString *key in @[(__bridge NSString *)kCMFormatDescriptionExtension_ColorPrimaries,
                             (__bridge NSString *)kCMFormatDescriptionExtension_TransferFunction,
                             (__bridge NSString *)kCMFormatDescriptionExtension_YCbCrMatrix,
                             (__bridge NSString *)kCMFormatDescriptionExtension_FullRangeVideo]) {
        if (extensions[key]) color[key] = extensions[key];
    }
    if (CMVideoFormatDescriptionCreateFromHEVCParameterSets(NULL, count, sets, sizes, headerLength,
            (__bridge CFDictionaryRef)color, &result) != noErr)
        return NULL;
    return result;
}

@implementation DirectHEVCReader {
    AVAssetTrack *_track;
    AVAsset *_asset;
    BOOL _requireHardware;
    AVAssetReader *_reader;
    AVAssetReaderTrackOutput *_output;
    CMSampleBufferRef _next;
    CMFormatDescriptionRef _sourceFormat;
    CMVideoFormatDescriptionRef _decoderFormat;
    VTDecompressionSessionRef _session;
    NSMutableArray *_pictures;
    double _lastPTS;
    size_t _surfaceLimit;
    CMVideoDimensions _sourceDimensions;
}

- (instancetype)initWithTrack:(AVAssetTrack *)track asset:(AVAsset *)asset requireHardware:(BOOL)requireHardware {
    if ((self = [super init])) {
        _track = track;
        _asset = asset;
        _requireHardware = requireHardware;
        _pictures = [NSMutableArray new];
        _lastPTS = -INFINITY;
        _surfaceLimit = 2;
    }
    return self;
}

- (BOOL)startAt:(double)target error:(NSError **)error {
    // A compressed reader may deliver preroll or begin mid-GOP. Re-open an
    // indexed time range around the requested position until it contains a sync
    // sample preceding the target. Never decode from zero after a long seek.
    double lookbacks[] = {0, 1, 4, 16};
    NSUInteger packets = 0, syncs = 0;
    double firstRaw = NAN, firstOutput = NAN, firstDecode = NAN, lastOutput = NAN;
    double lastStart = 0;
    for (size_t attempt = 0; attempt < sizeof(lookbacks)/sizeof(*lookbacks); attempt++) {
        [_reader cancelReading];
        _reader = [[AVAssetReader alloc] initWithAsset:_asset error:error];
        if (!_reader) return NO;
        _output = [[AVAssetReaderTrackOutput alloc] initWithTrack:_track outputSettings:nil];
        _output.alwaysCopiesSampleData = NO;
        if (![_reader canAddOutput:_output]) {
            *error = DecodeError(@"cannot add compressed HEVC track output", -2);
            return NO;
        }
        [_reader addOutput:_output];
        double start = MAX(target - lookbacks[attempt], 0);
        lastStart = start;
        if (start > 0) _reader.timeRange = CMTimeRangeMake(CMTimeMakeWithSeconds(start, 60000), kCMTimePositiveInfinity);
        if (![_reader startReading]) {
            *error = _reader.error ?: DecodeError(@"compressed reader", -1);
            return NO;
        }
        // Bound malformed timestamps/long GOP scans as well as the time range.
        for (int packet = 0; packet < 1024; packet++) {
            _next = [_output copyNextSampleBuffer];
            if (!_next) break;
            double pts = CMTimeGetSeconds(OutputPTS(_next));
            if (packets++ == 0) {
                firstRaw = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(_next));
                firstOutput = pts;
                firstDecode = CMTimeGetSeconds(OutputDTS(_next));
            }
            lastOutput = pts;
            BOOL sync = IsSync(_next);
            if (sync) syncs++;
            // The first access unit at the physical start is valid preroll
            // even when its PTS is positive (B frames, an empty head edit).
            // The output clock below still holds this picture until it is due.
            if (sync && isfinite(pts) && (pts <= target + 0.002 || (start == 0 && packet == 0))) return YES;
            CFRelease(_next);
            _next = NULL;
            if (pts > target + 0.25) break;
        }
        if (start == 0) break;
    }
    NSString *detail = [NSString stringWithFormat:
        @"no nearby HEVC sync sample: target=%.3f rangeStart=%.3f packets=%lu syncs=%lu firstPTS=%.3f firstOutputPTS=%.3f firstOutputDTS=%.3f lastOutputPTS=%.3f reader=%ld",
        target, lastStart, (unsigned long)packets, (unsigned long)syncs, firstRaw, firstOutput, firstDecode,
        lastOutput, (long)_reader.status];
    *error = _reader.error ?: DecodeError(detail, -2);
    return NO;
}

- (BOOL)openSession:(CMFormatDescriptionRef)source error:(NSError **)error {
    _sourceFormat = (CMFormatDescriptionRef)CFRetain(source);
    _decoderFormat = CopyDecoderFormat(source);
    if (!_decoderFormat) {
        *error = DecodeError(@"unsupported HEVC configuration", -3);
        return NO;
    }
    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(_decoderFormat);
    if (dims.width <= 0 || dims.height <= 0) {
        *error = DecodeError(@"invalid HEVC dimensions", -4);
        return NO;
    }
    _sourceDimensions = dims;
    double scale = MIN(1, 1920.0/MAX(dims.width, dims.height));
    int width = MAX(2, ((int)(dims.width * scale)) & ~1);
    int height = MAX(2, ((int)(dims.height * scale)) & ~1);
    NSDictionary *attrs = @{
        (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}, (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES
    };
    NSDictionary *specification = _requireHardware ? @{ (__bridge NSString *)kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: @YES } : nil;
    OSStatus status = VTDecompressionSessionCreate(NULL, _decoderFormat, (__bridge CFDictionaryRef)specification,
                        (__bridge CFDictionaryRef)attrs, NULL, &_session);
    if (status != noErr) {
        *error = DecodeError(@"HEVC decoder session", status);
        return NO;
    }
    VTSessionSetProperty(_session, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);
    if (_requireHardware && _track.nominalFrameRate > 30) {
        NSNumber *fraction = @(30.0 / _track.nominalFrameRate);
        VTSessionSetProperty(_session, kVTDecompressionPropertyKey_ReducedFrameDelivery, (__bridge CFNumberRef)fraction);
    }
    if (scale < 1) {
        NSDictionary *reduced = @{(__bridge NSString *)kVTDecompressionResolutionKey_Width: @(width),
                                  (__bridge NSString *)kVTDecompressionResolutionKey_Height: @(height)};
        VTSessionSetProperty(_session, kVTDecompressionPropertyKey_ReducedResolutionDecode, (__bridge CFDictionaryRef)reduced);
    }
    return YES;
}

- (BOOL)decode:(CMSampleBufferRef)source clock:(double)clock error:(NSError **)error {
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(source);
    if (!_session && (!format || ![self openSession:format error:error])) {
        if (!*error) *error = DecodeError(@"missing HEVC format", -5);
        return NO;
    }
    if (!format || !CFEqual(format, _sourceFormat) || CMSampleBufferGetNumSamples(source) != 1 || !CMSampleBufferGetDataBuffer(source)) {
        *error = DecodeError(@"changed or unsupported HEVC sample format", -6);
        return NO;
    }
    CMSampleTimingInfo timing;
    OSStatus status = CMSampleBufferGetSampleTimingInfo(source, 0, &timing);
    CMSampleBufferRef packet = NULL;
    if (status == noErr && _sourceFormat != _decoderFormat) {
        size_t size = CMSampleBufferGetSampleSize(source, 0);
        status = CMSampleBufferCreateReady(NULL, CMSampleBufferGetDataBuffer(source), _decoderFormat, 1, 1, &timing, 1, &size, &packet);
    }
    if (status != noErr) {
        *error = DecodeError(@"compressed sample timing", status);
        return NO;
    }
    CMTime outputPTS = OutputPTS(source);
    double pts = CMTimeGetSeconds(outputPTS);
    // Decode references even when their presentation deadlines have passed.
    VTDecodeFrameFlags flags = pts < clock - 0.15 ? kVTDecodeFrame_DoNotOutputFrame : 0;
    __block OSStatus delivery = noErr;
    status = VTDecompressionSessionDecodeFrameWithOutputHandler(_session, packet ?: source, flags, NULL,
        ^(OSStatus result, VTDecodeInfoFlags info, CVImageBufferRef image, CMTime timestamp, CMTime duration) {
            delivery = result;
            if (result != noErr || !image || (info & kVTDecodeInfo_FrameDropped)) return;
            size_t w = CVPixelBufferGetWidth(image), h = CVPixelBufferGetHeight(image);
            if (CVPixelBufferGetPixelFormatType(image) != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                w == 0 || h == 0 || w > self->_sourceDimensions.width || h > self->_sourceDimensions.height ||
                MAX(w, h) > 8192 || w*h > 36u*1024u*1024u ||
                !CVPixelBufferGetIOSurface(image) || !CMTIME_IS_NUMERIC(outputPTS)) {
                delivery = -7;
                return;
            }
            // Reduced decode is optional. Native 8K IOSurfaces can be mapped
            // directly; only retain as many as fit in a 128 MiB lookahead.
            size_t bytes = MAX(CVPixelBufferGetDataSize(image), w*h*3/2);
            self->_surfaceLimit = MAX(1, MIN(2, (128u*1024u*1024u)/bytes));
            CMVideoFormatDescriptionRef imageFormat = NULL;
            CMSampleBufferRef picture = NULL;
            // The output handler belongs to this input packet. Its timestamp
            // may still be raw media PTS. Publish the asset-timeline timestamp
            // of this packet (including any edit offset), including B frames.
            CMSampleTimingInfo outputTime = {duration, outputPTS, kCMTimeInvalid};
            delivery = CMVideoFormatDescriptionCreateForImageBuffer(NULL, image, &imageFormat);
            if (delivery == noErr) delivery = CMSampleBufferCreateReadyWithImageBuffer(NULL, image, imageFormat, &outputTime, &picture);
            if (imageFormat) CFRelease(imageFormat);
            if (picture) {
                [self->_pictures addObject:CFBridgingRelease(picture)];
                [self trimPicturesAt:clock];
            }
        });
    if (packet) CFRelease(packet);
    if (status != noErr || delivery != noErr) {
        *error = DecodeError(@"HEVC picture delivery", status ?: delivery);
        return NO;
    }
    return YES;
}

// Keep the latest due picture and then the nearest future pictures. A future
// P-frame anchor never prevents the next ready B-frame from entering the queue.
- (void)trimPicturesAt:(double)clock {
    if (_pictures.count <= _surfaceLimit) return;
    NSInteger earliest = 0, latest = 0, dueCount = 0;
    double minTime = INFINITY, maxTime = -INFINITY;
    for (NSInteger i = 0; i < _pictures.count; i++) {
        CMSampleBufferRef sample = (__bridge CMSampleBufferRef)_pictures[i];
        double pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample));
        if (pts < minTime) { minTime = pts; earliest = i; }
        if (pts > maxTime) { maxTime = pts; latest = i; }
        if (pts <= clock + 0.002) dueCount++;
    }
    [_pictures removeObjectAtIndex:dueCount > 1 ? earliest : latest];
}

- (nullable CMSampleBufferRef)copyPictureAt:(double)seconds {
    NSError *error = nil;
    CMSampleBufferRef picture = [self readPictureAt:seconds error:&error];
    _error = error;
    return picture;
}

- (nullable CMSampleBufferRef)readPictureAt:(double)seconds error:(NSError **)error {
    if (!isfinite(seconds) || seconds < 0) return NULL;
    if (!_reader && ![self startAt:seconds error:error]) return NULL;
    // Retain two NV12 surfaces and one packet. If the queue is full, keep
    // decoding packets whose DTS is already due: their PTS may precede an
    // anchor already queued. trimPicturesAt then evicts a more distant frame.
    for (int i = 0; i < 12; i++) {
        if (!_next) _next = [_output copyNextSampleBuffer];
        if (!_next) {
            if (_reader.status == AVAssetReaderStatusFailed) *error = _reader.error ?: DecodeError(@"compressed read", -8);
            break;
        }
        CMTime time = OutputDTS(_next);
        double lookahead = _pictures.count < _surfaceLimit ? 0.1 : 0;
        if (CMTimeGetSeconds(time) > seconds + lookahead) break;
        BOOL ok = [self decode:_next clock:seconds error:error];
        CFRelease(_next);
        _next = NULL;
        if (!ok) return NULL;
    }
    CMSampleBufferRef best = NULL;
    double bestTime = _lastPTS;
    for (NSInteger i = _pictures.count - 1; i >= 0; i--) {
        CMSampleBufferRef entry = (__bridge CMSampleBufferRef)_pictures[i];
        double t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(entry));
        if (t > seconds + 0.002) continue;
        if (t > bestTime && t >= seconds - 0.25) {
            if (best) CFRelease(best);
            best = (CMSampleBufferRef)CFRetain(entry);
            bestTime = t;
        }
        [_pictures removeObjectAtIndex:i];
    }
    _lastPTS = bestTime;
    return best;
}

- (void)close {
    [_reader cancelReading];
    _reader = nil;
    _output = nil;
    if (_session) { VTDecompressionSessionInvalidate(_session); CFRelease(_session); _session = NULL; }
    if (_next) { CFRelease(_next); _next = NULL; }
    if (_sourceFormat) { CFRelease(_sourceFormat); _sourceFormat = NULL; }
    if (_decoderFormat) { CFRelease(_decoderFormat); _decoderFormat = NULL; }
    [_pictures removeAllObjects];
    _lastPTS = -INFINITY;
    _surfaceLimit = 2;
}
- (void)dealloc { [self close]; }
@end
