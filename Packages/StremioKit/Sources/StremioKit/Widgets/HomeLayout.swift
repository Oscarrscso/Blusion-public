import Foundation

/// The rules every saved Home layout keeps, whichever screen saved it: the showcase (the spotlight) is first and the only one, and
/// Continue Watching is in the list. Home draws Continue Watching above everything when the list leaves it out, so a layout without it
/// would show it above the showcase.
public enum HomeLayout {
    /// The id Continue Watching takes when it is put back: the automatic layout's own.
    public static let continueWatchingID = "auto.continue"

    /// Whether a widget is Home's showcase: a spotlight.
    public static func isShowcase(_ widget: HomeWidget) -> Bool {
        if case .hero = widget.content { return true }
        return false
    }

    public static func isContinueWatching(_ widget: HomeWidget) -> Bool {
        widget.content == .continueWatching
    }

    /// The layout with the rules kept, and every widget in it kept. The first showcase moves to the top. Any other showcase, from an import
    /// or saved before only one was allowed, stays where it was as a banner, with its source and settings. A layout without Continue Watching
    /// gets it back right after the showcase, or first when there is none. A layout that already keeps the rules comes back unchanged, so
    /// this can run on every load and saves at most once.
    public static func normalised(_ list: [HomeWidget]) -> [HomeWidget] {
        var showcase: HomeWidget?
        var rest: [HomeWidget] = []
        for var widget in list {
            if case .hero(let row) = widget.content {
                if showcase == nil {
                    showcase = widget
                    continue
                }
                widget.content = .banner(row)
            }
            rest.append(widget)
        }
        if !rest.contains(where: isContinueWatching) {
            let id = list.contains { $0.id == continueWatchingID } ? UUID().uuidString : continueWatchingID
            rest.insert(HomeWidget(id: id, title: "Continue", content: .continueWatching), at: 0)
        }
        return (showcase.map { [$0] } ?? []) + rest
    }
}
