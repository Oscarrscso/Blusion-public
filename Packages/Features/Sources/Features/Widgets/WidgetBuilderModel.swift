import Foundation
import Observation
import StremioKit

/// The widget builder screen's state: the row, spotlight or banner being made or changed, the sentence that describes it, the pills
/// that open its settings, and the changes each setting makes. It has no views, so the host tests cover it.
@MainActor
@Observable
public final class WidgetBuilderModel {
    public enum Mode: Sendable { case create, edit }

    /// One setting of a widget. Each is a pill in the strip; one that has a value is also a token in the sentence.
    public enum Field: String, CaseIterable, Identifiable, Sendable {
        case source, ordering, period, genres, keywords, excludedKeywords, score, votes, language, runtime, release, providers, region,
             cast, crew, companies, catalogGenre, traktSort, title, limit, style, cards, posters, shuffle, randomSource
        public var id: String { rawValue }
    }

    /// A setting in the strip: its name, its current value in a few words, and whether the list can use it right now.
    public struct Pill: Identifiable, Equatable, Sendable {
        public let field: Field
        /// "Genres".
        public let title: String
        /// The current value in a few words: "Any", "Animation +1", "7+".
        public let value: String
        public let systemImage: String
        /// False for a filter the list cannot use right now; `value` then says why ("Not with Trending", "Movies only").
        public let isEnabled: Bool
        public var id: Field { field }
    }

    /// A tappable piece of the sentence. Tapping it opens its field; a removable one also has a cross that takes the value away.
    public struct Token: Identifiable, Hashable, Sendable {
        /// Unique in the sentence: the field's raw value, plus `:<valueID>` for one of several values.
        public let id: String
        public let field: Field
        public let text: String
        public let isRemovable: Bool
        /// The genre, keyword, person, company or provider this token stands for, when the field holds several.
        public let valueID: Int?
    }

    /// One piece of the sentence: plain words, the movie-or-series dropdown, or a token.
    public enum Part: Hashable, Sendable {
        /// Plain words of the sentence. A piece may hold several words.
        case text(String)
        /// The movie-or-series choice, drawn as a dropdown.
        case kind(TMDbDiscoverQuery.Kind)
        case token(Token)
    }

    /// A part of the sentence with its position, which gives a view a stable identity for each part.
    public struct SentenceItem: Identifiable, Hashable, Sendable {
        public let id: Int
        public let part: Part
    }

    /// Whether the screen makes a new widget or changes a saved one.
    public let mode: Mode
    /// The widget as it would be saved. A widget that is not a row, spotlight or banner is shown as an empty row with no source.
    public private(set) var widget: HomeWidget
    /// The setting whose editor is open, if any.
    public var selectedField: Field?
    /// True when the source is a TMDB list and no TMDb token is saved, so the list cannot be read.
    public private(set) var needsTMDbToken = false
    /// The genres of the query's kind, once loaded.
    public private(set) var genreOptions: [TMDbDiscoverQuery.Named] = []
    /// The watch providers of the query's kind and region, once loaded.
    public private(set) var providerOptions: [TMDbDiscoverQuery.Named] = []
    public private(set) var isLoadingOptions = false
    /// One plain sentence when the options could not be loaded.
    public private(set) var optionsMessage: String?
    /// The device's region, uppercased: the region a provider list uses when the query names none.
    public let deviceRegion: String

    private let manager: WidgetsManagerViewModel
    private let lookups: WidgetBuilderLookups
    /// False while the title follows the source's name.
    private var titleIsCustom: Bool
    /// A Trakt sort chosen before the list is: it is applied when a Trakt list is chosen.
    private var pendingTraktSort: TraktListSort?
    /// Whether the saved settings had a TMDb token at the last `load()`. Assumed true until then, so nothing warns early.
    private var hasSavedToken = true
    /// The key each option list was last loaded for, kept only after a load succeeds.
    private var loadedOptions: [Field: String] = [:]

    private static let noTokenMessage = "Add a TMDB Read Access Token in Settings to choose from TMDB's lists."
    private static let unreachableMessage = "TMDB couldn't be reached."

    /// The builder for a new widget (a TMDB list of popular movies unless `widget` is given) or for a saved one. `region` is the device's
    /// region, which the region and provider pills use when the query names none.
    public convenience init(mode: Mode, widget: HomeWidget? = nil, manager: WidgetsManagerViewModel, services: AppServices,
                            region: String = Locale.current.region?.identifier ?? "US") {
        self.init(mode: mode, widget: widget, manager: manager, lookups: .live(services: services), region: region)
    }

    /// The same builder with its TMDb calls supplied, so the tests can answer them without the network.
    init(mode: Mode, widget: HomeWidget?, manager: WidgetsManagerViewModel, lookups: WidgetBuilderLookups, region: String) {
        self.mode = mode
        self.manager = manager
        self.lookups = lookups
        self.deviceRegion = region.uppercased()
        let fallback = HomeWidget(title: "Popular Movies", content: .row(RowConfiguration(source: .tmdbDiscover(TMDbDiscoverQuery()))))
        var shown = widget ?? fallback
        if Self.rowOf(shown.content) == nil { shown.content = .row(RowConfiguration(source: .unsupported(kind: ""))) }
        self.widget = shown
        let source = Self.rowOf(shown.content)?.source ?? .unsupported(kind: "")
        // A title is custom when the user named the widget: a blank one, or the source's own name, is not.
        self.titleIsCustom = Self.trimmedOrNil(shown.title) != nil && shown.title != manager.autoTitle(for: source)
    }

    // MARK: Derived values

    /// The row, spotlight or banner being made or changed.
    public var row: RowConfiguration { Self.rowOf(widget.content) ?? RowConfiguration(source: .unsupported(kind: "")) }

    /// The query of a TMDB list; nil for any other source.
    public var query: TMDbDiscoverQuery? {
        guard case .tmdbDiscover(let query) = row.source else { return nil }
        return query
    }

    /// The widget's style: a row, a spotlight or a banner.
    public var style: WidgetStyle { WidgetStyle(widget.content) ?? .row }

    /// Shows the widget in another style, keeping its items and title (see `WidgetStyle.restyled`).
    public func setStyle(_ style: WidgetStyle) {
        widget = WidgetStyle.restyled(widget, as: style)
    }

    /// The name the source gives the widget.
    public var autoTitle: String { manager.autoTitle(for: row.source) }

    /// The source as the source picker names it: an addon's catalog, or a Trakt list or feed.
    public var sourceDescription: String { manager.describe(row.source) }

    /// The title the user typed, or "" while the title follows the source.
    public var customTitle: String { titleIsCustom ? widget.title : "" }

    /// Names the widget. Blank text goes back to the automatic title.
    public func setCustomTitle(_ text: String) {
        if Self.trimmedOrNil(text) == nil {
            titleIsCustom = false
            widget.title = autoTitle
        } else {
            titleIsCustom = true
            widget.title = text
        }
    }

    public var hidesTitle: Bool { widget.hideTitle }

    public func setHideTitle(_ hidden: Bool) {
        widget.hideTitle = hidden
    }

    /// False only while the source is unsupported, so there is no source to save.
    public var canCommit: Bool {
        if case .unsupported = row.source { return false }
        return true
    }

    /// The item counts on offer, with the widget's own count when it is not one of them.
    public var limitChoices: [Int] { Array(Set([5, 10, 15, 20, 30, 40, 50, 75, 100, row.limit])).sorted() }

    /// The genres the widget's catalog offers; empty for any other source.
    public var catalogGenres: [String] { manager.genres(for: row.source) }

    /// The Trakt sort of the widget's list, or the sort chosen before a list was.
    public var traktSort: TraktListSort? {
        if case .traktList(let list) = row.source { return list.sort }
        return pendingTraktSort
    }

    // MARK: Sentence

    /// The sentence that describes the widget. It always ends with a full stop. The view draws the tokens and the kind dropdown.
    public var sentence: [SentenceItem] {
        let shape = sentenceShape
        let parts = shape.head + Self.joined(shape.pieces) + [.text(".")]
        return parts.enumerated().map { SentenceItem(id: $0.offset, part: $0.element) }
    }

    /// The fixed words that lead the sentence, and the pieces that follow them, joined by `joined`.
    private var sentenceShape: (head: [Part], pieces: [[Part]]) {
        switch row.source {
        case .tmdbDiscover(let query):
            let head: [Part] = [.text("Make a"), .kind(query.kind), .text("list sorted by")]
            let ordering = Self.token(.ordering, Self.orderingPhrase(query.ordering), removable: false)
            return (head, [[ordering]] + filterClauses(query) + commonClauses)
        case .addonCatalog:
            // The genre and the sort read straight on from the source's name, with no "and" before them.
            var lead: [Part] = [.text("Show"), sourcePart]
            if let genre = catalogGenreName { lead += Self.clause("about", [Self.token(.catalogGenre, genre)]) }
            return ([], [lead] + commonClauses)
        case .traktList(let list):
            var lead: [Part] = [.text("Show the Trakt list"), sourcePart]
            if let sort = list.sort { lead += Self.clause("sorted by", [Self.token(.traktSort, sort.title)]) }
            return ([], [lead] + commonClauses)
        case .traktFeed:
            return ([], [[.text("Show"), sourcePart, .text("from Trakt")]] + commonClauses)
        case .unsupported:
            return ([.text("Choose what this widget shows:")], [[Self.token(.source, "Source", removable: false)]])
        }
    }

    /// The clauses that narrow a TMDB list: one for each filter that is set, in the order the sentence reads.
    private func filterClauses(_ saved: TMDbDiscoverQuery) -> [[Part]] {
        // A filter the list cannot use (one an imported file carried) is not part of what the widget shows, so it is not read out.
        let query = saved.removingUnsupportedFilters()
        var clauses: [[Part]] = []
        if query.isSet(.genres) {
            clauses.append(Self.clause("about", query.genres.map { Self.token(.genres, $0.name.lowercased(), valueID: $0.id) }))
        }
        if query.isSet(.keywords) {
            clauses.append(Self.clause("with", query.keywords.map { Self.token(.keywords, $0.name, valueID: $0.id) }))
        }
        if query.isSet(.excludedKeywords) {
            clauses.append(Self.clause("without", query.excludedKeywords.map { Self.token(.excludedKeywords, $0.name, valueID: $0.id) }))
        }
        if let period = query.period {
            clauses.append(Self.clause("from", [Self.token(.period, Self.periodPhrase(period))]))
        }
        if let text = Self.releaseText(query) { clauses.append(Self.clause("released", [Self.token(.release, text)])) }
        // A widget's score and votes are IMDb's (see `TMDbDiscoverQuery.usesTMDbScores`), and the sentence says so.
        if let text = Self.scoreText(query) { clauses.append(Self.clause("rated", [Self.token(.score, text + " on IMDb")])) }
        if query.isSet(.votes), let votes = query.minimumVotes {
            clauses.append(Self.clause("with", [Self.token(.votes, "\(votes)+ IMDb votes")]))
        }
        if let code = query.language { clauses.append(Self.clause("in", [Self.token(.language, Self.languageName(code))])) }
        if let text = Self.runtimeText(query) { clauses.append(Self.clause("running", [Self.token(.runtime, text)])) }
        if query.isSet(.providers) {
            clauses.append(Self.clause("on", query.providers.map { Self.token(.providers, $0.name, valueID: $0.id) }))
            let region = query.region ?? deviceRegion
            clauses.append(Self.clause("in", [Self.token(.region, Self.regionName(region), removable: query.region != nil)]))
        }
        if query.isSet(.cast) {
            clauses.append(Self.clause("starring", query.cast.map { Self.token(.cast, $0.name, valueID: $0.id) }))
        }
        if query.isSet(.crew) {
            clauses.append(Self.clause("made by", query.crew.map { Self.token(.crew, $0.name, valueID: $0.id) }))
        }
        if query.isSet(.companies) {
            clauses.append(Self.clause("from", query.companies.map { Self.token(.companies, $0.name, valueID: $0.id) }))
        }
        return clauses
    }

    /// The clauses every source has: the item count when it is not 20, and the title when the user named the widget.
    private var commonClauses: [[Part]] {
        var clauses: [[Part]] = []
        if row.limit != 20 { clauses.append(Self.clause("showing", [Self.token(.limit, "\(row.limit) titles")])) }
        if titleIsCustom, let title = Self.trimmedOrNil(widget.title) {
            clauses.append(Self.clause("called", [Self.token(.title, "\u{201C}\(title)\u{201D}")]))
        }
        return clauses
    }

    /// The source as the sentence names it.
    private var sourcePart: Part {
        let text: String
        switch row.source {
        case .addonCatalog(var reference):
            // The genre has its own token, so the catalog is named without it.
            reference.genre = nil
            text = manager.describe(.addonCatalog(reference))
        case .traktList(let list): text = list.listName
        case .traktFeed(let feed): text = feed.title
        case .tmdbDiscover, .unsupported: text = "Source"
        }
        return Self.token(.source, text, removable: false)
    }

    /// The genre a catalog is filtered to, or nil when it is not.
    private var catalogGenreName: String? {
        guard case .addonCatalog(let reference) = row.source else { return nil }
        return Self.trimmedOrNil(reference.genre)
    }

    // MARK: Pills

    /// The settings strip: the source first, then the settings of the source, then the title, items, style and card options.
    public var pills: [Pill] {
        var list = [sourcePill]
        switch row.source {
        case .tmdbDiscover(let query):
            list += tmdbPills(query)
        case .addonCatalog:
            if !catalogGenres.isEmpty {
                list.append(Pill(field: .catalogGenre, title: "Genre", value: catalogGenreName ?? "All", systemImage: "theatermasks",
                                 isEnabled: true))
            }
        case .traktList:
            list.append(Pill(field: .traktSort, title: "Sort", value: traktSort?.title ?? "List Default",
                             systemImage: "arrow.up.arrow.down", isEnabled: true))
        case .traktFeed, .unsupported:
            break
        }
        return list + commonPills
    }

    private var sourcePill: Pill {
        let value: String
        switch row.source {
        case .tmdbDiscover: value = "TMDB"
        case .addonCatalog: value = manager.describe(row.source).components(separatedBy: " · ").last ?? ""
        case .traktList, .traktFeed: value = "Trakt"
        case .unsupported: value = "Choose"
        }
        return Pill(field: .source, title: "Source", value: value, systemImage: "square.stack.3d.up", isEnabled: true)
    }

    /// The pills of a TMDB list. A filter the query cannot use is listed but disabled, with the reason as its value.
    private func tmdbPills(_ query: TMDbDiscoverQuery) -> [Pill] {
        let unavailable = query.isTrending ? "Not with Trending" : "Movies only"
        func filterPill(_ field: Field, _ title: String, _ image: String, _ filter: TMDbDiscoverQuery.Filter, _ value: String) -> Pill {
            let enabled = query.supports(filter)
            return Pill(field: field, title: title, value: enabled ? value : unavailable, systemImage: image, isEnabled: enabled)
        }
        return [
            Pill(field: .ordering, title: "Order", value: query.ordering.title, systemImage: "arrow.up.arrow.down", isEnabled: true),
            filterPill(.period, "Period", "calendar", .period, query.period?.title ?? "Any time"),
            filterPill(.genres, "Genres", "theatermasks", .genres, Self.listValue(query.genres, none: "Any")),
            filterPill(.keywords, "Keywords", "tag", .keywords, Self.listValue(query.keywords, none: "Any")),
            filterPill(.excludedKeywords, "Exclude", "tag.slash", .excludedKeywords, Self.listValue(query.excludedKeywords, none: "None")),
            filterPill(.score, "IMDb Score", "star", .score, Self.scoreText(query) ?? "Any"),
            filterPill(.votes, "IMDb Votes", "person.3", .votes, query.minimumVotes.map { "\($0)+" } ?? "Any"),
            filterPill(.language, "Language", "globe", .language, query.language.map(Self.languageName) ?? "Any"),
            filterPill(.runtime, "Runtime", "clock", .runtime, Self.runtimeText(query) ?? "Any"),
            filterPill(.release, "Release", "calendar.badge.clock", .release, Self.releaseText(query) ?? "Any"),
            filterPill(.providers, "Providers", "play.tv", .providers, Self.listValue(query.providers, none: "Any")),
            filterPill(.region, "Region", "mappin.and.ellipse", .region, Self.regionName(query.region ?? deviceRegion)),
            filterPill(.cast, "Cast", "person.2", .cast, Self.listValue(query.cast, none: "Any")),
            filterPill(.crew, "Crew", "megaphone", .crew, Self.listValue(query.crew, none: "Any")),
            filterPill(.companies, "Companies", "building.2", .companies, Self.listValue(query.companies, none: "Any")),
        ]
    }

    /// The title, items, style and card options, which every source has, in this order.
    private var commonPills: [Pill] {
        let cards = "\(row.presentation.aspectRatio.rawValue.capitalized) · \(row.presentation.cardStyle.rawValue.capitalized)"
        return [
            Pill(field: .title, title: "Title", value: customTitle.isEmpty ? "Automatic" : customTitle, systemImage: "textformat",
                 isEnabled: true),
            Pill(field: .limit, title: "Items", value: "\(row.limit)", systemImage: "number", isEnabled: true),
            Pill(field: .style, title: "Style", value: style.rawValue, systemImage: "rectangle.3.group", isEnabled: true),
            Pill(field: .cards, title: "Cards", value: cards, systemImage: "rectangle.portrait", isEnabled: true),
            Pill(field: .posters, title: "Posters", value: row.presentation.usesBetterPosters ? "Better Posters" : "Standard",
                 systemImage: "photo.artframe", isEnabled: true),
            Pill(field: .shuffle, title: "Shuffle", value: Self.shuffleText(row.shuffle), systemImage: "shuffle", isEnabled: true),
            Pill(field: .randomSource, title: "Random Source", value: Self.randomSourceText(row.randomSource), systemImage: "dice",
                 isEnabled: true),
        ]
    }

    /// A random source in a few words: "Off", "All Sources", "3 Sources".
    public static func randomSourceText(_ random: RandomSource?) -> String {
        guard let random else { return "Off" }
        if random.usesAllSources { return "All Sources" }
        return random.sources.count == 1 ? "1 Source" : "\(random.sources.count) Sources"
    }

    /// The catalogs a random source can pick from: every catalog of the installed addons.
    public var randomSourceChoices: [WidgetsManagerViewModel.CatalogChoice] { manager.catalogChoices }

    /// Turns the random source on (picking from every catalog, or keeping its sources) or off.
    public func setRandomSource(_ random: RandomSource?) {
        updateRow { $0.randomSource = random }
    }

    /// Adds a source to the ones the random source picks from, or takes it off. With none left, it picks from every catalog.
    public func toggleRandomSource(_ source: WidgetSource) {
        updateRow { row in
            var random = row.randomSource ?? RandomSource()
            if let index = random.sources.firstIndex(of: source) { random.sources.remove(at: index) } else { random.sources.append(source) }
            row.randomSource = random
        }
    }

    /// When the random source picks again.
    public func setRandomSourceSchedule(_ schedule: WidgetShuffle) {
        updateRow { row in
            guard var random = row.randomSource else { return }
            random.schedule = schedule
            row.randomSource = random
        }
    }

    /// A shuffle schedule in a few words: "Daily", "Every 1 to 6 hours". Nil is the widgets page's setting.
    public static func shuffleText(_ shuffle: WidgetShuffle?) -> String {
        switch shuffle {
        case nil: "Like Other Widgets"
        case .off?: "Off"
        case .everyOpen?: "Every Time Home Opens"
        case .hourly?: "Hourly"
        case .daily?: "Daily"
        case .randomTimes(let low, let high)?: "At Random, Every \(low) to \(high) Hours"
        }
    }

    // MARK: Selecting

    /// Opens a setting's editor, or closes it when it is already open. A setting whose pill is disabled cannot be opened.
    public func select(_ field: Field) {
        if selectedField == field {
            selectedField = nil
            return
        }
        guard isEnabled(field) else { return }
        selectedField = field
    }

    private func isEnabled(_ field: Field) -> Bool {
        pills.first(where: { $0.field == field })?.isEnabled == true
    }

    // MARK: Changes

    /// Sets the movie-or-series choice of a TMDB list.
    public func setKind(_ kind: TMDbDiscoverQuery.Kind) {
        updateQuery { $0.kind = kind }
    }

    /// Sets the ordering of a TMDB list. A trending ordering drops the filters a trending list cannot use.
    public func setOrdering(_ ordering: TMDbDiscoverQuery.Ordering) {
        updateQuery { $0.ordering = ordering }
    }

    /// Applies a change to a TMDB list's query. Filters the query cannot use are dropped afterwards. A period and explicit release dates
    /// replace each other: setting one clears the other. A blank language or region is stored as nil. Does nothing for other sources.
    public func updateQuery(_ change: (inout TMDbDiscoverQuery) -> Void) {
        guard let current = query else { return }
        var edited = current
        change(&edited)
        if edited.minimumScore != current.minimumScore || edited.maximumScore != current.maximumScore
            || edited.minimumVotes != current.minimumVotes {
            // A score or vote count set here is IMDb's, as the editor says, even on a list a search made with TMDb's.
            edited.usesTMDbScores = false
        }
        let periodChanged = edited.period != current.period
        let releaseChanged = edited.releasedFrom != current.releasedFrom || edited.releasedTo != current.releasedTo
        let releaseIsSet = edited.releasedFrom != nil || edited.releasedTo != nil
        if periodChanged, edited.period != nil {
            edited.releasedFrom = nil
            edited.releasedTo = nil
        } else if releaseChanged, releaseIsSet {
            edited.period = nil
        }
        edited.language = Self.trimmedOrNil(edited.language)
        edited.region = Self.trimmedOrNil(edited.region)?.uppercased()
        var configuration = row
        configuration.source = .tmdbDiscover(edited.removingUnsupportedFilters())
        writeRow(configuration)
    }

    /// Adds a genre, keyword, excluded keyword, provider, cast member, crew member or company to its list, or takes it off when it
    /// is there. A keyword added to the keywords is taken off the excluded keywords, and the other way round. Does nothing for other
    /// fields.
    public func toggle(_ value: TMDbDiscoverQuery.Named, in field: Field) {
        updateQuery { query in
            switch field {
            case .genres: Self.toggle(value, in: &query.genres)
            case .keywords:
                if Self.toggle(value, in: &query.keywords) { query.excludedKeywords.removeAll { $0.id == value.id } }
            case .excludedKeywords:
                if Self.toggle(value, in: &query.excludedKeywords) { query.keywords.removeAll { $0.id == value.id } }
            case .providers: Self.toggle(value, in: &query.providers)
            case .cast: Self.toggle(value, in: &query.cast)
            case .crew: Self.toggle(value, in: &query.crew)
            case .companies: Self.toggle(value, in: &query.companies)
            default: break
            }
        }
    }

    /// Applies a change to the row's items, presentation or other row settings. The limit stays within 1...100.
    public func updateRow(_ change: (inout RowConfiguration) -> Void) {
        var configuration = row
        change(&configuration)
        writeRow(configuration)
    }

    /// Makes the widget a TMDB list of popular movies when its source is something else. A TMDB list that is already set is kept.
    public func useTMDbList() {
        guard query == nil else { return }
        replaceSource(.tmdbDiscover(TMDbDiscoverQuery()))
    }

    /// Puts a catalog or Trakt source, chosen in a picker, into the widget. A Trakt sort chosen before the list is applied to it.
    public func setSource(_ source: WidgetSource) {
        guard case .traktList(var list) = source, let sort = pendingTraktSort else {
            replaceSource(source)
            return
        }
        list.sort = sort
        replaceSource(.traktList(list))
    }

    /// Filters a catalog to one of its genres. Nil or blank takes the filter away.
    public func setCatalogGenre(_ genre: String?) {
        guard case .addonCatalog(var reference) = row.source else { return }
        reference.genre = Self.trimmedOrNil(genre)
        replaceSource(.addonCatalog(reference))
    }

    /// Sorts a Trakt list. Before a Trakt list is chosen, the sort is kept and applied when it is.
    public func setTraktSort(_ sort: TraktListSort?) {
        pendingTraktSort = sort
        guard case .traktList(var list) = row.source else { return }
        list.sort = sort
        replaceSource(.traktList(list))
    }

    /// Takes one value away: a list entry, or the filter, sort, region, genre, title or item count the token shows. Tokens that cannot
    /// be removed do nothing.
    public func remove(_ token: Token) {
        guard token.isRemovable else { return }
        switch token.field {
        case .genres, .keywords, .excludedKeywords, .providers, .cast, .crew, .companies:
            guard let id = token.valueID else { return }
            updateQuery { Self.removeNamed(id, from: token.field, in: &$0) }
        case .period: updateQuery { $0.clear(.period) }
        case .score: updateQuery { $0.clear(.score) }
        case .votes: updateQuery { $0.clear(.votes) }
        case .language: updateQuery { $0.clear(.language) }
        case .runtime: updateQuery { $0.clear(.runtime) }
        case .release: updateQuery { $0.clear(.release) }
        case .region: updateQuery { $0.clear(.region) }
        case .catalogGenre: setCatalogGenre(nil)
        case .traktSort: setTraktSort(nil)
        case .limit: updateRow { $0.limit = 20 }
        case .title: setCustomTitle("")
        default: break
        }
    }

    // MARK: Loading and lookups

    /// Reads whether a TMDb token is saved, which settles `needsTMDbToken`. Call it when the screen appears and after the source changes.
    public func load() async {
        hasSavedToken = await lookups.hasToken()
        needsTMDbToken = query != nil && !hasSavedToken
    }

    /// Loads the genres of the query's kind, or the watch providers of its kind and region, unless they are already loaded for it.
    /// Says why when they cannot be loaded. Does nothing for other fields and sources.
    public func loadOptions(for field: Field) async {
        guard let query else { return }
        switch field {
        case .genres:
            guard loadedOptions[field] != query.kind.rawValue else { return }
            genreOptions = []
            await perform {
                genreOptions = try await lookups.genres(query.kind)
                loadedOptions[field] = query.kind.rawValue
            }
        case .providers:
            let region = query.region ?? deviceRegion
            let key = "\(query.kind.rawValue)/\(region)"
            guard loadedOptions[field] != key else { return }
            providerOptions = []
            await perform {
                providerOptions = try await lookups.providers(query.kind, region)
                loadedOptions[field] = key
            }
        default:
            return
        }
    }

    /// Runs one option load with the progress flag set. Says why when there is no token or the request fails.
    private func perform(_ work: () async throws -> Void) async {
        optionsMessage = nil
        isLoadingOptions = true
        defer { isLoadingOptions = false }
        guard await lookups.hasToken() else {
            optionsMessage = Self.noTokenMessage
            return
        }
        do {
            try await work()
        } catch {
            optionsMessage = Self.unreachableMessage
        }
    }

    /// The matches for the text typed into a field's search: keywords for the keyword fields, people for cast and crew, companies for
    /// companies. Empty for blank text, for fields without a search and when the search fails.
    public func suggestions(for field: Field, matching text: String) async -> [TMDbDiscoverQuery.Named] {
        guard let term = Self.trimmedOrNil(text) else { return [] }
        do {
            switch field {
            case .keywords, .excludedKeywords: return try await lookups.keywords(term)
            case .cast, .crew: return try await lookups.people(term)
            case .companies: return try await lookups.companies(term)
            default: return []
            }
        } catch {
            return []
        }
    }

    /// The languages whose name or code contains the text, by name. Blank text gives them all.
    public static func languages(matching text: String, locale: Locale = .current) -> [(code: String, name: String)] {
        let codes = Locale.LanguageCode.isoLanguageCodes.map(\.identifier).filter { $0.count == 2 }
        let named = codes.compactMap { code -> (code: String, name: String)? in
            guard let name = locale.localizedString(forLanguageCode: code) else { return nil }
            return (code: code, name: name)
        }
        return matching(named, text)
    }

    /// The regions whose name or code contains the text, by name. Blank text gives them all.
    public static func regions(matching text: String, locale: Locale = .current) -> [(code: String, name: String)] {
        let codes = Locale.Region.isoRegions.map(\.identifier).filter { $0.count == 2 }
        let named = codes.compactMap { code -> (code: String, name: String)? in
            guard let name = locale.localizedString(forRegionCode: code) else { return nil }
            return (code: code, name: name)
        }
        return matching(named, text)
    }

    // MARK: Saving

    /// Adds a new widget or replaces the saved one. A blank title becomes the automatic one. Does nothing while `canCommit` is false.
    public func commit() async {
        guard canCommit else { return }
        var saved = widget
        if Self.trimmedOrNil(saved.title) == nil { saved.title = autoTitle }
        switch mode {
        case .create: await manager.add(saved)
        case .edit: await manager.update(saved)
        }
    }

    /// Removes the widget from Home.
    public func removeWidget() async {
        await manager.remove(id: widget.id)
    }

    // MARK: Helpers

    /// Writes the row back and keeps the rest in step: the title follows the source unless it is custom, a selection that no longer
    /// applies is dropped, and `needsTMDbToken` is refreshed.
    private func writeRow(_ configuration: RowConfiguration) {
        var configuration = configuration
        configuration.limit = min(max(configuration.limit, 1), 100)
        widget.content = (WidgetStyle(widget.content) ?? .row).content(configuration)
        if !titleIsCustom { widget.title = autoTitle }
        if let field = selectedField, !isEnabled(field) { selectedField = nil }
        needsTMDbToken = query != nil && !hasSavedToken
    }

    /// Puts a source into the row, keeping its items and presentation.
    private func replaceSource(_ source: WidgetSource) {
        var configuration = row
        configuration.source = source
        writeRow(configuration)
    }

    /// The row, spotlight or banner a widget holds; nil for the other kinds.
    private static func rowOf(_ content: HomeWidget.Content) -> RowConfiguration? {
        switch content {
        case .row(let row), .hero(let row), .banner(let row): return row
        case .collection, .continueWatching, .unsupported: return nil
        }
    }

    /// The text trimmed of spaces and new lines, or nil when nothing is left.
    private static func trimmedOrNil(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    /// A token of the sentence. Its id is the field's name, with the value's id when the field holds several values.
    private static func token(_ field: Field, _ text: String, valueID: Int? = nil, removable: Bool = true) -> Part {
        let id = valueID.map { "\(field.rawValue):\($0)" } ?? field.rawValue
        return .token(Token(id: id, field: field, text: text, isRemovable: removable, valueID: valueID))
    }

    /// A clause of the sentence: its lead word, then its tokens.
    private static func clause(_ lead: String, _ tokens: [Part]) -> [Part] {
        [.text(lead)] + tokens
    }

    /// The pieces with a comma between neighbours, and "and" before the last one.
    private static func joined(_ pieces: [[Part]]) -> [Part] {
        var parts: [Part] = []
        for (index, piece) in pieces.enumerated() {
            if index > 0 { parts.append(.text(index == pieces.count - 1 ? "and" : ",")) }
            parts += piece
        }
        return parts
    }

    /// Removes the entry with the id from the query's list for `field`.
    private static func removeNamed(_ id: Int, from field: Field, in query: inout TMDbDiscoverQuery) {
        switch field {
        case .genres: query.genres.removeAll { $0.id == id }
        case .keywords: query.keywords.removeAll { $0.id == id }
        case .excludedKeywords: query.excludedKeywords.removeAll { $0.id == id }
        case .providers: query.providers.removeAll { $0.id == id }
        case .cast: query.cast.removeAll { $0.id == id }
        case .crew: query.crew.removeAll { $0.id == id }
        case .companies: query.companies.removeAll { $0.id == id }
        default: break
        }
    }

    /// Adds the value to the list when it is missing, removes it when it is there. True when it was added.
    @discardableResult
    private static func toggle(_ value: TMDbDiscoverQuery.Named, in list: inout [TMDbDiscoverQuery.Named]) -> Bool {
        if list.contains(where: { $0.id == value.id }) {
            list.removeAll { $0.id == value.id }
            return false
        }
        list.append(value)
        return true
    }

    /// The entries whose name or code contains the text, sorted by name. Blank text keeps them all.
    private static func matching(_ entries: [(code: String, name: String)], _ text: String) -> [(code: String, name: String)] {
        let term = (trimmedOrNil(text) ?? "").lowercased()
        return entries
            .filter { term.isEmpty || $0.name.lowercased().contains(term) || $0.code.lowercased().contains(term) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The value of a list filter in a pill: the first name, with "+n" for the others.
    private static func listValue(_ names: [TMDbDiscoverQuery.Named], none: String) -> String {
        guard let first = names.first else { return none }
        return names.count == 1 ? first.name : "\(first.name) +\(names.count - 1)"
    }

    /// The ordering in a sentence, such as "Trending this week".
    private static func orderingPhrase(_ ordering: TMDbDiscoverQuery.Ordering) -> String {
        switch ordering {
        case .popular: return "Popular"
        case .trendingToday: return "Trending today"
        case .trendingThisWeek: return "Trending this week"
        case .newest: return "Newest"
        case .oldest: return "Oldest"
        }
    }

    /// The period in a sentence, such as "the last 3 months".
    private static func periodPhrase(_ period: TMDbDiscoverQuery.Period) -> String {
        switch period {
        case .lastMonth: return "the last month"
        case .last3Months: return "the last 3 months"
        case .thisYear: return "this year"
        case .lastYear: return "last year"
        case .last5Years: return "the last 5 years"
        case .last10Years: return "the last 10 years"
        }
    }

    /// The score bounds as read in a sentence: "7+", "up to 6" or "7 to 9". Nil when no bound is set.
    private static func scoreText(_ query: TMDbDiscoverQuery) -> String? {
        switch (query.minimumScore, query.maximumScore) {
        case let (low?, high?): return "\(number(low)) to \(number(high))"
        case let (low?, nil): return "\(number(low))+"
        case let (nil, high?): return "up to \(number(high))"
        case (nil, nil): return nil
        }
    }

    /// The runtime bounds in minutes: "90+ min", "under 120 min" or "90 to 120 min". Nil when no bound is set.
    private static func runtimeText(_ query: TMDbDiscoverQuery) -> String? {
        switch (query.minimumRuntime, query.maximumRuntime) {
        case let (low?, high?): return "\(low) to \(high) min"
        case let (low?, nil): return "\(low)+ min"
        case let (nil, high?): return "under \(high) min"
        case (nil, nil): return nil
        }
    }

    /// The release years: "2010 to 2020", "in 2015", "from 2010" or "up to 2020". Nil when no year is set.
    private static func releaseText(_ query: TMDbDiscoverQuery) -> String? {
        ReleaseYears.text(from: query.releasedFrom, to: query.releasedTo)
    }

    /// A score or minute without a trailing ".0": 7 for 7.0, 7.5 for 7.5.
    private static func number(_ value: Double) -> String {
        if let whole = Int(exactly: value) { return String(whole) }
        return String(value)
    }

    /// The language's name in the current locale, or its code in capitals when the locale has no name for it.
    private static func languageName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code.uppercased()
    }

    /// The region's name in the current locale, or its code in capitals when the locale has no name for it.
    private static func regionName(_ code: String) -> String {
        Locale.current.localizedString(forRegionCode: code) ?? code.uppercased()
    }
}

/// The TMDb calls the builder makes, as closures so the tests can answer them without the network. `live` makes them with the token
/// saved in Settings.
struct WidgetBuilderLookups: Sendable {
    /// True when a TMDb Read Access Token is saved. The lookups below answer with empty lists when none is.
    var hasToken: @Sendable () async -> Bool
    var genres: @Sendable (TMDbDiscoverQuery.Kind) async throws -> [TMDbDiscoverQuery.Named]
    var keywords: @Sendable (String) async throws -> [TMDbDiscoverQuery.Named]
    var people: @Sendable (String) async throws -> [TMDbDiscoverQuery.Named]
    var companies: @Sendable (String) async throws -> [TMDbDiscoverQuery.Named]
    var providers: @Sendable (TMDbDiscoverQuery.Kind, String) async throws -> [TMDbDiscoverQuery.Named]

    /// The calls made with the token saved in Settings, read again for each call. Without a token `TMDbRatings` sends no request.
    static func live(services: AppServices) -> WidgetBuilderLookups {
        let client = services.client
        let settings = services.settings
        let token: @Sendable () async -> String = {
            let saved = await settings.load()
            return (saved.tmdbReadToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return WidgetBuilderLookups(
            hasToken: { !(await token()).isEmpty },
            genres: { kind in try await TMDbRatings(client: client, readAccessToken: await token()).genres(kind: kind) },
            keywords: { text in try await TMDbRatings(client: client, readAccessToken: await token()).searchKeywords(text) },
            people: { text in try await TMDbRatings(client: client, readAccessToken: await token()).searchPeople(text) },
            companies: { text in try await TMDbRatings(client: client, readAccessToken: await token()).searchCompanies(text) },
            providers: { kind, region in
                try await TMDbRatings(client: client, readAccessToken: await token()).watchProviders(kind: kind, region: region)
            })
    }
}
