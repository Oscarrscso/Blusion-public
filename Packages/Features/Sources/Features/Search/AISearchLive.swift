import Foundation
import StremioKit

extension DescribedSearchService {
    static func live(_ services: AppServices) -> DescribedSearchService {
        let settings = services.settings
        let client = services.client
        let content = services.widgetContent
        let progress = services.progress
        let tmdb: @Sendable () async -> TMDbRatings? = {
            guard let token = await settings.load().tmdbReadToken else { return nil }
            return TMDbRatings(client: client, readAccessToken: token)
        }
        return DescribedSearchService(interpreter: OnDeviceDescriptionInterpreter.availableInterpreter(), keywords: { text in
            guard let api = await tmdb() else { return [] }
            return (try? await api.searchKeywords(text)) ?? []
        }, titles: { query in
            // Only one small window is resolved at a time. Each query is cached by WidgetContentService.
            try await content.items(for: .tmdbDiscover(query), limit: 18)
        }, ranker: OnDeviceDescriptionInterpreter.availableRanker(), titleMatches: { text in
            guard let api = await tmdb() else { throw WidgetSourceError.needsTMDbToken }
            return try await api.searchTitleItems(text, limit: 12)
        }, peopleTitles: { people, filters in
            guard let api = await tmdb() else { throw WidgetSourceError.needsTMDbToken }
            var credits: [TMDbPersonCredit] = []
            var identities: Set<String>?
            var facts: [String] = []
            for person in people {
                try Task.checkCancellation()
                let matches = try await api.searchPeople(person.name)
                guard let match = matches.first(where: { $0.name.caseInsensitiveCompare(person.name) == .orderedSame }) else { return [] }
                let filmography = try await api.personCredits(id: match.id).filter { credit in
                    credit.roles.contains { role in
                        switch (person.role, role) {
                        case (.cast, .acting): true
                        case (.director, .crew(let job, _)): job == "Director"
                        case (.writer, .crew(let job, _)): ["Writer", "Screenplay", "Story"].contains(job)
                        case (.creator, .crew(let job, _)): job == "Creator"
                        default: false
                        }
                    }
                }
                let ids = Set(filmography.map(\.id))
                identities = identities.map { $0.intersection(ids) } ?? ids
                if credits.isEmpty { credits = filmography }
                facts.append("\(person.role.rawValue): \(match.name)")
            }
            // Narrowed before the cap: Tom Hanks' two dozen most popular credits are talk shows and recent films, which left
            // "Tom Hanks movies from the 90s" with nothing.
            let chosen = credits.filter { identities?.contains($0.id) == true && Self.fitsFilmography($0, filters: filters) }
                .sorted { $0.popularity > $1.popularity }
            // No unbounded per-title requests: at most six IMDb identities resolve concurrently.
            var result: [AISearchCandidate] = []
            for start in stride(from: 0, to: min(chosen.count, 24), by: 6) {
                try Task.checkCancellation()
                let window = Array(chosen[start..<min(start + 6, min(chosen.count, 24))])
                let evidence = facts.joined(separator: "; ")
                let batch = await withTaskGroup(of: (Int, AISearchCandidate?).self) { group in
                    for (index, credit) in window.enumerated() {
                        group.addTask {
                            guard !Task.isCancelled,
                                  let metadata = try? await api.searchMetadata(tmdbID: credit.tmdbID, mediaType: credit.mediaType)
                            else { return (index, nil) }
                            let facts = [evidence, metadata.language.map { "Original language: \($0)" },
                                         metadata.score.map { "TMDb audience score: \($0)/10" },
                                         metadata.companies.joined(separator: ", ")].compactMap { $0 }.joined(separator: "; ")
                            return (index, AISearchCandidate(item: metadata.item, evidence: facts, metadata: metadata))
                        }
                    }
                    var found: [(Int, AISearchCandidate)] = []
                    for await (index, candidate) in group { if let candidate { found.append((index, candidate)) } }
                    return found.sorted { $0.0 < $1.0 }.map(\.1)
                }
                result += batch
            }
            return result
        }, companies: { text in
            guard let api = await tmdb() else { return [] }
            return (try? await api.searchCompanies(text)) ?? []
        }, related: { seed in
            guard let api = await tmdb() else { throw WidgetSourceError.needsTMDbToken }
            let titles = try await api.relatedTitles(imdbID: seed.id, type: seed.type)
            var result: [MetaPreview] = []
            for start in stride(from: 0, to: min(titles.count, 18), by: 6) {
                try Task.checkCancellation()
                let window = Array(titles[start..<min(start + 6, min(titles.count, 18))])
                let batch = await withTaskGroup(of: (Int, MetaPreview?).self) { group in
                    for (index, title) in window.enumerated() {
                        group.addTask {
                            guard !Task.isCancelled, let imdb = try? await api.imdbID(tmdbID: title.tmdbID, mediaType: title.mediaType)
                            else { return (index, nil) }
                            return (index, MetaPreview(id: imdb, type: title.mediaType == "tv" ? "series" : "movie", name: title.title,
                                poster: title.poster, background: title.backdrop, description: title.overview,
                                releaseInfo: title.releaseDate.map { String($0.prefix(4)) }))
                        }
                    }
                    var found: [(Int, MetaPreview)] = []
                    for await (index, item) in group { if let item { found.append((index, item)) } }
                    return found.sorted { $0.0 < $1.0 }.map(\.1)
                }
                result += batch
            }
            return result
        }, watched: {
            Set(await progress.all().filter { $0.isWatched || $0.position > 0 }.map {
                "\($0.type)/\($0.seriesID ?? $0.contentID)"
            })
        }, pageTitles: { query, skip in
            try await content.items(for: .tmdbDiscover(query), limit: batchSize, skip: skip)
        })
    }

    /// Whether a credit is of the kind and years the search allows, and is a part rather than an appearance as themselves.
    static func fitsFilmography(_ credit: TMDbPersonCredit, filters: DescribedSearch) -> Bool {
        if let kind = filters.kind, credit.isMovie != (kind == .movie) { return false }
        if filters.earliestYear != nil || filters.latestYear != nil {
            guard let year = credit.year else { return false }
            if let earliest = filters.earliestYear, year < earliest { return false }
            if let latest = filters.latestYear, year > latest { return false }
        }
        let parts = credit.roles.filter { if case .acting = $0 { true } else { false } }
        let appearances = parts.filter { role in
            guard case .acting(let character) = role, let character = character?.lowercased() else { return false }
            return ["self", "himself", "herself", "themselves"].contains { character.hasPrefix($0) }
        }
        return parts.isEmpty || appearances.count < parts.count || credit.roles.count > parts.count
    }
}
