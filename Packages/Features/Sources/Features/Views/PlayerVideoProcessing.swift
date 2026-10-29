#if canImport(UIKit) && canImport(AVKit)
import AVFoundation
import CoreImage
import Observation
import PlayerKit
import QuartzCore
import StremioKit
import SwiftUI
import UIKit
import VideoToolbox

/// Machine-learning super resolution, on VideoToolbox's low-latency super-resolution scaler (iOS 26), for the AVPlayer engine and for
/// AetherEngine, which plays through an AVPlayer. Frames come from an `AVPlayerItemVideoOutput`, are scaled on the device's Neural
/// Engine/GPU, and are shown in a sample-buffer layer over the picture. It steps aside, saying why, when it cannot help: HDR (the scaler
/// takes 8-bit frames), video already at the size it is shown, a chip without the scaler, or frames that take longer than the frame
/// interval. What it did is kept for Settings (`UpscalingReport`).
@MainActor
@Observable
final class SuperResolutionRenderer {
    /// What it is doing, for the statistics panel.
    private(set) var status = "Off"
    private(set) var isRendering = false
    /// Scaled frames shown in the last second, while it runs.
    private(set) var framesPerSecond: Int?

    @ObservationIgnored let displayLayer = AVSampleBufferDisplayLayer()
    @ObservationIgnored private weak var player: AVPlayer?
    @ObservationIgnored private var item: AVPlayerItem?
    @ObservationIgnored private var output: AVPlayerItemVideoOutput?
    @ObservationIgnored private var pipeline: (any VideoScalingPipeline)?
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var displayScale: CGFloat = 1
    /// The picture's size, in pixels, when the scale was last decided; a new size (a rotation or zoom mode change) decides again.
    @ObservationIgnored private var decidedSize = CGSize.zero
    @ObservationIgnored private var activeFactor: Float?
    @ObservationIgnored private var wanted = false
    @ObservationIgnored private var blockedBySubtitles = false
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private weak var source: (any AVPlayerFrameSource)?
    @ObservationIgnored private var poll: Task<Void, Never>?
    /// What it did while it ran during this video, for the report.
    @ObservationIgnored private var ranSummary: String?
    @ObservationIgnored private var peakFramesPerSecond = 0
    @ObservationIgnored private var countedFrames = 0
    @ObservationIgnored private var countedSince = CACurrentMediaTime()

    static var isSupportedOnThisDevice: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return VTLowLatencySuperResolutionScalerConfiguration.isSupported
        #endif
    }

    init() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.isHidden = true
        displayLayer.backgroundColor = UIColor.clear.cgColor
    }

    /// `source` gives the AVPlayer playing the picture: AVPlayer itself, or AetherEngine's, which it swaps as it rebuilds its session, so
    /// it is followed every half second. The scale is decided from the size the picture is shown at (the display layer's, which its host
    /// lays out with the picture) and asked again whenever that size changes. Call again when anything changes; it starts or stops as
    /// needed.
    func update(source: (any AVPlayerFrameSource)?, wanted: Bool, displayScale: CGFloat, gravity: AVLayerVideoGravity,
                embeddedSubtitlesOn: Bool) {
        displayLayer.videoGravity = gravity
        self.displayScale = max(displayScale, 1)
        self.blockedBySubtitles = embeddedSubtitlesOn
        self.wanted = wanted
        self.source = source
        refresh()
        if wanted, source != nil {
            if poll == nil {
                poll = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(500))
                        guard let self else { return }
                        self.refresh()
                        self.countFrames()
                    }
                }
            }
        } else {
            poll?.cancel()
            poll = nil
        }
    }

    private func refresh() {
        let player = source?.framePlayer
        guard wanted, let player, !blockedBySubtitles else {
            let reason = !wanted ? "Off"
                : blockedBySubtitles ? "Paused while the stream's own subtitles are on (they are drawn under the scaled picture)"
                : "Not available: this player draws the picture itself (mpv, or AetherEngine's software path)"
            if pipeline != nil || status != reason { stop(reason: reason) }
            // Forgotten, so turning it on again starts afresh.
            self.player = nil
            item = nil
            observation = nil
            return
        }
        if engineSaysHDR, pipeline != nil {
            stop(reason: Self.hdrReason)
            return
        }
        guard player !== self.player || player.currentItem !== item else {
            // The same video: a picture laid out at a new size (the first layout, a rotation, a zoom mode change) decides the scale again.
            if pictureSize != decidedSize {
                if pipeline == nil {
                    prepare()
                } else {
                    recheckRunningScale()
                }
            }
            return
        }
        stop(reason: "Waiting for the video…")
        self.player = player
        item = player.currentItem
        observation = item?.observe(\.presentationSize, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.prepare() }
        }
    }

    /// Re-evaluates scale factor after rotation or zoom-mode layout changes without rebuilding when the target factor stays identical.
    private func recheckRunningScale() {
        #if !targetEnvironment(simulator)
        guard let item, item.presentationSize.width > 0, item.presentationSize.height > 0 else { return }
        let source = item.presentationSize
        let width = Int(source.width), height = Int(source.height)
        let shown = pictureSize
        guard shown.width > 0, shown.height > 0 else { return }
        decidedSize = shown
        let ratios = (shown.width / source.width, shown.height / source.height)
        let needed = displayLayer.videoGravity == .resizeAspect ? min(ratios.0, ratios.1) : max(ratios.0, ratios.1)
        if needed <= 1.15 {
            stop(reason: "Not needed: the \(width)×\(height) video is shown at \(Int(shown.width))×\(Int(shown.height)) or smaller")
            return
        }
        let factors = VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(frameWidth: width, frameHeight: height).sorted()
        let nextFactor = factors.first(where: { CGFloat($0) >= needed * 0.9 }) ?? factors.last
        if nextFactor != activeFactor {
            stop(reason: "Adjusting scale…")
            prepare()
        }
        #endif
    }

    /// The size the picture is shown at, in pixels: the display layer's frame, which its host keeps on the picture.
    private var pictureSize: CGSize {
        CGSize(width: (displayLayer.bounds.width * displayScale).rounded(), height: (displayLayer.bounds.height * displayScale).rounded())
    }

    /// The engine's word on HDR, for streams whose asset does not say (AetherEngine's, which can learn it only after loading).
    private var engineSaysHDR: Bool { (source as? any PictureOverlayHosting)?.pictureIsHDR == true }

    private static let hdrReason = "Not used for HDR video (the scaler takes 8-bit SDR frames)"

    /// Ends this video: what it did goes to Settings' report, when AI upscaling was chosen.
    func tearDown() {
        poll?.cancel()
        poll = nil
        source = nil
        // A video closed before anything was decided (still waiting for it) leaves the last report as it was.
        let undecided = status == "Off" || status.hasPrefix("Waiting")
        if wanted, let summary = ranSummary {
            UpscalingReport.record(undecided || isRendering ? summary : "\(summary). Then: \(status)")
        } else if wanted, !undecided {
            UpscalingReport.record(status)
        }
        stop(reason: "Off")
        observation = nil
        player = nil
        item = nil
        ranSummary = nil
        peakFramesPerSecond = 0
        wanted = false
    }

    private func prepare() {
        guard wanted, !blockedBySubtitles, pipeline == nil, let item, item.presentationSize.width > 0 else { return }
        #if targetEnvironment(simulator)
        stop(reason: "Not available in the simulator")
        #else
        guard Self.isSupportedOnThisDevice else {
            stop(reason: "This device has no machine-learning video scaler; the standard scaler is used")
            return
        }
        let size = pictureSize
        decidedSize = size
        guard size.width > 0, size.height > 0 else {
            stop(reason: "Waiting for the picture's size…")
            return
        }
        Task { [weak self] in
            guard let item = self?.item else { return }
            let isHDR = await Self.isHDR(item.asset)
            self?.start(item: item, isHDR: isHDR)
        }
        #endif
    }

    #if !targetEnvironment(simulator)
    private func start(item: AVPlayerItem, isHDR: Bool) {
        guard wanted, pipeline == nil, item === self.item else { return }
        guard !isHDR, !engineSaysHDR else {
            stop(reason: Self.hdrReason)
            return
        }
        let source = item.presentationSize
        let width = Int(source.width), height = Int(source.height)
        let shown = pictureSize
        decidedSize = shown
        // Fitted inside its frame, the picture is scaled by the smaller ratio; filling it (or a frame already the picture's shape), by
        // the larger.
        let ratios = (shown.width / source.width, shown.height / source.height)
        let needed = displayLayer.videoGravity == .resizeAspect ? min(ratios.0, ratios.1) : max(ratios.0, ratios.1)
        guard needed > 1.15 else {
            stop(reason: "Not needed: the \(width)×\(height) video is shown at \(Int(shown.width))×\(Int(shown.height)) or smaller")
            return
        }
        if let maximum = VTLowLatencySuperResolutionScalerConfiguration.maximumDimensions,
           width > Int(maximum.width) || height > Int(maximum.height) {
            stop(reason: "The video is larger than the scaler takes (\(Int(maximum.width))×\(Int(maximum.height)))")
            return
        }
        let factors = VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(frameWidth: width, frameHeight: height).sorted()
        guard let factor = factors.first(where: { CGFloat($0) >= needed * 0.9 }) ?? factors.last else {
            stop(reason: "The scaler has no scale for \(width)×\(height)")
            return
        }
        let configuration = VTLowLatencySuperResolutionScalerConfiguration(frameWidth: width, frameHeight: height, scaleFactor: factor)
        guard let pipeline = SuperResolutionPipeline(configuration: configuration, layer: displayLayer, onSlow: { [weak self] in
            Task { @MainActor in self?.stop(reason: "Paused: this device could not keep up with the frame rate") }
        }) else {
            stop(reason: "The scaler could not start")
            return
        }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: configuration.sourcePixelBufferAttributes)
        item.add(output)
        self.output = output
        self.pipeline = pipeline
        self.activeFactor = factor
        let link = CADisplayLink(target: DisplayLinkTarget { [weak self] link in self?.tick(link) }, selector: #selector(DisplayLinkTarget.fire(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        displayLayer.isHidden = false
        isRendering = true
        countedFrames = pipeline.shownFrames
        countedSince = CACurrentMediaTime()
        let scaled = "\(Int(Float(width) * factor))×\(Int(Float(height) * factor))"
        status = "On: ×\(factor.formatted()), \(width)×\(height) → \(scaled)"
        ranSummary = "Ran ×\(factor.formatted()): \(width)×\(height) → \(scaled)"
    }
    #endif

    private func tick(_ link: CADisplayLink) {
        guard let output, let pipeline else { return }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
        pipeline.submit(buffer, presentationTime: time, frameInterval: link.targetTimestamp - link.timestamp)
    }

    /// The scaled frames shown since the last count, as a rate: proof it is working, for Info and the report.
    private func countFrames() {
        guard let pipeline, isRendering else {
            if framesPerSecond != nil { framesPerSecond = nil }
            return
        }
        let now = CACurrentMediaTime()
        let shown = pipeline.shownFrames
        let elapsed = now - countedSince
        guard elapsed >= 0.9 else { return }
        let rate = Int((Double(shown - countedFrames) / elapsed).rounded())
        countedFrames = shown
        countedSince = now
        if framesPerSecond != rate { framesPerSecond = rate }
        if rate > peakFramesPerSecond, let summary = ranSummary?.components(separatedBy: ", up to ").first {
            peakFramesPerSecond = rate
            ranSummary = "\(summary), up to \(rate) frames a second"
        }
    }

    private func stop(reason: String) {
        link?.invalidate()
        link = nil
        if let output { item?.remove(output) }
        output = nil
        pipeline?.end()
        pipeline = nil
        activeFactor = nil
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true) {}
        displayLayer.isHidden = true
        isRendering = false
        if framesPerSecond != nil { framesPerSecond = nil }
        status = reason
    }

    private static func isHDR(_ asset: AVAsset) async -> Bool {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let format = (try? await track.load(.formatDescriptions))?.first else { return false }
        let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        return transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
            || transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
    }
}

/// What AI upscaling did on the last video played with it chosen, kept for Settings › Player. Saved in the standard defaults, as a line
/// and a date, so it is still there after a relaunch.
enum UpscalingReport {
    static let summaryKey = "upscaling.lastReport"
    static let dateKey = "upscaling.lastReportDate"

    static func record(_ summary: String) {
        UserDefaults.standard.set(summary, forKey: summaryKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: dateKey)
    }
}

/// CADisplayLink retains its target; this keeps the renderer out of that cycle. The link runs on the main run loop.
@MainActor
private final class DisplayLinkTarget: NSObject {
    let action: @MainActor (CADisplayLink) -> Void
    init(_ action: @escaping @MainActor (CADisplayLink) -> Void) { self.action = action }
    @objc func fire(_ link: CADisplayLink) { action(link) }
}

/// The hardware-only scaler is not declared by the simulator SDK. Its renderer
/// keeps a protocol reference, while the implementation compiles only on device.
private protocol VideoScalingPipeline: AnyObject {
    func submit(_ source: CVPixelBuffer, presentationTime: CMTime, frameInterval: CFTimeInterval)
    func end()
    /// Scaled frames handed to the display layer so far.
    var shownFrames: Int { get }
}

#if !targetEnvironment(simulator)
/// The scaler session and its buffers, used off the main thread. One frame in flight at a time: a frame that arrives while one is being
/// scaled is dropped, and a run of frames slower than the frame interval ends the session.
private final class SuperResolutionPipeline: VideoScalingPipeline, @unchecked Sendable {
    private let processor = VTFrameProcessor()
    private let pool: CVPixelBufferPool
    private let renderer: AVSampleBufferVideoRenderer
    private let onSlow: @Sendable () -> Void
    private let lock = NSLock()
    private var busy = false
    private var slowFrames = 0
    private var ended = false
    private var shown = 0

    var shownFrames: Int { lock.withLock { shown } }

    @MainActor
    init?(configuration: VTLowLatencySuperResolutionScalerConfiguration, layer: AVSampleBufferDisplayLayer, onSlow: @escaping @Sendable () -> Void) {
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary,
                                configuration.destinationPixelBufferAttributes as CFDictionary, &pool)
        guard let pool, (try? processor.startSession(configuration: configuration)) != nil else { return nil }
        self.pool = pool
        self.renderer = layer.sampleBufferRenderer
        self.onSlow = onSlow
    }

    func submit(_ source: CVPixelBuffer, presentationTime: CMTime, frameInterval: CFTimeInterval) {
        let accepted = lock.withLock { () -> Bool in
            guard !busy, !ended else { return false }
            busy = true
            return true
        }
        guard accepted else { return }
        var destination: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination)
        guard let destination, let sourceFrame = VTFrameProcessorFrame(buffer: source, presentationTimeStamp: presentationTime),
              let destinationFrame = VTFrameProcessorFrame(buffer: destination, presentationTimeStamp: presentationTime) else {
            lock.withLock { busy = false }
            return
        }
        let started = CACurrentMediaTime()
        let parameters = VTLowLatencySuperResolutionScalerParameters(sourceFrame: sourceFrame, destinationFrame: destinationFrame)
        // The buffer belongs to this frame alone until it is enqueued.
        let output = UncheckedBuffer(buffer: destination)
        processor.process(parameters: parameters) { [self] _, error in
            let elapsed = CACurrentMediaTime() - started
            let slow = lock.withLock { () -> Bool in
                busy = false
                slowFrames = elapsed > max(frameInterval, 1.0 / 120) * 0.9 ? slowFrames + 1 : 0
                return slowFrames >= 45
            }
            if slow {
                onSlow()
                return
            }
            guard error == nil, let sample = Self.sampleBuffer(output.buffer, time: presentationTime) else { return }
            renderer.enqueue(sample)
            lock.withLock { shown += 1 }
        }
    }

    func end() {
        lock.withLock { ended = true }
        processor.endSession()
    }

    private static func sampleBuffer(_ buffer: CVPixelBuffer, time: CMTime) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: format, sampleTiming: &timing,
                                                 sampleBufferOut: &sample)
        guard let sample else { return nil }
        // Shown as soon as it is ready: the frame was due when it was pulled from the player.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

private struct UncheckedBuffer: @unchecked Sendable {
    let buffer: CVPixelBuffer
}
#endif

/// Original frames sampled twice a second: persistent encoded bars for geometry, plus AVPlayer edge colours for ambient mode.
/// mpv supplies native source screenshots. Aether's software path preserves the complete frame when samples are unavailable.
@MainActor
@Observable
final class PictureSampler {
    /// Left, right, top and bottom edge colours, while ambient mode is on.
    private(set) var colours: [Color] = []

    @ObservationIgnored private weak var source: (any AVPlayerFrameSource)?
    @ObservationIgnored private weak var item: AVPlayerItem?
    @ObservationIgnored private var sourceRevision: Int?
    @ObservationIgnored private var output: AVPlayerItemVideoOutput?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var detector = VideoBlackBars()
    @ObservationIgnored private var detectedAspect: Double?
    @ObservationIgnored private var ambient = false
    @ObservationIgnored var onPictureAspect: ((Double?) -> Void)?

    /// Quarter-HD (480×270) gives ~5.3 clean rows for 1.85:1's ~21px bars on 1080p without excessive memory or CPU work.
    private static let width = 480, height = 270

    func update(source: (any AVPlayerFrameSource)?, ambient: Bool) {
        self.ambient = ambient
        if !ambient, !colours.isEmpty { colours = [] }
        guard let source else {
            let hadAspect = detectedAspect != nil
            stop()
            if hadAspect { onPictureAspect?(nil) }
            return
        }
        if source !== self.source {
            let hadAspect = detectedAspect != nil
            stop()
            self.source = source
            self.sourceRevision = source.frameSourceRevision
            if hadAspect { onPictureAspect?(nil) }
        }
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.sample()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        detach()
        source = nil
        sourceRevision = nil
        detector.reset()
        detectedAspect = nil
        if !colours.isEmpty { colours = [] }
    }

    private func detach() {
        releaseOutput()
        item = nil
    }

    /// Takes the frame copy off the video. A video output makes the player convert every frame for it, which a UHD remux can feel.
    private func releaseOutput() {
        if let output { item?.remove(output) }
        output = nil
    }

    private func sample() {
        guard let source else { return }
        if sourceRevision != source.frameSourceRevision {
            detach()
            sourceRevision = source.frameSourceRevision
            detector.reset()
            if !colours.isEmpty { colours = [] }
            if detectedAspect != nil { detectedAspect = nil; onPictureAspect?(nil) }
        }
        // Asked again every time: AetherEngine swaps its AVPlayer item as it rebuilds its session within the same load.
        guard let item = source.framePlayer?.currentItem else {
            detach()
            if let native = source as? OriginalPictureSampling, let sample = native.sampleOriginalPicture() {
                _ = detect(sample.frame, aspect: sample.aspect)
            }
            return
        }
        if item !== self.item || output == nil {
            if item !== self.item { detach() }
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Self.width, kCVPixelBufferHeightKey as String: Self.height,
            ])
            item.add(output)
            self.item = item
            self.output = output
        }
        guard let output else { return }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
        read(buffer)
    }

    private func detect(_ frame: VideoLumaFrame, aspect: Double) -> Double? {
        let detected = detector.sample(frame, pictureAspect: aspect)
        if detected != detectedAspect { detectedAspect = detected; onPictureAspect?(detected) }
        return detected
    }

    private func read(_ buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 2, height > 2 else { return }
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        func luma(_ x: Int, _ y: Int) -> Int {
            let p = pixels + y * stride + x * 4
            return (Int(p[2]) * 54 + Int(p[1]) * 183 + Int(p[0]) * 19) >> 8
        }
        let frame = VideoLumaFrame(width: width, height: height,
                                   pixels: (0..<(width * height)).map { UInt8(luma($0 % width, $0 / width)) })
        let presented = item?.presentationSize ?? .zero
        let aspect = presented.width > 0 && presented.height > 0 ? Double(presented.width / presented.height) : Double(width) / Double(height)
        let detected = detect(frame, aspect: aspect)
        guard ambient else { return }
        // Ambient colours use the same confirmed bars as display geometry, rather than a dark scene's temporary edges.
        let kept = VideoGeometry.keptFraction(aspect: aspect, crop: detected)
        let left = Int((kept.minX * Double(width)).rounded()), right = Int(((1 - kept.maxX) * Double(width)).rounded())
        let top = Int((kept.minY * Double(height)).rounded()), bottom = Int(((1 - kept.maxY) * Double(height)).rounded())
        // The colours just inside this frame's picture, not of its bars.
        let x0 = min(left, width - 1), x1 = max(x0 + 1, width - right)
        let y0 = min(top, height - 1), y1 = max(y0 + 1, height - bottom)
        func average(_ xs: Range<Int>, _ ys: Range<Int>) -> Color {
            var (r, g, b, n) = (0, 0, 0, 0)
            for y in ys { for x in xs { let p = pixels + y * stride + x * 4; b += Int(p[0]); g += Int(p[1]); r += Int(p[2]); n += 1 } }
            guard n > 0 else { return .black }
            return Color(red: Double(r) / Double(n * 255), green: Double(g) / Double(n * 255), blue: Double(b) / Double(n * 255))
        }
        let edge = max(1, (x1 - x0) / 6), band = max(1, (y1 - y0) / 5)
        colours = [average(x0..<x0 + edge, y0..<y1), average(x1 - edge..<x1, y0..<y1),
                   average(x0..<x1, y0..<y0 + band), average(x0..<x1, y1 - band..<y1)]
    }
}

/// The glow behind the picture: each edge's colour, blurred far out. Black when there is nothing to sample.
struct AmbientGlow: View {
    let colours: [Color]

    var body: some View {
        GeometryReader { proxy in
            if colours.count == 4 {
                ZStack {
                    Rectangle().fill(colours[0]).frame(width: proxy.size.width * 0.45).frame(maxWidth: .infinity, alignment: .leading)
                    Rectangle().fill(colours[1]).frame(width: proxy.size.width * 0.45).frame(maxWidth: .infinity, alignment: .trailing)
                    Rectangle().fill(colours[2]).frame(height: proxy.size.height * 0.4).frame(maxHeight: .infinity, alignment: .top)
                    Rectangle().fill(colours[3]).frame(height: proxy.size.height * 0.4).frame(maxHeight: .infinity, alignment: .bottom)
                }
                .blur(radius: 80)
                .opacity(0.55)
                .animation(.easeInOut(duration: 0.8), value: colours)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif
