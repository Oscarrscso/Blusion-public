#if canImport(UIKit)
import PlayerKit
import StremioKit
import SwiftUI
import UIKit

/// The player's episode picker: the series' seasons and episodes in a sheet over the player. A tap reads that episode's streams and
/// hands the player a plan for it, as Up Next does at the end of an episode.
struct PlayerEpisodePicker: View {
    /// Reads the chosen episode's streams and returns the plan to play, or nil when none can be played.
    let prepare: (StreamRequest) async -> PlaybackPlan?
    /// The plan is ready: the player moves to it.
    let onPlay: (PlaybackPlan) -> Void

    @State private var model: PlayerEpisodePickerModel
    @State private var prepareTask: Task<Void, Never>?
    @State private var playFailure: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPhoneLandscape) private var isPhoneLandscape

    init(current: StreamRequest, services: AppServices,
         prepare: @escaping (StreamRequest) async -> PlaybackPlan?, onPlay: @escaping (PlaybackPlan) -> Void) {
        self.prepare = prepare
        self.onPlay = onPlay
        _model = State(initialValue: PlayerEpisodePickerModel(request: current, services: services))
    }

    /// `isPhoneLandscape` is also true on an iPad turned sideways, so the device is checked as well. A phone in landscape has no room for
    /// a title above the episodes, so it is left out there.
    private var isPhoneInLandscape: Bool { isPhoneLandscape && UIDevice.current.userInterfaceIdiom == .phone }

    var body: some View {
        NavigationStack {
            List {
                if model.isLoading {
                    HStack {
                        Spacer()
                        Spinner().controlSize(.large)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                } else if let failure = model.failure {
                    Text(failure).font(.subheadline).foregroundStyle(.secondary)
                } else {
                    if model.seasons.count > 1 {
                        Section {
                            seasonMenu
                        }
                    }
                    Section {
                        ForEach(model.episodes) { episode in
                            row(episode)
                        }
                    }
                }
            }
            .navigationTitle(isPhoneInLandscape ? "" : "Episodes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await model.load() }
            .onDisappear { prepareTask?.cancel() }
            .alert("Episode unavailable", isPresented: Binding(get: { playFailure != nil },
                                                               set: { if !$0 { playFailure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(playFailure ?? "")
            }
            .accessibilityIdentifier("player.episodePicker")
        }
    }

    private var seasonMenu: some View {
        Menu {
            ForEach(model.seasons, id: \.self) { season in
                Button(PlayerEpisodePickerModel.seasonName(season)) { model.selectSeason(season) }
            }
        } label: {
            HStack {
                Text(model.selectedSeason.map(PlayerEpisodePickerModel.seasonName) ?? "Season")
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
            .frame(maxWidth: .infinity)
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
                ArtworkImage(url: video.thumbnail, title: video.title, maxPixelSize: 240)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(width: 96, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    if let number = video.episode {
                        Text("Episode \(number)").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    }
                    Text(video.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                Spacer(minLength: 8)
                if isPreparing {
                    Spinner().controlSize(.small)
                } else if isCurrent {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
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
