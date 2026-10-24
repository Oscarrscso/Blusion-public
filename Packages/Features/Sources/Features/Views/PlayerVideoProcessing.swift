#if canImport(UIKit) && canImport(AVKit)
import AVFoundation
import CoreImage
import Observation
import QuartzCore
import SwiftUI
import UIKit
import VideoToolbox

/// Machine-learning super resolution for the AVPlayer engine, on VideoToolbox's low-latency super-resolution scaler (iOS 26). Frames come
/// from an `AVPlayerItemVideoOutput`, are scaled on the device's Neural Engine/GPU, and are shown in a sample-buffer layer over the player
/// layer. It steps aside, saying why, when it cannot help: HDR (the scaler takes 8-bit frames), video already at screen resolution, a
/// chip without the scaler, or frames that take longer than the frame interval.
@MainActor
@Observable
final class SuperResolutionRenderer {
    /// What it is doing, for the statistics panel.
    private(set) var status = "Off"
    private(set) var isRendering = false

    @ObservationIgnored let displayLayer = AVSampleBufferDisplayLayer()
    @ObservationIgnored private weak var player: AVPlayer?
    @ObservationIgnored private var item: AVPlayerItem?
    @ObservationIgnored private var output: AVPlayerItemVideoOutput?
    @ObservationIgnored private var pipeline: SuperResolutionPipeline?
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var targetSize = CGSize.zero
    @ObservationIgnored private var wanted = false
    @ObservationIgnored private var blockedBySubtitles = false
    @ObservationIgnored private var observation: NSKeyValueObservation?

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
        displayLayer.backgroundColor = UIColor.black.cgColor
    }

    /// `targetSize` is the layer's size in pixels. Call again when anything changes; it starts or stops as needed.
    func update(player: AVPlayer?, wanted: Bool, targetSize: CGSize, gravity: AVLayerVideoGravity, embeddedSubtitlesOn: Bool) {
        displayLayer.videoGravity = gravity
        self.targetSize = targetSize
        self.blockedBySubtitles = embeddedSubtitlesOn
        let changedPlayer = player !== self.player || player?.currentItem !== item
        self.wanted = wanted
        if !wanted || player == nil || embeddedSubtitlesOn {
            stop(reason: !wanted ? "Off" : embeddedSubtitlesOn ? "Paused while the stream's own subtitles are on (they are drawn under the scaled picture)" : "Off")
            self.player = player
            return
        }
        if changedPlayer || pipeline == nil {
            stop(reason: "Waiting for the video…")
            self.player = player
            item = player?.currentItem
            observation = item?.observe(\.presentationSize, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.prepare() }
            }
        }
    }

    func tearDown() {
        stop(reason: "Off")
        observation = nil
        player = nil
        item = nil
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
        guard !isHDR else {
            stop(reason: "Not used for HDR video (the scaler takes 8-bit SDR frames)")
            return
        }
        let source = item.presentationSize
        let width = Int(source.width), height = Int(source.height)
        let needed = max(targetSize.width / source.width, targetSize.height / source.height)
        guard needed > 1.15 else {
            stop(reason: "Not needed: the video is already at the screen's resolution")
            return
        }
        if let maximum = VTLowLatencySuperResolutionScalerConfiguration.maximumDimensions,
           width > Int(maximum.width) || height > Int(maximum.height) {
            stop(reason: "The video is larger than the scaler takes (\(maximum.width)×\(maximum.height))")
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
        let link = CADisplayLink(target: DisplayLinkTarget { [weak self] link in self?.tick(link) }, selector: #selector(DisplayLinkTarget.fire(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        displayLayer.isHidden = false
        isRendering = true
        status = "AI super resolution ×\(factor.formatted()) (VideoToolbox): \(width)×\(height) → \(Int(Float(width) * factor))×\(Int(Float(height) * factor))"
    }
    #endif

    private func tick(_ link: CADisplayLink) {
        guard let output, let pipeline else { return }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
        pipeline.submit(buffer, presentationTime: time, frameInterval: link.targetTimestamp - link.timestamp)
    }

    private func stop(reason: String) {
        link?.invalidate()
        link = nil
        if let output { item?.remove(output) }
        output = nil
        pipeline?.end()
        pipeline = nil
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true) {}
        displayLayer.isHidden = true
        isRendering = false
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

/// CADisplayLink retains its target; this keeps the renderer out of that cycle. The link runs on the main run loop.
@MainActor
private final class DisplayLinkTarget: NSObject {
    let action: @MainActor (CADisplayLink) -> Void
    init(_ action: @escaping @MainActor (CADisplayLink) -> Void) { self.action = action }
    @objc func fire(_ link: CADisplayLink) { action(link) }
}

/// The scaler session and its buffers, used off the main thread. One frame in flight at a time: a frame that arrives while one is being
/// scaled is dropped, and a run of frames slower than the frame interval ends the session.
private final class SuperResolutionPipeline: @unchecked Sendable {
    private let processor = VTFrameProcessor()
    private let pool: CVPixelBufferPool
    private let renderer: AVSampleBufferVideoRenderer
    private let onSlow: @Sendable () -> Void
    private let lock = NSLock()
    private var busy = false
    private var slowFrames = 0
    private var ended = false

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

/// Ambient mode: the colours at the picture's edges, sampled twice a second from a tiny copy of the frame, for a glow around
/// letterboxed video. Reads AVPlayer frames only; the fallback engine draws straight to the screen, so there is nothing to sample there.
@MainActor
@Observable
final class AmbientSampler {
    /// Left, right, top and bottom edge colours.
    private(set) var colours: [Color] = []

    @ObservationIgnored private weak var item: AVPlayerItem?
    @ObservationIgnored private var output: AVPlayerItemVideoOutput?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let context = CIContext(options: [.workingColorSpace: NSNull()])

    func update(player: AVPlayer?, enabled: Bool) {
        guard enabled, let item = player?.currentItem else {
            stop()
            return
        }
        guard item !== self.item else { return }
        stop()
        self.item = item
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 18,
        ])
        item.add(output)
        self.output = output
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.sample()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        if let output { item?.remove(output) }
        output = nil
        item = nil
        colours = []
    }

    private func sample() {
        guard let output else { return }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        func average(_ xs: Range<Int>, _ ys: Range<Int>) -> Color {
            var (r, g, b, n) = (0, 0, 0, 0)
            for y in ys { for x in xs { let p = pixels + y * stride + x * 4; b += Int(p[0]); g += Int(p[1]); r += Int(p[2]); n += 1 } }
            guard n > 0 else { return .black }
            return Color(red: Double(r) / Double(n * 255), green: Double(g) / Double(n * 255), blue: Double(b) / Double(n * 255))
        }
        let edge = max(1, width / 6), band = max(1, height / 5)
        colours = [average(0..<edge, 0..<height), average(width - edge..<width, 0..<height),
                   average(0..<width, 0..<band), average(0..<width, height - band..<height)]
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
