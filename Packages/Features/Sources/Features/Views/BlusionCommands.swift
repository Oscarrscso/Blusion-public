#if canImport(UIKit)
import SwiftUI

public struct BlusionCommands: Commands {
    @FocusedValue(AppRouter.self) private var router: AppRouter?

    public init() {}

    public var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { router?.showSettings() }.keyboardShortcut(",")
        }
        CommandMenu("Go") {
            Button("Home") { router?.open(.home) }.keyboardShortcut("1")
            Button("Discover") { router?.open(.discover) }.keyboardShortcut("2")
            Button("Library") { router?.open(.library) }.keyboardShortcut("3")
            #if targetEnvironment(macCatalyst)
            Button("Settings") { router?.showSettings() }.keyboardShortcut("4")
            #endif
            // As a tap on the Search tab: its first page, with the field focused, on every platform.
            Button("Search") { router?.tapTab(.search) }.keyboardShortcut("f")
            #if targetEnvironment(macCatalyst)
            Divider()
            Button("Back") { router?.goBackOnTab() }.keyboardShortcut("[")
            Button("Refresh Home") { router?.refreshHome() }.keyboardShortcut("r")
            #endif
        }
    }
}
#endif
