import LowTalkerCommands

/// The CLI's process, and nothing else: every command lives in `LowTalkerCommands`, so this
/// one file is what SwiftPM links into `.build/debug/lowtalker` and what Xcode links into the
/// copy each app bundle carries. An async `@main` rather than top-level code, so the process
/// starts exactly as it did when the command itself was `@main`.
@main
enum Entry {
    static func main() async { await LowTalker.main() }
}
