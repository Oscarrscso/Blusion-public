#if canImport(SwiftData)
import Foundation
import SwiftData
import StremioKit

@Model
public final class DownloadEntity {
    @Attribute(.unique) public var id: UUID
    public var metadata: Data
    public init(id: UUID, metadata: Data) { self.id = id; self.metadata = metadata }
}

public actor SwiftDataDownloadStore: DownloadStore {
    private let container: ModelContainer
    private lazy var context = ModelContext(container)
    public init(container: ModelContainer) { self.container = container }
    public func loadAll() async throws -> [DownloadItem] {
        try context.fetch(FetchDescriptor<DownloadEntity>()).compactMap {
            guard let item = try? JSONDecoder().decode(DownloadItem.self, from: $0.metadata),
                  item.hasValidPaths, DownloadItem.validRequest(item.request) else { return nil }
            return item
        }
    }
    public func save(_ items: [DownloadItem]) async throws {
        guard items.allSatisfy({ $0.hasValidPaths && DownloadItem.validRequest($0.request) && $0.request.poster == nil }) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let rows = try context.fetch(FetchDescriptor<DownloadEntity>())
        let ids = Set(items.map(\.id))
        for row in rows where !ids.contains(row.id) { context.delete(row) }
        for item in items {
            let data = try JSONEncoder().encode(item)
            if let row = rows.first(where: { $0.id == item.id }) { row.metadata = data }
            else { context.insert(DownloadEntity(id: item.id, metadata: data)) }
        }
        try context.save()
    }
}
#endif
