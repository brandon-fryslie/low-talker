import ArgumentParser
import Flavors
import Foundation
import KeyboardLayout
import LowTalkerCore
import Typing

/// The spike behind low-keyboard-3ti.2: keystrokes sent to the
/// Karabiner-DriverKit-VirtualHIDDevice driver extension from this process, with as
/// little between as macOS allows, to measure the premise before a module or a helper
/// exists.
///
/// What macOS allows is less than the ticket assumed. The extension's user client
/// opens only for a process holding `com.apple.developer.driverkit.userclient-access`
/// for its bundle id, an entitlement Apple grants per app id; root without it gets
/// kIOReturnNotPermitted, measured here. The package ships the one process that holds
/// it, Karabiner-VirtualHIDDevice-Daemon, which runs as root and takes reports over a
/// Unix domain socket in a root-only directory. That socket is the way in, and root is
/// what it takes to reach it: `type` needs sudo. `watch` runs as the user and needs
/// the terminal's Input Monitoring and Accessibility, like `hotkey`.
struct DextCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dext",
        abstract: "Type through the virtual keyboard driver extension, and watch what arrives.",
        subcommands: [DextTypeCommand.self, DextWatchCommand.self]
    )
}

/// Types text into a named app as the virtual keyboard and reads it back off that app's
/// focused element through Accessibility, so what it prints is measured, not assumed.
/// Naming the app is what keeps a window that steals focus from swallowing the text.
struct DextTypeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "type",
        abstract: "Type text through the virtual keyboard into a named app (sudo for --through device)."
    )

    @Argument(help: "The bundle id of the app to type into, e.g. com.apple.TextEdit.")
    var into: BundleID

    @Argument(help: "The text to type. Anything the current keyboard layout has keys for, dead-key sequences included.")
    var text: String

    /// [LAW:no-mode-explosion] Which keyboard, as a value on the one typing command,
    /// rather than a second command that would be this one with four lines changed and
    /// every later fix owed to both.
    @Option(name: .customLong("through"), help: "Where the keystrokes go: the driver in this process, which needs root, or the installed helper, which does not.")
    var through: Through = .device

    @Option(name: .customLong("layout"), help: "The keyboard layout to type through, by input source id (com.apple.keylayout.Dvorak). Defaults to this process's own, which under sudo is root's US and not the console user's - so a machine on any other layout needs this said.")
    var layoutID: String?

    @OptionGroup var installation: FlavorOption

    @MainActor
    func run() async throws {
        // Named rather than discovered when it has to be. This command runs as root, and
        // root is answered with root's own layout: on a machine switched to Dvorak, the
        // console user is told Dvorak and this process is told US. Typing US keys under
        // Dvorak types something else entirely and every check here would still pass, so
        // the layout is printed whether it was named or found. [LAW:no-silent-failure]
        let layout = try layoutID.map { try KeyboardLayout.named($0) } ?? KeyboardLayout.current()
        // Printed here, where the fact becomes known, and not alongside the focus report
        // below: a run that never raises the app throws before that line, and the layout is
        // exactly what an operator needs told when the machine is not on root's US.
        print("typing through \(layout.name)")
        // After the print and not before it, so that "the layout it used" holds for a run
        // that types nothing too. Resolving a layout cannot fail differently for an empty
        // string, so the cheap check has no claim on going first.
        // [LAW:parse-dont-validate] The text is proven typeable before the daemon is
        // touched, so a refusal leaves no half-typed line behind.
        guard !text.isEmpty else { throw ValidationError("there is nothing to type") }
        let typing = try layout.typing(text)
        // What the keys will put on screen, which is not always what was asked for: a CRLF
        // is one Return, and the app writes one line break for it. Compared against this
        // rather than the argument, so a run that typed correctly is not reported as a
        // mismatch over a character no keyboard can produce. [LAW:one-source-of-truth]
        let expected = String(typing.map(\.character))
        let clock = ContinuousClock()
        // Watched before a single report goes out, so there is no window where an
        // interrupt can end the process with a key already down.
        let interrupt = Interrupt.watched()
        let opened = try through.open(clock, flavor: installation.flavor)
        let keyboard = opened.keyboard
        // The typist releases every key on a run it stops. This release is for the run
        // before it: a device that will not come up is released through the connection
        // that was opened to it, since the last run's keys may still be down there, and
        // that is why it is registered before the keyboard is brought up.
        defer {
            do { try keyboard.releaseAll() }
            // [LAW:no-silent-failure] Nowhere to throw from a defer, so it is said out
            // loud: a key may be left held and the next thing typed will show it.
            catch { print("the keyboard was not released: \(error). A key may be left held.") }
        }
        print(try opened.bringUp())

        // [LAW:no-ambient-temporal-coupling] The target is stated, not discovered, and
        // every read re-checks it, so a window that steals focus mid-run is a named
        // failure rather than text delivered somewhere nobody asked for. The hotkey is
        // refused as it is in the app: this command types into the same session the
        // app's tap may be listening to.
        let screen = TargetApp(bundleID: into, interrupt: interrupt)
        let typist = Typist(keyboard: GuardedKeyboard(keyboard: keyboard, queue: DeviceQueue(), interrupt: interrupt, screen: screen), hotkeys: [Hotkey.defaultChord(for: installation.flavor)])
        // The first character alone, so its latency is the driver's and not the queue's,
        // and the rest as one run. Both are lowered from `expected`, which is already the
        // text as the keys will type it, so splitting it by character changes nothing.
        let first = try typist.lower(String(expected.prefix(1)), on: layout)
        let rest = try typist.lower(String(expected.dropFirst()), on: layout)

        try interrupt.check()
        try await screen.raise(within: .seconds(5))
        let start = try screen.focus()
        let before = start.text
        // Which element, not just which app: a find bar accepts keystrokes as readily as
        // a document, and reads them back just as convincingly.
        print("typing into \(into.rawValue), focus is \(start.role)")

        // From the first report on there is text in the document that cannot be taken
        // back, so every failure from here has to say how much of it landed. The guard is
        // over the region where that is true, not over one kind of error: catching only
        // ScreenUnreadable let a daemon timeout mid-burst walk past it, and leaving the
        // first press outside the block let its own failure past as well. What throws
        // does not change what the operator needs to be told. [LAW:single-enforcer]
        // The typist reports each of its two runs against that run's own count, so its
        // report is re-based on the whole text here, where the whole text is known.
        var typed = 0
        let firstPosted = clock.now
        do {
            typed += try await typist.type(first)
            let firstSeen = try await screen.wait(within: .seconds(3)) { $0.shows(String(expected.prefix(1)), moreThan: before) }
            print("first character on screen in \(into.rawValue) after \((clock.now - firstPosted).milliseconds) ms\(firstSeen ? "" : " (NEVER SEEN)")")

            let restPosted = clock.now
            typed += try await typist.type(rest)
            let acknowledged = clock.now - restPosted
            // Against a baseline, like the first character's check: an app already holding
            // this text would otherwise confirm a run that delivered nothing.
            let allSeen = try await screen.wait(within: .seconds(5)) { $0.shows(expected, moreThan: before) }
            let settled = clock.now - restPosted
            // The count is the one the clock actually covers: the first character was
            // posted and timed above, on its own, and is not in this window.
            // [LAW:one-source-of-truth] With nothing after that character there is no
            // burst, and no window either - "0 more in 0.0 ms, all 1 on screen after
            // 0.1 ms" is measured from after the character had already landed and reads
            // as a claim about it, which the line above has already made properly.
            if rest.count > 0 {
                print("\(rest.count) more characters posted and acknowledged in \(acknowledged.milliseconds) ms, all \(typing.count) on screen after \(settled.milliseconds) ms")
            }
            if allSeen {
                print("the screen holds the text, complete and in order")
            } else {
                // The mismatch report is the entire output of a bad run, so it is not
                // allowed to fail on its own account. A screen that will not be read is
                // part of the report, not a reason to lose it. [LAW:no-silent-failure]
                do { print("MISMATCH: the screen holds \(try screen.read())") }
                catch { print("MISMATCH, and the screen would not be read afterwards: \(error)") }
            }
        } catch let stopped as TypingStopped {
            throw TypingStopped(typed: typed + stopped.typed, of: typing.count, halfTyped: stopped.halfTyped, cause: stopped.cause, unreleased: stopped.unreleased)
        } catch {
            // A wait that failed between the two runs: every key is up, because the
            // typist releases after each keystroke, and the count is what it typed.
            throw TypingStopped(typed: typed, of: typing.count, cause: error)
        }
    }
}

/// Prints every keyboard event the login session carries, through the same tap the
/// app installs, with the time from the driver's stamp to the tap's callback.
struct DextWatchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watch",
        abstract: "Print each keyboard event the session's event tap sees until interrupted."
    )

    @MainActor
    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let (events, continuation) = AsyncStream.makeStream(of: (KeyEvent, HostTime).self)
        _ = try SystemKeyboardTap().install(
            handling: { event in
                continuation.yield((event, .now))
                return .pass
            },
            onLapse: { print("the tap lapsed and was switched back on") }
        )
        print("watching the session's keyboard events")
        for await (event, arrived) in events {
            let key = switch event.key {
            case .key(let key): "key \(key.rawValue)"
            case .modifier(let modifier): "modifier \(modifier.rawValue)"
            }
            print("\(event.direction) \(key) stamp-to-tap \((arrived - event.time).microseconds) us")
        }
    }
}

extension BundleID: ExpressibleByArgument {}

extension Duration {
    /// Milliseconds to a tenth, the resolution a keystroke's latency needs.
    var milliseconds: String {
        fixed(Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15, places: 1)
    }

    var microseconds: Int64 {
        components.seconds * 1_000_000 + components.attoseconds / 1_000_000_000_000
    }
}
