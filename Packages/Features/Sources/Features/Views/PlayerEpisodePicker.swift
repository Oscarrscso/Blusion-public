#if canImport(UIKit)
import PlayerKit
import StremioKit
import SwiftUI
import UIKit

/// The player's episode picker: the series' seasons and episodes in a glass panel that drops from the Episodes button, in the same style
/// as the options panel. A tap reads that episode's streams and hands the player a plan for it, as Up Next does at the end of an episode.
struct PlayerEpisodePicker: View {
    /// Reads the chosen episode's streams and returns the plan to play, or nil when none can be played.
    let prepare: (StreamRequest) async -> PlaybackPlan?
    /// The plan is ready: the player moves to it.
    let onPlay: (PlaybackPlan) -> Void
    let onClose: () -> Void

    @State private var model: PlayerEpisodePickerModel
    @State private var prepareTask: Task<Void, Never>?
    @State private var playFailure: String?

    init(current: StreamRequest, services: AppServices,
         prepare: @escaping (StreamRequest) async -> PlaybackPlan?, onPlay: @escaping (PlaybackPlan) -> Void,
         onClose: @escaping () -> Void) {
        self.prepare = prepare
        self.onPlay = onPlay
        self.onClose = onClose
        _model = State(initialValue: PlayerEpisodePickerModel(request: current, services: services))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    content
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                }
                .scrollIndicators(.visible)
                .scrollBounceBehavior(.basedOnSize)
                // Opens on the episode playing, and on a season's first episode when the season changes.
                .onChange(of: model.episodes.map(\.id)) { _, _ in
                    if let current = model.episodes.first(where: model.isCurrent) {
                        proxy.scrollTo(current.id, anchor: .center)
                    } else if let first = model.episodes.first {
                        proxy.scrollTo(first.id, anchor: .top)
                    }
                }
            }
        }
        .clipShape(.rect(cornerRadius: 24))
        .glassEffect(.regular.tint(.black.opacity(0.32)), in: .rect(cornerRadius: 24))
        .foregroundStyle(.white)
        .tint(.white)
        .task { await model.load() }
        .onDisappear { prepareTask?.cancel() }
        .alert("Episode unavailable", isPresented: Binding(get: { playFailure != nil },
                                                           set: { if !$0 { playFailure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(playFailure ?? "")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.episodePicker")
    }

    /// The panel's title, or the season menu when there is more than one season, and its close button.
    private var header: some View {
        HStack {
            if !model.isLoading && model.failure == nil && model.seasons.count > 1 {
                seasonMenu
            } else {
                Text("Episodes")
                    .font(.headline)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 12)
            Button(action: onClose) {
                Image(systemName: "xmark").frame(width: 32, height: 32)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            #if !targetEnvironment(macCatalyst)
            .keyboardShortcut(.escape, modifiers: [])
            #endif
            .accessibilityLabel("Close")
            .accessibilityIdentifier("player.episodePicker.close")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            Spinner().controlSize(.large)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else if let failure = model.failure {
            Text(failure).font(.subheadline).foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 4)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(model.episodes) { episode in
                    row(episode)
                        .id(episode.id)
                    if episode.id != model.episodes.last?.id {
                        Divider().padding(.leading, 14)
                    }
                }
            }
            .background(.white.opacity(0.065), in: .rect(cornerRadius: 18))
        }
    }

    private var seasonMenu: some View {
        Menu {
            ForEach(model.seasons, id: \.self) { season in
                Button(PlayerEpisodePickerModel.seasonName(season)) { Task { await model.selectSeason(season) } }
            }
        } label: {
            HStack(spacing: 6) {
                Text(model.selectedSeason.map(PlayerEpisodePickerModel.seasonName) ?? "Season")
                    .font(.headline)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .contentShape(.rect)
        }
        .accessibilityIdentifier("player.seasonPicker")
    }

    private func row(_ video: Video) -> some View {
        let airsLater = !video.hasAired()
        let isCurrent = model.isCurrent(video)
        let isPreparing = model.preparingID == video.id
        return Button {
            choose(video)
        } label: {
            HStack(spacing: 12) {
                ArtworkImage(url: video.thumbnail, title: video.title, maxPixelSize: nil)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(width: 96, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if let number = video.episode {
                            Text("Episode \(number)")
                        }
                        if let number = video.episode, let score = model.imdbScores[number] {
                            HStack(spacing: 3) {
                                ReviewSiteIcon(site: .imdb, size: 14)
                                Text(String(Int((score * 10).rounded())))
                                    .monospacedDigit()
                            }
                            .accessibilityLabel("IMDb rating \(score, format: .number.precision(.fractionLength(1))) out of 10")
                        }
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.6))
                    Text(video.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                if isPreparing {
                    Spinner().controlSize(.small)
                } else if isCurrent {
                    Image(systemName: "checkmark").font(.body.weight(.semibold))
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(airsLater || model.preparingID != nil)
        .opacity(airsLater ? 0.45 : 1)
        .accessibilityIdentifier("player.episode.\(video.id)")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private func choose(_ video: Video) {
        guard model.preparingID == nil, let request = model.request(for: video) else { return }
        Haptics.tap()
        model.beginPreparing(video)
        prepareTask = Task {
            let plan = await prepare(request)
            guard !Task.isCancelled else { return }
            model.endPreparing()
            if let plan {
                onPlay(plan)
            } else {
                playFailure = "This episode's streams couldn't be played."
            }
        }
    }
}
#endif
