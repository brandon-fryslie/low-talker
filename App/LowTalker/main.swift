import AppKit

// AppKit's `@main` entry only calls NSApplicationMain, which creates the delegate
// from a nib named in Info.plist. This app has no nib, so the delegate is wired here.
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
