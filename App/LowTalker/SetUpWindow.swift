import AppKit
import Flavors
import Onboarding

/// The guided setup's window: one requirement at a time, explained in plain words before
/// the person presses the button that makes macOS ask.
///
/// [LAW:one-source-of-truth] It draws `Readiness` and keeps nothing of its own but the walk's
/// skipped steps. Every page is drawn from a reading taken as it is drawn: when the window
/// opens, when it comes back to the front - which is when a person returns from System
/// Settings - and after every request. A grant made anywhere clears its step at the next of
/// those, with no relaunch.
///
/// [LAW:effects-at-boundaries] It asks macOS for nothing itself. `ask` is the app's, and the
/// window calls it only from the button a person pressed.
@MainActor
final class SetUpWindow: NSObject, NSWindowDelegate {
    private let flavor: Flavor
    /// The list as it stands now.
    private let read: () -> Readiness
    /// Asks macOS for one row's grant, and answers with what went wrong when something did.
    private let ask: (Requirement.Row) async -> String?

    private var walk = GuidedSetup()
    /// What the last request said went wrong, shown on the step it was made from.
    private var failure: (row: Requirement.Row, reason: String)?
    private var asking = false

    private lazy var window: NSWindow = {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 420),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = GuidedSetup.title(for: flavor).replacingOccurrences(of: "…", with: "")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = page
        return window
    }()

    private let page: NSStackView = {
        let page = NSStackView()
        page.orientation = .vertical
        page.alignment = .leading
        page.spacing = 10
        page.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        return page
    }()

    private static let width: CGFloat = 520

    init(flavor: Flavor, read: @escaping () -> Readiness, ask: @escaping (Requirement.Row) async -> String?) {
        self.flavor = flavor
        self.read = read
        self.ask = ask
    }

    /// Opens the walk at its first step, with nothing set aside.
    func show() {
        walk = GuidedSetup()
        failure = nil
        draw()
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) { draw() }

    // MARK: - drawing

    private func draw() {
        let readiness = read()
        page.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // [LAW:dataflow-not-control-flow] One page or the other, chosen by what the walk
        // reads off the list, never by a mode the window keeps.
        switch walk.current(in: readiness) {
        case .some(let requirement): drawStep(requirement, left: readiness.unmet.count)
        case .none: drawSummary(readiness)
        }
        window.setContentSize(page.fittingSize)
    }

    private func drawStep(_ requirement: Requirement, left: Int) {
        let explanation = requirement.row.explanation(for: flavor)
        add(label(left == 1 ? "1 step left" : "\(left) steps left", size: 11, color: .secondaryLabelColor))
        add(label(requirement.name, size: 20, weight: .semibold))
        add(label("Right now: \(requirement.reads)", size: 12, color: .secondaryLabelColor))
        section("Why \(flavor.displayName) asks", explanation.why)
        section("What it lets you do", explanation.enables)
        section("If you skip it", explanation.ifSkipped)
        // The step's own words, for the states the explanation cannot know about: a grant
        // switched off after it was given, a driver waiting for a restart.
        if !requirement.stepLines.isEmpty {
            add(label(requirement.stepLines.joined(separator: " "), size: 12, color: .secondaryLabelColor))
        }
        if let failure, failure.row == requirement.row {
            add(label(failure.reason, size: 12, color: .systemRed))
        }
        let row = requirement.row
        var buttons = [button("Skip for Now") { [unowned self] in walk.skip(row); failure = nil; draw() }]
        if let pane = row.settingsPane {
            buttons.append(button("Open System Settings") { NSWorkspace.shared.open(pane) })
        }
        // The one button that makes macOS ask, and the default, so Return is the person
        // choosing to be asked. A row the app cannot ask for offers a fresh reading instead.
        let primary = row.askTitle.map { title in button(title) { [unowned self] in request(row) } }
            ?? button("Check Again") { [unowned self] in draw() }
        primary.keyEquivalent = "\r"
        primary.isEnabled = !asking
        buttons.append(primary)
        add(buttonRow(buttons))
    }

    private func drawSummary(_ readiness: Readiness) {
        let skipped = readiness.unmet
        add(label(skipped.isEmpty ? "\(flavor.displayName) is set up" : "Set aside for now", size: 20, weight: .semibold))
        for requirement in readiness.requirements where requirement.met {
            add(label("✓ \(requirement.name): \(requirement.reads)", size: 13))
        }
        // Each step set aside says what not having it costs, and offers the way back in:
        // declining leaves the walk resumable, never finished for good.
        for requirement in skipped {
            let row = requirement.row
            add(label("\(requirement.name): \(requirement.reads)", size: 13, weight: .semibold))
            add(label(row.explanation(for: flavor).ifSkipped, size: 12, color: .secondaryLabelColor))
            add(buttonRow([button("Set Up \(requirement.name)…") { [unowned self] in walk.revisit(row); draw() }]))
        }
        let done = button("Done") { [unowned self] in window.close() }
        done.keyEquivalent = "\r"
        add(buttonRow([done]))
    }

    private func request(_ row: Requirement.Row) {
        asking = true
        failure = nil
        draw()
        Task {
            let reason = await ask(row)
            asking = false
            failure = reason.map { (row, $0) }
            draw()
        }
    }

    // MARK: - pieces

    private func add(_ view: NSView) { page.addArrangedSubview(view) }

    private func section(_ heading: String, _ body: String) {
        add(label(heading, size: 13, weight: .semibold))
        add(label(body, size: 13))
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.preferredMaxLayoutWidth = Self.width - 48
        return label
    }

    private func button(_ title: String, _ action: @escaping @MainActor () -> Void) -> NSButton {
        ActionButton(title: title, action: action)
    }

    private func buttonRow(_ buttons: [NSButton]) -> NSStackView {
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }
}

/// A button that runs a closure, so each page can say what its buttons do where it draws
/// them rather than through a selector per button.
@MainActor
private final class ActionButton: NSButton {
    private let run: @MainActor () -> Void

    init(title: String, action: @escaping @MainActor () -> Void) {
        run = action
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .push
        target = self
        self.action = #selector(pressed)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    @objc private func pressed() { run() }
}
