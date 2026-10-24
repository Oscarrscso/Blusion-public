import Foundation
import StremioKit

/// The one line Settings shows for the IMDb data kept on the device, such as "1,234,567 titles · 11 Oct 2026 · 48 MB".
enum IMDbDatasetSummary {
    static func text(_ status: IMDbDatasetStatus?) -> String {
        guard let status else { return "Downloading soon" }
        let count = status.titleCount.formatted(.number)
        var parts = ["\(count) titles"]
        if let date = status.updatedAt ?? status.checkedAt { parts.append(date.formatted(.dateTime.day().month(.abbreviated).year())) }
        if let size = status.fileSize { parts.append(size.formatted(.byteCount(style: .file))) }
        return parts.joined(separator: " · ")
    }
}
