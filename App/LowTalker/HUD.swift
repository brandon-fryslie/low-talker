import AppKit
import Dictation

/// The small panel near the bottom of the screen while a press is on its way: listening,
/// with what the engine has read of the press so far, then transcribing, then gone once the
/// press's outcome is reported.
///
/// It never takes focus from the app the words are going to. A borderless panel cannot become
/// key, a non-activating one is ordered in without activating this app, and it lets every
/// click through to whatever is under it.
///
/// [LAW:one-source-of-truth] It draws `Dictation.Activity` and keeps nothing of its own.
@MainActor
final class HUD {
    private static let width: CGFloat = 440

    private lazy var panel: NSPanel = {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 60),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // An agent app is never active, and a panel that hid on deactivation would never show.
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            content.topAnchor.constraint(equalTo: background.topAnchor),
            content.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: Self.width),
        ])
        panel.contentView = background
        return panel
    }()

    private lazy var content: NSStackView = {
        let content = NSStackView(views: [state, heard])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 4
        content.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        return content
    }()

    private let state: NSTextField = {
        let state = NSTextField(labelWithString: "")
        state.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        state.textColor = .secondaryLabelColor
        return state
    }()

    /// One line, cut at its head: the newest words are the ones the person is watching.
    private let heard: NSTextField = {
        let heard = NSTextField(labelWithString: "")
        heard.font = .systemFont(ofSize: NSFont.systemFontSize + 2)
        heard.lineBreakMode = .byTruncatingHead
        heard.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return heard
    }()

    func show(_ activity: Dictation.Activity) {
        switch activity {
        case .idle:
            panel.orderOut(nil)
        case .listening(let words):
            draw(state: "Listening", heard: words)
        case .transcribing:
            draw(state: "Transcribing", heard: "")
        }
    }

    /// The panel with these lines, centred low on the screen the person is working on.
    private func draw(state: String, heard: String) {
        self.state.stringValue = state
        self.heard.stringValue = heard
        // A press with nothing read yet shows only its state, rather than an empty line.
        self.heard.isHidden = heard.isEmpty
        let size = content.fittingSize
        let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        panel.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.minY + screen.height * 0.12, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }
}
