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
            Button("Search") {
                router?.open(.search)
                #if targetEnvironment(macCatalyst)
                router?.searchFocusRevision += 1
                #endif
            }.keyboardShortcut("f")
            #if targetEnvironment(macCatalyst)
            Divider()
            Button("Back") { router?.goBackOnTab() }.keyboardShortcut("[")
            Button("Refresh Home") { router?.refreshHome() }.keyboardShortcut("r")
            #endif
        }
    }
}
#endif
