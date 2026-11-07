#if canImport(UIKit)
import SwiftUI
import StremioKit
import UIKit

/// A hold menu's ways to play at a chosen quality, below a divider: Highest Quality, beside the remux symbol and, when Best Blurays names
/// the film's best disc, that disc's mark after it (none for a title that is only streamed), then Data Saver and Ultra Saver. Play, an
/// episode's card and a Continue Watching card share it.
struct PlayQualityMenuItems: View {
    /// The film's best disc, as the device keeps Best Blurays' answer. Nil shows the remux symbol alone.
    let disc: BestDiscFormat?
    let play: (PlayQuality) -> Void

    var body: some View {
        Divider()
        Button {
            Haptics.play(.buttons)
            play(.highest)
        } label: {
            if let image = PlayQualityMenu.highestImage(disc) {
                Label { Text(PlayQualityMenu.highestTitle) } icon: { Image(uiImage: image) }
            } else {
                Label(PlayQualityMenu.highestTitle, systemImage: QualityBadge.remuxSymbol)
            }
        }
        Button(PlayQualityMenu.dataSaverTitle, systemImage: PlayQualityMenu.dataSaverSymbol) {
            Haptics.play(.buttons)
            play(.dataSaver)
        }
        Button(PlayQualityMenu.ultraSaverTitle, systemImage: PlayQualityMenu.ultraSaverSymbol) {
            Haptics.play(.buttons)
            play(.ultraSaver)
        }
    }
}

/// The same choices for a menu built in UIKit (an episode's card in landscape), as an inline section, so the menu draws the divider.
@MainActor
enum PlayQualityMenu {
    static let highestTitle = "Highest Quality"
    static let dataSaverTitle = "Data Saver"
    static let dataSaverSymbol = "leaf"
    static let ultraSaverTitle = "Ultra Saver"
    static let ultraSaverSymbol = "tortoise"

    static func menu(disc: BestDiscFormat?, play: @escaping (PlayQuality) -> Void) -> UIMenu {
        let highest = UIAction(title: highestTitle, image: highestImage(disc) ?? UIImage(systemName: QualityBadge.remuxSymbol)) { _ in
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
        let ultraSaver = UIAction(title: ultraSaverTitle, image: UIImage(systemName: ultraSaverSymbol)) { _ in
            Task { @MainActor in
                Haptics.play(.buttons)
                play(.ultraSaver)
            }
        }
        return UIMenu(options: .displayInline, children: [highest, dataSaver, ultraSaver])
    }

    /// Highest Quality's mark when the film's best disc is known: the remux symbol, then the disc's mark. Nil without a disc, where the menu
    /// shows the remux symbol on its own as a plain symbol.
    static func highestImage(_ disc: BestDiscFormat?) -> UIImage? {
        guard let logo = discImage(disc),
              let glyph = UIImage(systemName: QualityBadge.remuxSymbol,
                                  withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)) else { return nil }
        let gap: CGFloat = 4
        let height = max(logo.size.height, glyph.size.height)
        let size = CGSize(width: (glyph.size.width + gap + logo.size.width).rounded(.up), height: height.rounded(.up))
        return UIGraphicsImageRenderer(size: size).image { _ in
            glyph.draw(in: CGRect(x: 0, y: (height - glyph.size.height) / 2, width: glyph.size.width, height: glyph.size.height))
            logo.draw(in: CGRect(x: glyph.size.width + gap, y: (height - logo.size.height) / 2, width: logo.size.width,
                                 height: logo.size.height))
        }
        .withRenderingMode(.alwaysTemplate)
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
