#if canImport(UIKit)
import SwiftUI
import StremioKit
import UIKit

/// A hold menu's ways to play at a chosen quality, below a divider: Highest Quality, marked with the film's best disc when Best Blurays
/// names one (no mark for a title that is only streamed), then Data Saver. Play, an episode's card and a Continue Watching card share it.
struct PlayQualityMenuItems: View {
    /// The film's best disc, as the device keeps Best Blurays' answer. Nil shows no mark.
    let disc: BestDiscFormat?
    let play: (PlayQuality) -> Void

    var body: some View {
        Divider()
        Button {
            Haptics.play(.buttons)
            play(.highest)
        } label: {
            if let image = PlayQualityMenu.discImage(disc) {
                Label { Text(PlayQualityMenu.highestTitle) } icon: { Image(uiImage: image) }
            } else {
                Text(PlayQualityMenu.highestTitle)
            }
        }
        Button(PlayQualityMenu.dataSaverTitle, systemImage: PlayQualityMenu.dataSaverSymbol) {
            Haptics.play(.buttons)
            play(.dataSaver)
        }
    }
}

/// The same choices for a menu built in UIKit (an episode's card in landscape), as an inline section, so the menu draws the divider.
@MainActor
enum PlayQualityMenu {
    static let highestTitle = "Highest Quality"
    static let dataSaverTitle = "Data Saver"
    static let dataSaverSymbol = "leaf"

    static func menu(disc: BestDiscFormat?, play: @escaping (PlayQuality) -> Void) -> UIMenu {
        let highest = UIAction(title: highestTitle, image: discImage(disc)) { _ in
            Task { @MainActor in
                Haptics.play(.buttons)
                play(.highest)
            }
        }
        let dataSaver = UIAction(title: dataSaverTitle, image: UIImage(systemName: dataSaverSymbol)) { _ in
            Task { @MainActor in
                Haptics.play(.buttons)
                play(.dataSaver)
            }
        }
        return UIMenu(options: .displayInline, children: [highest, dataSaver])
    }

    /// The disc's mark, the logo the stream rows use, at a menu glyph's height. The logos are wide, so they are drawn to fit a small box
    /// rather than at their own size, and as a template, so the menu tints them like the symbols beside them.
    static func discImage(_ disc: BestDiscFormat?) -> UIImage? {
        guard let disc, let logo = UIImage(named: disc == .uhdBluRay ? "StreamLogoUHDBluRay" : "StreamLogoBluRay"),
              logo.size.width > 0, logo.size.height > 0 else { return nil }
        let box = CGSize(width: 34, height: 16)
        let scale = min(box.width / logo.size.width, box.height / logo.size.height)
        let size = CGSize(width: (logo.size.width * scale).rounded(.up), height: (logo.size.height * scale).rounded(.up))
        return UIGraphicsImageRenderer(size: size).image { _ in logo.draw(in: CGRect(origin: .zero, size: size)) }
            .withRenderingMode(.alwaysTemplate)
    }
}
#endif
