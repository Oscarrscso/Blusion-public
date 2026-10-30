#if canImport(UIKit)
import StremioKit
import SwiftUI

/// The editor panel of one setting, shown at the foot of the screen: the setting's name and a close button, then its choices. A panel is as
/// tall as its content; only the lists that can grow long scroll (see `ScrollsWhenLong`).
struct WidgetFieldPanel: View {
    let model: WidgetBuilderModel
    let field: WidgetBuilderModel.Field
    /// True while a text field in the panel is being edited.
    @Binding var isTyping: Bool
    /// Opens the picker of addon catalogs and Trakt feeds and lists.
    let openSourcePicker: () -> Void
    /// Opens the browser of Trakt lists.
    let openTraktLists: () -> Void
    @Environment(\.layoutMetrics) private var metrics
    @State private var providerText = ""
    @State private var regionText = ""
    @State private var languageText = ""
    @FocusState private var titleFocused: Bool

    init(model: WidgetBuilderModel, field: WidgetBuilderModel.Field, isTyping: Binding<Bool>, openSourcePicker: @escaping () -> Void,
         openTraktLists: @escaping () -> Void) {
        self.model = model
        self.field = field
        _isTyping = isTyping
        self.openSourcePicker = openSourcePicker
        self.openTraktLists = openTraktLists
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(spacing: Theme.Spacing.s) {
                Text(title)
                    .font(.headline)
                Spacer(minLength: 0)
                Button {
                    Haptics.tap()
                    model.selectedField = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .glassCircleButton(.small)
                .accessibilityLabel("Close")
            }
            content
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Not glass: the chips and buttons inside are glass, and glass on glass does not read.
        .translucentPanelSurface()
        .padding(.horizontal, metrics.contentMargin)
        .onDisappear { isTyping = false }
        .accessibilityIdentifier("widgetBuilder.panel.\(field.rawValue)")
    }

    /// The name of the setting, as its panel's header shows it.
    private var title: String {
        switch field {
        case .source: "Source"
        case .ordering: "Order"
        case .period: "Period"
        case .genres: "Genres"
        case .keywords: "Keywords"
        case .excludedKeywords: "Exclude Keywords"
        case .score: "IMDb Score"
        case .votes: "IMDb Votes"
        case .language: "Language"
        case .runtime: "Runtime"
        case .release: "Release Year"
        case .providers: "Watch Providers"
        case .region: "Region"
        case .cast: "Cast"
        case .crew: "Crew"
        case .companies: "Companies"
        case .catalogGenre: "Genre"
        case .traktSort: "Sort"
        case .title: "Title"
        case .limit: "Items"
        case .style: "Style"
        case .cards: "Cards"
        case .posters: "Posters"
        case .shuffle: "Shuffle"
        case .randomSource: "Random Source"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch field {
        case .source: sourceContent
        case .ordering: orderingContent
        case .period: periodContent
        case .genres: genresContent
        case .keywords, .excludedKeywords, .cast, .crew, .companies:
            ValueSearch(model: model, field: field, isTyping: $isTyping)
        case .providers: providersContent
        case .region: regionContent
        case .language: languageContent
        case .score: scoreContent
        case .votes: votesContent
        case .runtime: runtimeContent
        case .release: releaseContent
        case .catalogGenre: catalogGenreContent
        case .traktSort: traktSortContent
        case .title: titleContent
        case .limit: limitContent
        case .style: styleContent
        case .cards: cardsContent
        case .posters: postersContent
        case .shuffle: shuffleContent
        case .randomSource: randomSourceContent
        }
    }

    /// The TMDB list being edited. The panels of TMDB settings only open for a TMDB list, so the empty default is never shown.
    private var query: TMDbDiscoverQuery { model.query ?? TMDbDiscoverQuery() }

    // MARK: Source and ordering

    private var sourceContent: some View {
        VStack(spacing: Theme.Spacing.xs) {
            ChoiceRow(title: "TMDB List", subtitle: "Movies or series by order and filters", isSelected: model.query != nil) {
                model.useTMDbList()
            }
            ChoiceRow(title: "Addon Catalog or Trakt", subtitle: catalogSubtitle, opensScreen: true, action: openSourcePicker)
            if case .traktList = model.row.source {
                ChoiceRow(title: "Browse Trakt Lists", opensScreen: true, action: openTraktLists)
            }
        }
    }

    /// What the source is, for the addon or Trakt row; the picker's hint when the source is a TMDB list or is not set yet.
    private var catalogSubtitle: String {
        switch model.row.source {
        case .addonCatalog, .traktList, .traktFeed: model.sourceDescription
        case .tmdbDiscover, .unsupported: "Pick a catalog from an installed addon, or a Trakt feed or list"
        }
    }

    private var orderingContent: some View {
        VStack(spacing: Theme.Spacing.xs) {
            ForEach(TMDbDiscoverQuery.Ordering.allCases, id: \.self) { ordering in
                ChoiceRow(title: ordering.title, isSelected: query.ordering == ordering) { model.setOrdering(ordering) }
            }
        }
    }

    private var periodContent: some View {
        ChoiceList(rowCount: TMDbDiscoverQuery.Period.allCases.count + 1) {
            ChoiceRow(title: "Any Time", isSelected: query.period == nil) { model.updateQuery { $0.period = nil } }
            ForEach(TMDbDiscoverQuery.Period.allCases, id: \.self) { period in
                ChoiceRow(title: period.title, isSelected: query.period == period) { model.updateQuery { $0.period = period } }
            }
        }
    }

    // MARK: Genres and providers

    private var genresContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            if showsOptionsStatus {
                optionsStatus
            } else {
                ScrollsWhenLong {
                    FlowLayout(spacing: Theme.Spacing.s) {
                        ForEach(model.genreOptions) { genre in
                            GlassChip(genre.name, isSelected: query.genres.contains { $0.id == genre.id }, isCompact: true) {
                                model.toggle(genre, in: .genres)
                            }
                        }
                    }
                }
            }
        }
        .task(id: model.query?.kind) { await model.loadOptions(for: .genres) }
    }

    @ViewBuilder
    private var providersContent: some View {
        let region = query.region ?? model.deviceRegion
        let regionName = Locale.current.localizedString(forRegionCode: region) ?? region
        let term = providerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = model.providerOptions.filter { term.isEmpty || $0.name.localizedCaseInsensitiveContains(term) }
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SearchField(text: $providerText, placeholder: "Search providers", isTyping: $isTyping)
            if showsOptionsStatus {
                optionsStatus
            } else {
                ScrollsWhenLong {
                    FlowLayout(spacing: Theme.Spacing.s) {
                        ForEach(matches) { provider in
                            GlassChip(provider.name, isSelected: query.providers.contains { $0.id == provider.id }, isCompact: true) {
                                model.toggle(provider, in: .providers)
                            }
                        }
                    }
                }
            }
            Text("Shown for \(regionName). Change it with Region.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .task(id: "\(query.kind.rawValue)/\(region)") { await model.loadOptions(for: .providers) }
    }

    /// True while a list of options loads or could not be loaded, so the list gives way to a spinner or the reason.
    private var showsOptionsStatus: Bool { model.isLoadingOptions || model.optionsMessage != nil }

    @ViewBuilder
    private var optionsStatus: some View {
        if model.isLoadingOptions {
            Spinner()
                .frame(maxWidth: .infinity)
        } else if let message = model.optionsMessage {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Region and language

    private var regionContent: some View {
        let regions = WidgetBuilderModel.regions(matching: regionText).map { CodedName(code: $0.code, name: $0.name) }
        let deviceName = Locale.current.localizedString(forRegionCode: model.deviceRegion) ?? model.deviceRegion
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SearchField(text: $regionText, placeholder: "Search countries", isTyping: $isTyping)
            ChoiceList(rowCount: regions.count + 1) {
                ChoiceRow(title: "Device Region (\(deviceName))", isSelected: query.region == nil) {
                    model.updateQuery { $0.region = nil }
                }
                ForEach(regions) { region in
                    ChoiceRow(title: region.name, isSelected: query.region == region.code) {
                        model.updateQuery { $0.region = region.code }
                    }
                }
            }
        }
    }

    private var languageContent: some View {
        let languages = WidgetBuilderModel.languages(matching: languageText).map { CodedName(code: $0.code, name: $0.name) }
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SearchField(text: $languageText, placeholder: "Search languages", isTyping: $isTyping)
            ChoiceList(rowCount: languages.count + 1) {
                ChoiceRow(title: "Any Language", isSelected: query.language == nil) { model.updateQuery { $0.language = nil } }
                ForEach(languages) { language in
                    ChoiceRow(title: language.name, isSelected: query.language == language.code) {
                        model.updateQuery { $0.language = language.code }
                    }
                }
            }
        }
    }

    // MARK: Score, votes and runtime

    private var scoreContent: some View {
        let low = query.minimumScore ?? 0
        let high = query.maximumScore ?? 10
        return VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            // Moving one bound past the other moves the other along with it.
            scoreSlider("At least", value: low, neutral: 0) { setScore(low: $0, high: max($0, high)) }
            scoreSlider("At most", value: high, neutral: 10) { setScore(low: min(low, $0), high: $0) }
        }
    }

    /// One bound of the score: a slider from 0 to 10 in halves, its value at the trailing edge. The neutral end reads "Any".
    private func scoreSlider(_ title: String, value: Double, neutral: Double, update: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Text(value == neutral ? "Any" : ScoreText.wholeScore(value))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { value }, set: { next in
                if next != value { Haptics.selection() }
                update(next)
            }), in: 0...10, step: 0.5)
                .accessibilityLabel(title)
        }
    }

    /// Stores both score bounds. 0 for the minimum and 10 for the maximum are no bound, so they are stored as nil.
    private func setScore(low: Double, high: Double) {
        model.updateQuery { edited in
            edited.minimumScore = low > 0 ? low : nil
            edited.maximumScore = high < 10 ? high : nil
        }
    }

    /// On IMDb's scale, where a well-known film has hundreds of thousands of votes.
    private static let voteChoices = [1_000, 5_000, 10_000, 25_000, 50_000, 100_000, 250_000]

    private var votesContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            FlowLayout(spacing: Theme.Spacing.s) {
                GlassChip("Any", isSelected: query.minimumVotes == nil, isCompact: true) { model.updateQuery { $0.minimumVotes = nil } }
                ForEach(Self.voteChoices, id: \.self) { votes in
                    GlassChip("\(votes.formatted())+", isSelected: query.minimumVotes == votes, isCompact: true) {
                        model.updateQuery { $0.minimumVotes = votes }
                    }
                }
            }
            NumberField(placeholder: "Custom", text: votesText, isTyping: $isTyping)
        }
    }

    /// The custom vote count as typed. Only digits are kept, and an empty field means no minimum.
    private var votesText: Binding<String> {
        Binding(get: { query.minimumVotes.map { String($0) } ?? "" }, set: { text in
            let votes = Int(Self.digits(text, limit: 7))
            model.updateQuery { $0.minimumVotes = votes }
        })
    }

    /// A runtime preset: the bounds it sets, in minutes.
    private struct RuntimePreset: Identifiable {
        let title: String
        let low: Int?
        let high: Int?
        var id: String { title }
    }

    private static let runtimePresets = [
        RuntimePreset(title: "Any", low: nil, high: nil),
        RuntimePreset(title: "Under 90 min", low: nil, high: 90),
        RuntimePreset(title: "90 to 120 min", low: 90, high: 120),
        RuntimePreset(title: "Over 120 min", low: 120, high: nil),
    ]

    private var runtimeContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            FlowLayout(spacing: Theme.Spacing.s) {
                ForEach(Self.runtimePresets) { preset in
                    GlassChip(preset.title, isSelected: query.minimumRuntime == preset.low && query.maximumRuntime == preset.high,
                              isCompact: true) {
                        model.updateQuery {
                            $0.minimumRuntime = preset.low
                            $0.maximumRuntime = preset.high
                        }
                    }
                }
            }
            HStack(spacing: Theme.Spacing.s) {
                NumberField(placeholder: "From (min)", text: runtimeText(\.minimumRuntime), isTyping: $isTyping)
                NumberField(placeholder: "To (min)", text: runtimeText(\.maximumRuntime), isTyping: $isTyping)
            }
        }
    }

    /// A runtime bound as typed, in minutes from 1 to 999. An empty or out-of-range field means no bound.
    private func runtimeText(_ keyPath: WritableKeyPath<TMDbDiscoverQuery, Int?>) -> Binding<String> {
        Binding(get: { query[keyPath: keyPath].map { String($0) } ?? "" }, set: { text in
            let minutes = Int(Self.digits(text, limit: 3)).flatMap { (1...999).contains($0) ? $0 : nil }
            model.updateQuery { $0[keyPath: keyPath] = minutes }
        })
    }

    // MARK: Release years

    /// Whole years: From is 1 January of its year and To is 31 December of its (see `ReleaseYears`).
    private var releaseContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            yearRow("From", text: query.releasedFrom, date: ReleaseYears.from) { value in model.updateQuery { $0.releasedFrom = value } }
            yearRow("To", text: query.releasedTo, date: ReleaseYears.to) { value in model.updateQuery { $0.releasedTo = value } }
            Text("Setting a year replaces the period.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// One end of the release years: a year picker and a Clear button when it has a year, or an Add Year button when it has none. A saved
    /// date shows its year, and keeps its day until another year is picked. `date` gives the date saved for a year picked.
    private func yearRow(_ title: String, text: String?, date: @escaping (Int) -> String,
                         update: @escaping (String?) -> Void) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 0)
            if let year = ReleaseYears.year(of: text) {
                Picker(title, selection: Binding(get: { year }, set: { picked in
                    if let value = ReleaseYears.edit(shown: year, picked: picked, date: date) { update(value) }
                })) {
                    ForEach(ReleaseYears.offered(including: year), id: \.self) { Text(verbatim: String($0)).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                Button("Clear") { update(nil) }
                    .buttonStyle(.glassCapsule)
            } else {
                Button("Add Year") { update(date(ReleaseYears.current())) }
                    .buttonStyle(.glassCapsule)
            }
        }
    }

    // MARK: Catalogs and Trakt

    private var catalogGenreContent: some View {
        ChoiceList(rowCount: model.catalogGenres.count + 1) {
            ChoiceRow(title: "All Genres", isSelected: catalogGenre == nil) { model.setCatalogGenre(nil) }
            ForEach(model.catalogGenres, id: \.self) { genre in
                ChoiceRow(title: genre, isSelected: genre == catalogGenre) { model.setCatalogGenre(genre) }
            }
        }
    }

    /// The genre a catalog is filtered to, or nil.
    private var catalogGenre: String? {
        if case .addonCatalog(let reference) = model.row.source { return reference.genre }
        return nil
    }

    private var traktSortContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            ChoiceList(rowCount: TraktListSort.allCases.count + 1) {
                ChoiceRow(title: "List Default", isSelected: model.traktSort == nil) { model.setTraktSort(nil) }
                ForEach(TraktListSort.allCases) { sort in
                    ChoiceRow(title: sort.title, isSelected: model.traktSort == sort) { model.setTraktSort(sort) }
                }
            }
            Text("List Default keeps the order the list's owner chose.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Title and items

    private var titleContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            TextField(model.autoTitle, text: Binding(get: { model.customTitle }, set: { model.setCustomTitle($0) }))
                .focused($titleFocused)
                .submitLabel(.done)
                .onSubmit { titleFocused = false }
                .panelField()
                .accessibilityIdentifier("widgetEditor.title")
                .onChange(of: titleFocused) { _, focused in isTyping = focused }
            Toggle("Hide title on Home", isOn: Binding(get: { model.hidesTitle }, set: { model.setHideTitle($0) }))
        }
    }

    private var limitContent: some View {
        FlowLayout(spacing: Theme.Spacing.s) {
            ForEach(model.limitChoices, id: \.self) { count in
                GlassChip("\(count)", isSelected: model.row.limit == count, isCompact: true) {
                    model.updateRow { $0.limit = count }
                }
            }
        }
        .accessibilityIdentifier("widgetEditor.items")
    }

    // MARK: Style and cards

    private var styleContent: some View {
        VStack(spacing: Theme.Spacing.xs) {
            ForEach(WidgetStyle.allCases) { style in
                ChoiceRow(title: style.rawValue, isSelected: model.style == style) { model.setStyle(style) }
            }
        }
        .accessibilityIdentifier("widgetEditor.style")
    }

    @ViewBuilder
    private var cardsContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            if model.style == .row {
                labelled("Shape") {
                    FlowLayout(spacing: Theme.Spacing.s) {
                        ForEach(WidgetPresentation.AspectRatio.allCases, id: \.self) { ratio in
                            GlassChip(ratio.rawValue.capitalized, isSelected: model.row.presentation.aspectRatio == ratio, isCompact: true) {
                                model.updateRow { $0.presentation.aspectRatio = ratio }
                            }
                        }
                    }
                }
                labelled("Size") {
                    FlowLayout(spacing: Theme.Spacing.s) {
                        ForEach(WidgetPresentation.CardStyle.allCases, id: \.self) { size in
                            GlassChip(size.rawValue.capitalized, isSelected: model.row.presentation.cardStyle == size, isCompact: true) {
                                model.updateRow { $0.presentation.cardStyle = size }
                            }
                        }
                    }
                }
                Toggle("Numbered (top list)", isOn: presentationBinding(\.showsRank))
                    .accessibilityIdentifier("widgetEditor.numbered")
            }
            Toggle("Show ratings", isOn: presentationBinding(\.showsRatings))
        }
    }

    // MARK: Posters

    private var postersContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Toggle("Use Better Posters addon", isOn: presentationBinding(\.usesBetterPosters))
                .accessibilityIdentifier("widgetEditor.betterPosters")
            Text("""
                Poster cards take their artwork from the BetterPosters addon (btttr.cc), which draws a tag, the genre and the IMDb rating on \
                each poster. A title it has no artwork for keeps its usual poster. Wide and square cards are not changed.
                """)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// When this widget's titles take a new random order: on the widgets page's schedule, never, or on one of its own.
    private var shuffleContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            ChoiceList(rowCount: WidgetShuffle.choices.count + 1) {
                ChoiceRow(title: WidgetBuilderModel.shuffleText(nil), isSelected: model.row.shuffle == nil) {
                    model.updateRow { $0.shuffle = nil }
                }
                ForEach(WidgetShuffle.choices, id: \.self) { choice in
                    ChoiceRow(title: WidgetBuilderModel.shuffleText(choice), isSelected: model.row.shuffle == choice) {
                        model.updateRow { $0.shuffle = choice }
                    }
                }
            }
            Text("""
                Shuffles the order of this widget's titles. An order stays until its next shuffle. Like Other Widgets follows the Shuffle \
                setting on the widgets page.
                """)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// A source picked at random for this widget: from every catalog, or from the ones ticked, picked again on a schedule. Home names
    /// the widget after the source it picked.
    private var randomSourceContent: some View {
        let random = model.row.randomSource
        let schedules = WidgetShuffle.choices.filter { $0 != .off }
        return VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            ChoiceList(rowCount: 2) {
                ChoiceRow(title: "Off", isSelected: random == nil) { model.setRandomSource(nil) }
                ChoiceRow(title: "All Sources", isSelected: random?.usesAllSources == true) {
                    model.setRandomSource(RandomSource(schedule: random?.schedule ?? .daily))
                }
            }
            labelled("Pick From") {
                ChoiceList(rowCount: model.randomSourceChoices.count) {
                    ForEach(model.randomSourceChoices) { choice in
                        let source = WidgetSource.addonCatalog(choice.reference)
                        ChoiceRow(title: choice.title, subtitle: choice.addonName, isSelected: random?.sources.contains(source) == true) {
                            model.toggleRandomSource(source)
                        }
                    }
                }
            }
            if random != nil {
                labelled("New Source") {
                    ChoiceList(rowCount: schedules.count) {
                        ForEach(schedules, id: \.self) { schedule in
                            ChoiceRow(title: WidgetBuilderModel.shuffleText(schedule), isSelected: random?.schedule == schedule) {
                                model.setRandomSourceSchedule(schedule)
                            }
                        }
                    }
                }
            }
            Text("""
                Home shows this widget with a source picked at random, from every catalog or from the ones ticked, named after the source, \
                and picks again on the New Source schedule. With none ticked, it picks from every catalog.
                """)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Helpers

    /// A binding to one of the row's presentation settings, written back through the model.
    private func presentationBinding<Value>(_ keyPath: WritableKeyPath<WidgetPresentation, Value>) -> Binding<Value> {
        Binding(get: { model.row.presentation[keyPath: keyPath] }, set: { value in
            model.updateRow { $0.presentation[keyPath: keyPath] = value }
        })
    }

    /// A small heading over a group of choices.
    private func labelled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    /// The digits of `text`, at most `limit` of them.
    private static func digits(_ text: String, limit: Int) -> String {
        String(text.filter { $0.isASCII && $0.isNumber }.prefix(limit))
    }
}

/// The search for the values a list filter takes (keywords, people or companies): the values chosen so far as chips that remove on tap,
/// and the matches for the typed text as rows that add or remove on tap. The matches come from TMDB after a short pause in typing.
private struct ValueSearch: View {
    let model: WidgetBuilderModel
    let field: WidgetBuilderModel.Field
    @Binding var isTyping: Bool
    @State private var text = ""
    @State private var matches: [TMDbDiscoverQuery.Named] = []
    /// The text `matches` answers, so "Nothing found." is said only once the answer to the typed text has come.
    @State private var matchedText: String?

    init(model: WidgetBuilderModel, field: WidgetBuilderModel.Field, isTyping: Binding<Bool>) {
        self.model = model
        self.field = field
        _isTyping = isTyping
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SearchField(text: $text, placeholder: placeholder, isTyping: $isTyping)
            ScrollsWhenLong {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    if !chosen.isEmpty {
                        FlowLayout(spacing: Theme.Spacing.s) {
                            ForEach(chosen) { value in
                                GlassChip(value.name, isSelected: true, isCompact: true) { model.toggle(value, in: field) }
                            }
                        }
                    }
                    results
                }
            }
        }
        .task(id: text) {
            // A search waits for a pause in typing, and an answer for text that has since changed is dropped.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let asked = text
            let found = await model.suggestions(for: field, matching: asked)
            guard !Task.isCancelled else { return }
            matches = found
            matchedText = asked
        }
    }

    @ViewBuilder
    private var results: some View {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("Type to search TMDB.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if matches.isEmpty {
            if matchedText == text {
                Text("Nothing found.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(matches) { match in
                ChoiceRow(title: match.name, isSelected: chosen.contains { $0.id == match.id }) { model.toggle(match, in: field) }
            }
        }
    }

    /// The values the field holds now.
    private var chosen: [TMDbDiscoverQuery.Named] {
        let query = model.query ?? TMDbDiscoverQuery()
        switch field {
        case .keywords: return query.keywords
        case .excludedKeywords: return query.excludedKeywords
        case .cast: return query.cast
        case .crew: return query.crew
        case .companies: return query.companies
        default: return []
        }
    }

    private var placeholder: String {
        switch field {
        case .keywords: "Search keywords"
        case .excludedKeywords: "Search keywords to leave out"
        case .cast: "Search actors"
        case .crew: "Search directors, writers and crew"
        default: "Search studios and companies"
        }
    }
}

/// A row of a list of choices: its title, an optional grey line under it, and a checkmark when it is the current choice or a chevron for a
/// row that opens another screen. The whole row is the button.
private struct ChoiceRow: View {
    let title: String
    var subtitle: String?
    var isSelected = false
    var opensScreen = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.semibold))
                } else if opensScreen {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, Theme.Spacing.m)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(isSelected ? Theme.surface : Color.clear, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerFeedback()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The rounded search field of a panel: a magnifying glass, the text and a clear button. It reports focus through `isTyping`.
private struct SearchField: View {
    let placeholder: String
    @Binding var text: String
    @Binding var isTyping: Bool
    @FocusState private var isFocused: Bool

    init(text: Binding<String>, placeholder: String, isTyping: Binding<Bool>) {
        _text = text
        self.placeholder = placeholder
        _isTyping = isTyping
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .focused($isFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit { isFocused = false }
            if !text.isEmpty {
                Button {
                    Haptics.tap()
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .panelField()
        .onChange(of: isFocused) { _, focused in isTyping = focused }
    }
}

/// A field for a number, typed with the number pad. Its text binding keeps only the digits. It reports focus through `isTyping`. The
/// screen gives the pad its Done key.
private struct NumberField: View {
    let placeholder: String
    let text: Binding<String>
    @Binding var isTyping: Bool
    @FocusState private var isFocused: Bool

    init(placeholder: String, text: Binding<String>, isTyping: Binding<Bool>) {
        self.placeholder = placeholder
        self.text = text
        _isTyping = isTyping
    }

    var body: some View {
        TextField(placeholder, text: text)
            .keyboardType(.numberPad)
            .focused($isFocused)
            .panelField()
            .onChange(of: isFocused) { _, focused in isTyping = focused }
    }
}

/// A list of one-line choices that may run to hundreds of rows (every country, every language): as tall as its rows up to 260 points,
/// then scrolling, and built row by row as it scrolls.
private struct ChoiceList<Content: View>: View {
    let rowCount: Int
    let content: () -> Content

    init(rowCount: Int, @ViewBuilder content: @escaping () -> Content) {
        self.rowCount = rowCount
        self.content = content
    }

    /// The height of `rowCount` rows of the least height a row has, with the gaps between them.
    private var rowsHeight: CGFloat {
        CGFloat(rowCount) * 44 + CGFloat(max(rowCount - 1, 0)) * Theme.Spacing.xs
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Spacing.xs) {
                content()
            }
        }
        .scrollIndicators(.visible, axes: .vertical)
        .scrollIndicatorsFlash(onAppear: true)
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .frame(height: min(260, rowsHeight))
    }
}

/// Content that is as tall as it needs to be up to 260 points, then scrolls. Only the lists that can grow long use it, so the rest of a
/// panel never scrolls.
private struct ScrollsWhenLong<Content: View>: View {
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            content()
            ScrollView {
                content()
            }
            .scrollIndicators(.visible, axes: .vertical)
            .scrollIndicatorsFlash(onAppear: true)
            .scrollDismissesKeyboard(.interactively)
        }
        .frame(maxHeight: 260)
    }
}

/// A coded name from the region and language lists, identified by its code.
private struct CodedName: Identifiable {
    let code: String
    let name: String
    var id: String { code }
}

private extension View {
    /// A text field of a panel: a rounded surface like the rows, at least 44 points tall and as wide as the panel.
    func panelField() -> some View {
        padding(.horizontal, Theme.Spacing.m)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
    }
}
#endif
