#if canImport(UIKit)
import SwiftUI
import StremioKit

/// A title's page for a preview that may be listed under its TMDb number: the IMDb id is looked up first (see `TMDbPreviewResolver`), with
/// the spinner on the page's background meanwhile, and then the page opens with it. Any other preview, and one looked up already this
/// session, opens its page at once.
struct IMDbTitlePage<Page: View>: View {
    let services: AppServices
    let page: (MetaPreview) -> Page
    private let original: MetaPreview
    @State private var preview: MetaPreview?

    init(preview: MetaPreview, services: AppServices, @ViewBuilder page: @escaping (MetaPreview) -> Page) {
        self.original = preview
        self.services = services
        self.page = page
        _preview = State(initialValue: TMDbPreviewResolver.readyPreview(for: preview))
    }

    var body: some View {
        if let preview {
            page(preview)
        } else {
            Spinner()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .screenBackground()
                .accessibilityIdentifier("detail.lookingUpTitle")
                .task { preview = await TMDbPreviewResolver.resolve(original, services: services) }
        }
    }
}
#endif
