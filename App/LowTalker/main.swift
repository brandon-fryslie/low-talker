import AppKit

// `LowTalker --bench …` is the bench from a terminal, and branches off before anything the
// menu-bar app sets up. [LAW:one-type-per-behavior] One binary, so the bench reads the
// bookmarks and the carried store the app does, under the app's own sandbox and signature.
if CommandLine.arguments.dropFirst().first == "--bench" {
    BenchTerminal.run(Array(CommandLine.arguments.dropFirst(2)))
}

// AppKit's `@main` entry only calls NSApplicationMain, which creates the delegate
// from a nib named in Info.plist. This app has no nib, so the delegate is wired here.
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
