#if canImport(VideoToolbox) && canImport(CoreMedia)
import CoreMedia
import Foundation
import VideoToolbox

/// What this device decodes in hardware, read once per launch. AVPlayer decodes a codec only where the hardware can (ADR-006).
public enum AVHardware {
    /// True on chips with hardware AV1 decode (A17 Pro, M3 and later). Elsewhere AV1 goes to the fallback engine.
    public static let decodesAV1InHardware: Bool = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
}
#endif
