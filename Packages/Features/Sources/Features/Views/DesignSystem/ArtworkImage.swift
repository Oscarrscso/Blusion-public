#if canImport(UIKit)
import SwiftUI
import UIKit

private struct ArtworkLoadingSpinnerKey: EnvironmentKey { static let defaultValue = false }

private struct ArtworkPriorityKey: EnvironmentKey { static let defaultValue: TaskPriority = .medium }
private struct ArtworkOrderKey: EnvironmentKey { static let defaultValue: Int? = nil }

extension EnvironmentValues {
    var showsArtworkLoadingSpinner: Bool {
        get { self[ArtworkLoadingSpinnerKey.self] }
        set { self[ArtworkLoadingSpinnerKey.self] = newValue }
    }

    var artworkPriority: TaskPriority {
        get { self[ArtworkPriorityKey.self] }
        set { self[ArtworkPriorityKey.self] = newValue }
    }
    var artworkOrder: Int? {
        get { self[ArtworkOrderKey.self] }
        set { self[ArtworkOrderKey.self] = newValue }
    }
}

private struct VisibleArtworkPriority: ViewModifier {
    let order: Int
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .environment(\.artworkPriority, isVisible ? .medium : .low)
            .environment(\.artworkOrder, order)
            .onGeometryChange(for: Bool.self) { proxy in
                guard let viewport = proxy.bounds(of: .scrollView) else { return true }
                return viewport.intersects(CGRect(origin: .zero, size: proxy.size))
            } action: { isVisible = $0 }
    }
}

extension View {
    /// Visible Home rows first; ties follow the widget layout from top to bottom.
    func prioritizesArtwork(order: Int) -> some View { modifier(VisibleArtworkPriority(order: order)) }
}

/// Artwork that fills whatever frame it is given (aspect fill, clipped). While loading, or when there is no image, it shows a
/// flat grey skeleton; the image fades in. Missing artwork uses `title` as its fallback after loading finishes. The caller sizes and clips it.
struct ArtworkImage: View {
    let url: URL?
    let title: String
    let maxPixelSize: CGFloat
    let contentMode: ContentMode
    let placeholderURL: URL?
    let placeholderBlur: CGFloat
    /// Tried once, at the same size, when `url` fails to load. Nil, or the same URL as `url`, means no second try.
    let fallbackURL: URL?
    let imageAlignment: Alignment
    /// True for a stand-in: a picture of `url` that is decoded at another size is shown as it is, so one the user has just seen is there
    /// in the first frame and nothing is loaded for it.
    let acceptsAnyCachedSize: Bool
    /// Told whether the picture on show is the fallback, so the caller can draw what the first choice would have carried itself.
    let usesFallback: Binding<Bool>?
    /// True for a card's poster. The picture it replaces stays opaque under the new one while that fades in, so no placeholder shows
    /// through. With `fallbackURL` (a BetterPosters picture over the usual poster), a decoded copy of the fallback, at any size, stands in
    /// from the first frame.
    let keepsPictureOnShow: Bool
    @Environment(\.showsArtworkLoadingSpinner) private var showsLoadingSpinner
    @Environment(\.artworkPriority) private var artworkPriority
    @Environment(\.artworkOrder) private var artworkOrder

    @State private var hasFinishedLoading = false
    @State private var image: UIImage?
    /// The picture `image` replaced, held opaque under it while the new one fades in, so no placeholder shows through (see `show`).
    @State private var beneath: UIImage?
    /// Counts the pictures shown, so a fade that a newer one has overtaken knows not to clear what it left beneath.
    @State private var fadeCount = 0
    /// The URL `image` was loaded for, so a view that re-appears keeps its picture instead of flashing the placeholder.
    @State private var imageURL: URL?
    @State private var placeholderImage: UIImage?
    /// True while `image` came from `fallbackURL`.
    @State private var showsFallback: Bool

    init(url: URL?, title: String = "", maxPixelSize: CGFloat = 600, contentMode: ContentMode = .fill,
         placeholderURL: URL? = nil, placeholderBlur: CGFloat = 1, fallbackURL: URL? = nil, imageAlignment: Alignment = .center,
         acceptsAnyCachedSize: Bool = false, usesFallback: Binding<Bool>? = nil, keepsPictureOnShow: Bool = false) {
        self.url = url
        self.title = title
        self.maxPixelSize = maxPixelSize
        self.contentMode = contentMode
        self.placeholderURL = placeholderURL
        self.placeholderBlur = placeholderBlur
        self.fallbackURL = fallbackURL
        self.imageAlignment = imageAlignment
        self.acceptsAnyCachedSize = acceptsAnyCachedSize
        self.usesFallback = usesFallback
        self.keepsPictureOnShow = keepsPictureOnShow
        // Already decoded (the usual case when scrolling back): start with the picture, no placeholder frame and no fade.
        var cached = url.flatMap { Self.cachedPicture($0, maxPixelSize: maxPixelSize, anySize: acceptsAnyCachedSize) }
        var fellBack = false
        // The URL the first picture belongs to. Nil for a stand-in, so `load()` still fetches `url`.
        var shownURL = cached == nil ? nil : url
        if cached == nil, let url, let fallbackURL, fallbackURL != url {
            // A first choice that is known not to exist is not waited for again: its fallback, when decoded, is there at once too.
            if ImagePipeline.shared.isKnownMissing(url) {
                cached = ImagePipeline.shared.cachedImage(for: fallbackURL, maxPixelSize: maxPixelSize)
                fellBack = cached != nil
                shownURL = cached == nil ? nil : url
            }
            if cached == nil, keepsPictureOnShow {
                cached = ImagePipeline.shared.cachedImageAtAnySize(for: fallbackURL)
                fellBack = cached != nil
            }
        }
        _image = State(initialValue: cached)
        _imageURL = State(initialValue: shownURL)
        _showsFallback = State(initialValue: fellBack)
        _placeholderImage = State(initialValue: placeholderURL.flatMap { ImagePipeline.shared.cachedImage(for: $0, maxPixelSize: 600) })
    }

    var body: some View {
        // Color.clear takes the size it is offered. The picture lives in an overlay, so its own pixel size never reaches the layout.
        Color.clear
            .overlay { placeholder }
            .overlay(alignment: imageAlignment) {
                if image == nil, let placeholderImage {
                    Image(uiImage: placeholderImage)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .blur(radius: placeholderBlur)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: imageAlignment) {
                if let beneath {
                    Image(uiImage: beneath)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                }
            }
            .overlay(alignment: imageAlignment) {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .id(imageURL)
                        .transition(.opacity)
                }
            }
            .clipped()
            .loadingCardSpinner(showsLoadingSpinner && url != nil && image == nil && placeholderImage == nil && !hasFinishedLoading)
            .accessibilityHidden(true)
            // Stretching changes only the frame; it must not restart the download, decode or fade.
            .task(id: url) { await load() }
            // Promote an existing queued request when its row scrolls on screen, without restarting its download.
            .task(id: "\(url?.absoluteString ?? "-")|\(artworkPriority.rawValue)|\(artworkOrder ?? -1)") {
                guard let url, artworkOrder != nil else { return }
                await ImagePipeline.shared.prioritize(url, maxPixelSize: maxPixelSize, priority: artworkPriority, order: artworkOrder)
                if let fallbackURL {
                    await ImagePipeline.shared.prioritize(fallbackURL, maxPixelSize: maxPixelSize,
                                                           priority: artworkPriority, order: artworkOrder)
                }
            }
            .onChange(of: showsFallback, initial: true) { _, fellBack in usesFallback?.wrappedValue = fellBack }
            .task(id: image == nil ? placeholderURL : nil) {
                guard image == nil, let placeholderURL else { return }
                let preview = try? await ImagePipeline.shared.image(for: placeholderURL, maxPixelSize: 600,
                                                                    priority: artworkPriority, order: artworkOrder)
                guard !Task.isCancelled, image == nil else { return }
                withAnimation(.easeOut(duration: 0.1)) { placeholderImage = preview }
            }
    }

    /// Flat grey like the TV app's loading cards. No gradient: it is drawn once per card and must be cheap.
    private var placeholder: some View {
        ZStack {
            if contentMode == .fit { Theme.background } else { Theme.placeholder }
            if !title.isEmpty && (url == nil || hasFinishedLoading) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .padding(8)
            }
        }
    }

    private func load() async {
        hasFinishedLoading = false
        defer { if !Task.isCancelled { hasFinishedLoading = true } }
        guard let url else {
            image = nil
            beneath = nil
            imageURL = nil
            showsFallback = false
            return
        }
        if imageURL == url, image != nil { return }
        // The picture on show is still the fallback while `url` loads over it, so the caller keeps drawing what the fallback lacks.
        if keepsPictureOnShow, image != nil, let fallbackURL, imageURL == fallbackURL { showsFallback = true }
        if let cached = Self.cachedPicture(url, maxPixelSize: maxPixelSize, anySize: acceptsAnyCachedSize) {
            await show(cached, url: url, fellBack: false)
            return
        }
        // Keep the current artwork visible while a replacement downloads.
        guard let loaded = try? await download(url), !Task.isCancelled else { return }
        await show(loaded.image, url: url, fellBack: loaded.isFallback)
    }

    /// Fades `picture` in over the one on show. For a poster, the one on show stays opaque beneath until the fade is over, so the
    /// placeholder never shows through: a BetterPosters picture replacing the usual poster, or the reverse, goes straight from one to the other.
    private func show(_ picture: UIImage, url: URL, fellBack: Bool) async {
        let duration = placeholderURL == nil ? 0.35 : 0.15
        let previous = image
        fadeCount += 1
        let fade = fadeCount
        beneath = keepsPictureOnShow ? previous : nil
        withAnimation(.easeInOut(duration: duration)) {
            image = picture
            imageURL = url
            placeholderImage = nil
            showsFallback = fellBack
        }
        guard keepsPictureOnShow, previous != nil else { return }
        // A cancelled fade leaves `beneath` under an opaque picture until the next change replaces it.
        do { try await Task.sleep(for: .seconds(duration + 0.05)) } catch { return }
        // Only the latest fade clears `beneath`, so an older one cannot clear it while a newer one still fades.
        if fadeCount == fade { beneath = nil }
    }

    /// The decoded picture of `url` at this view's size, or, for a stand-in, at any size.
    private static func cachedPicture(_ url: URL, maxPixelSize: CGFloat, anySize: Bool) -> UIImage? {
        if let exact = ImagePipeline.shared.cachedImage(for: url, maxPixelSize: maxPixelSize) { return exact }
        return anySize ? ImagePipeline.shared.cachedImageAtAnySize(for: url) : nil
    }

    /// The picture at `url`, or at `fallbackURL` once when `url` fails. A load that was cancelled does not try the fallback.
    private func download(_ url: URL) async throws -> (image: UIImage, isFallback: Bool) {
        do {
            return (try await ImagePipeline.shared.image(for: url, maxPixelSize: maxPixelSize,
                                                         priority: artworkPriority, order: artworkOrder), false)
        } catch {
            guard !Task.isCancelled, let fallbackURL, fallbackURL != url else { throw error }
            return (try await ImagePipeline.shared.image(for: fallbackURL, maxPixelSize: maxPixelSize,
                                                         priority: artworkPriority, order: artworkOrder), true)
        }
    }
}
#endif
