#if canImport(UIKit)
import SwiftUI

/// The page Mac Settings shows to the right of the page it was opened from (Appearance → Colour beside Appearance), as the list opens a
/// page beside itself. Only Mac Settings provides one (see `SettingsView`); without it a `SettingsSubpageLink` pushes its page.
@MainActor
@Observable
final class SettingsSidePage {
    /// The open row's identity, which lights it.
    private(set) var openID: String?
    private(set) var page: AnyView?

    /// Opens `id`'s page, or closes it when it is already open.
    func toggle(_ id: String, page: () -> AnyView) {
        if openID == id {
            close()
        } else {
            openID = id
            self.page = page()
        }
    }

    func close() {
        openID = nil
        page = nil
    }
}

extension EnvironmentValues {
    @Entry var settingsSidePage: SettingsSidePage? = nil
}

/// A Settings page's row that opens a page of its own: pushed on iPhone, beside the page in Mac Settings, where the open row is lit and
/// choosing it again closes the page.
struct SettingsSubpageLink<Label: View, Destination: View>: View {
    let id: String
    @ViewBuilder let destination: () -> Destination
    @ViewBuilder let label: () -> Label
    @Environment(\.settingsSidePage) private var sidePage

    init(id: String, @ViewBuilder destination: @escaping () -> Destination, @ViewBuilder label: @escaping () -> Label) {
        self.id = id
        self.destination = destination
        self.label = label
    }

    var body: some View {
        if let sidePage {
            let isOpen = sidePage.openID == id
            Button {
                Haptics.play(.buttons)
                withAnimation(.smooth(duration: 0.25)) { sidePage.toggle(id) { AnyView(destination()) } }
            } label: {
                HStack {
                    label()
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.hoverPlain)
            .listRowBackground(SettingsRowBackground(isSelected: isOpen))
            .accessibilityAddTraits(isOpen ? .isSelected : [])
        } else {
            NavigationLink(destination: destination, label: label)
        }
    }
}

#if targetEnvironment(macCatalyst)
/// Mac Settings' detail: the chosen page, and the page opened from it in a column to its right. A window too narrow for both shows the
/// opened page alone until it is closed. Its Close button sits at the trailing corner, clear of the navigation over the window's centre.
struct SettingsDetailColumns<Page: View>: View {
    let sidePage: SettingsSidePage
    @ViewBuilder let page: () -> Page

    /// The page's width beside an opened page, and the narrowest the detail can be to show both.
    private static var pageWidth: CGFloat { 400 }
    private static var splitWidth: CGFloat { 760 }

    var body: some View {
        GeometryReader { geometry in
            let splits = geometry.size.width >= Self.splitWidth
            HStack(spacing: 0) {
                // One view throughout, so the page keeps its place and state as the column opens and closes.
                page()
                    .environment(\.settingsSidePage, sidePage)
                    .frame(width: sidePage.page == nil ? geometry.size.width : (splits ? Self.pageWidth : 0))
                    .opacity(sidePage.page != nil && !splits ? 0 : 1)
                    .allowsHitTesting(sidePage.page == nil || splits)
                    .clipped()
                if let opened = sidePage.page {
                    if splits { Divider().ignoresSafeArea() }
                    NavigationStack {
                        opened
                            .overlay(alignment: .topTrailing) { closeButton }
                    }
                    .id(sidePage.openID)
                    .frame(maxWidth: .infinity)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
    }

    private var closeButton: some View {
        Button("Close", systemImage: "xmark") {
            withAnimation(.smooth(duration: 0.25)) { sidePage.close() }
        }
        .labelStyle(.iconOnly)
        .fontWeight(.semibold)
        .buttonStyle(FixedGlassButtonStyle(size: MacPageNavigation.controlHeight))
        .padding(MacPageNavigation.inset)
        .keyboardShortcut(.cancelAction)
        .help("Close")
        .accessibilityIdentifier("settings.sidePage.close")
    }
}
#endif
#endif
