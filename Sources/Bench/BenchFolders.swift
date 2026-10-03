import Foundation

/// The folders a person picked for the bench, remembered as security-scoped bookmarks.
///
/// The app is sandboxed: it reads a folder outside its container only once a person has
/// picked it in an open panel, and reads it again in a later process only through the
/// bookmark made then. A path alone - `~/Library/Application Support/low-talker/hub`, a
/// checkout's `bench/` - is refused however it is spelled, so the window's open panels are
/// the one way a folder gets here and `LowTalker --bench` reads what they remembered.
/// [LAW:single-enforcer]
public struct BenchFolders: Sendable {
    // UserDefaults is documented safe to use from any thread; Foundation has yet to mark it
    // Sendable.
    nonisolated(unsafe) private let defaults: UserDefaults
    /// Each bookmark under the path of the folder it was made for.
    static let key = "bench.folders"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Remembers `folder`, which a person just picked, for this process and every later one.
    public func remember(_ folder: URL) throws {
        var saved = bookmarks
        saved[Self.name(folder)] = try folder.bookmarkData(options: .withSecurityScope)
        defaults.set(saved, forKey: Self.key)
    }

    /// `folder`, opened through the bookmark a person's pick left, or the refusal that names
    /// it. Read while the returned folder is held.
    public func open(_ folder: URL) throws -> OpenFolder {
        let name = Self.name(folder)
        guard let bookmark = bookmarks[name] else { throw FolderNotPicked(path: name) }
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &stale)
        let opened = OpenFolder(url)
        // A bookmark the system says is stale still resolved; it is made again while the
        // folder is open, so the next process does not find it staler still.
        if stale { try remember(url) }
        return opened
    }

    private var bookmarks: [String: Data] {
        defaults.dictionary(forKey: Self.key) as? [String: Data] ?? [:]
    }

    /// One name per folder however its path was spelled: a trailing slash, which an open
    /// panel's URL has and a path typed after `--bench` may not, a `..`, a link.
    static func name(_ folder: URL) -> String {
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

/// A picked folder opened for reading, closed again when the last reference goes.
public final class OpenFolder: Sendable {
    public let url: URL
    private let scoped: Bool

    init(_ url: URL) {
        self.url = url
        scoped = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if scoped { url.stopAccessingSecurityScopedResource() }
    }

    /// What `read` makes of the folder, read while it is open.
    public func reading<T>(_ read: (URL) throws -> T) rethrows -> T {
        try withExtendedLifetime(self) { try read(url) }
    }
}

/// A folder no open panel has handed the app, so the sandbox will not let it be read.
public struct FolderNotPicked: Error, Equatable, CustomStringConvertible {
    public let path: String

    public var description: String {
        "\(path) has not been picked, so the sandbox will not let LowTalker read it; pick it once in the Benchmark window, which remembers it"
    }
}
