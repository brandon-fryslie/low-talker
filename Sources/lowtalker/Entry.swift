import LowTalkerCommands

/// The CLI's process, and nothing else: every command lives in `LowTalkerCommands`, where the
/// tests reach it. An async `@main` rather than top-level code, so the process
/// starts exactly as it did when the command itself was `@main`.
@main
enum Entry {
    static func main() async { await LowTalker.main() }
}
