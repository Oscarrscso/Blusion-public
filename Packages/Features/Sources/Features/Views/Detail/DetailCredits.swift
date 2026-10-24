#if canImport(UIKit)
import SwiftUI
import StremioKit
import UIKit

/// The title's cast and crew, with photos from TMDb when it has them and the addon's plain names when it does not. On iPhone the information
/// block follows them; on Mac it sits at the top of the page instead.
struct DetailCredits: View {
    let model: DetailViewModel
    let contentMargin: CGFloat
    /// The page's width, so four whole cast cards fit across it.
    let pageWidth: CGFloat
    @Environment(\.layoutMetrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.titleSectionSpacing) {
            if let group = model.shownCreditGroup, let people = model.shownCredits, !people.isEmpty {
                VStack(alignment: .leading, spacing: metrics.headerSpacing) {
                    // TMDb's cast and crew, one part at a time, with photos. The heading is the part shown and the menu of the others.
                    CreditGroupMenu(groups: model.creditGroups, shown: group, playColourHex: model.playColourHex) { model.creditGroup = $0 }
                        .padding(.horizontal, contentMargin)
                    // Four whole cards across the page, the fifth peeking in; never wider than a shelf's usual card.
                    let cardWidth = CastCardLayout.cardWidth(pageWidth: pageWidth, margin: contentMargin, spacing: metrics.cardSpacing,
                                                             maximum: metrics.posterWidth)
                    // Keyed on the width, so the row measures its height again when the cards change size (the phone turned). Each
                    // photo loads as its card scrolls on, behind the rest of the page. A part has a row of its own, so it starts at its
                    // first card.
                    ShelfScroll(margin: contentMargin, spacing: metrics.cardSpacing, resetKey: "\(Int(cardWidth))") {
                        ForEach(people) { PersonCardLink(person: $0, width: cardWidth).reportsShelfEdge(id: $0.id) }
                    }
                    .id(group)
                    .accessibilityIdentifier("detail.castCarousel")
                }
                .sensoryFeedback(.selection, trigger: model.creditGroup)
            } else if model.isLoadingCredits {
                VStack(alignment: .leading, spacing: metrics.headerSpacing) {
                    DetailSkeletonLine(font: .subheadline.weight(.semibold), width: 48)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .padding(.horizontal, contentMargin)
                    let width = CastCardLayout.cardWidth(pageWidth: pageWidth, margin: contentMargin,
                                                         spacing: metrics.cardSpacing, maximum: metrics.posterWidth)
                    ShelfScroll(margin: contentMargin, spacing: metrics.cardSpacing) {
                        ForEach(0..<6, id: \.self) { index in
                            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                                RoundedRectangle(cornerRadius: Theme.Radius.poster)
                                    .fill(Theme.placeholder)
                                    .frame(width: width, height: width * 1.5)
                                    .loadingCardSpinner()
                                VStack(alignment: .leading, spacing: 2) {
                                    DetailSkeletonLine(font: width < metrics.posterWidth ? .caption.weight(.semibold) : Theme.Typography.cardTitle,
                                                       width: width * 0.85)
                                    DetailSkeletonLine(font: width < metrics.posterWidth ? .caption2 : Theme.Typography.cardSubtitle,
                                                       width: width * 0.6)
                                }
                                .frame(width: width, alignment: .leading)
                            }
                            .reportsShelfEdge(id: index)
                        }
                    }
                    .allowsHitTesting(false)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Loading cast and crew")
                .transition(.opacity)
            } else if !model.detail.cast.isEmpty {
                VStack(alignment: .leading, spacing: metrics.headerSpacing) {
                    // Without TMDb (no read token, or it did not answer) the addon's names still show, as initials, and open nothing.
                    SectionHeader("Cast & Crew")
                        .padding(.horizontal, contentMargin)
                    ShelfScroll(margin: contentMargin, spacing: metrics.cardSpacing) {
                            ForEach(model.detail.cast, id: \.self) { name in
                                VStack(spacing: 8) {
                                    Text(name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined())
                                        .font(.title2.weight(.medium))
                                        .frame(width: metrics.avatarSize, height: metrics.avatarSize)
                                        .background(Theme.surfaceStrong, in: Circle())
                                    Text(name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                                }
                                .frame(width: metrics.avatarSize + 12)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(name)
                                .reportsShelfEdge(id: name)
                            }
                    }
                }
            }
            // The information follows the cast and crew on iPhone and on the Mac alike.
            DetailInformation(model: model)
                .frame(maxWidth: metrics.readableWidth, alignment: .leading)
                .padding(.horizontal, contentMargin)
        }
        .detailLoadingTransition(model.isLoadingCredits)
        .environment(\.showsArtworkLoadingSpinner, true)
    }
}

/// The compact coloured glass control for Cast and the other credit groups. Picking one shows its people.
private struct CreditGroupMenu: View {
    let groups: [TitleCreditGroup]
    let shown: TitleCreditGroup
    let playColourHex: String?
    let pick: (TitleCreditGroup) -> Void

    @ViewBuilder
    var body: some View {
        if groups.count > 1 {
            menu
        } else {
            // Keep the coloured glass when there is only one group; only the menu and its chevron are unnecessary.
            groupLabel
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var menu: some View {
        Menu {
            ForEach(groups) { group in
                Button {
                    // The part already shown stays as it is, without a tick.
                    if group != shown { pick(group) }
                } label: {
                    if group == shown { Label(group.title, systemImage: "checkmark") } else { Text(group.title) }
                }
            }
        } label: {
            groupLabel
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Still the section's heading, so the headings rotor finds it.
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel("Cast and Crew")
        .accessibilityValue(shown.title)
        .accessibilityHint("Shows another part of the cast and crew")
        .accessibilityIdentifier("detail.creditsMenu")
    }

    private var groupLabel: some View {
        HStack(spacing: 4) {
            Text(shown.title)
                .font(.subheadline.weight(.semibold))
            if groups.count > 1 {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 28)
        // The tint belongs to the glass inside the label, just like Sort and AI, so it travels with the system menu animation.
        .glassEffect(.regular.interactive().tint((PlayColourStore.colour(hex: playColourHex) ?? .clear).opacity(0.25)), in: .capsule)
        .animation(.smooth(duration: 0.3), value: playColourHex)
        .contentShape(Capsule())
        .pointerFeedback()
    }
}
#endif
