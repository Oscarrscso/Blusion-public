import Foundation

extension Array where Element == CollectionItem {
    /// The tiles with every id unique. The first tile with an id keeps it, and a repeat takes the id plus the first number no tile has, so
    /// `["1", "1", "1-2", "1"]` becomes `["1", "1-3", "1-2", "1-4"]`. It is deterministic, so a saved collection loads the same way every
    /// time. SwiftUI and the tile editor key tiles by id, which is only defined when the ids are unique.
    public func withUniqueIDs() -> [CollectionItem] {
        var taken = Set(map(\.id))
        var seen = Set<String>()
        return map { original in
            var tile = original
            if !seen.insert(tile.id).inserted {
                var number = 2
                while taken.contains("\(tile.id)-\(number)") { number += 1 }
                tile.id = "\(tile.id)-\(number)"
                taken.insert(tile.id)
                seen.insert(tile.id)
            }
            return tile
        }
    }
}

extension HomeWidget {
    /// The widget with its tiles' ids made unique (see `withUniqueIDs()`), so a collection saved with repeats loads without them.
    public func withUniqueTileIDs() -> HomeWidget {
        guard case .collection(let tiles) = content else { return self }
        var widget = self
        widget.content = .collection(tiles.withUniqueIDs())
        return widget
    }
}
