import AppKit
import Dictation
import LowTalkerCore

/// The small panel near the bottom of the screen while a press is on its way, or while words
/// no cursor took are held: listening, with what the engine has read of the press so far, then
/// transcribing, then gone once the press's outcome is reported - unless an insert failed, and
/// then it says why and holds the words until a cursor takes them or the person dismisses them
/// with the circle on its corner.
///
/// It never takes focus from the app the words are going to. A borderless panel cannot become
/// key, and a non-activating one is ordered in without activating this app, so a click on the
/// circle leaves the person where they were. Every click goes through it to whatever is under
/// it, except while it holds words and has the circle to click.
///
/// [LAW:one-source-of-truth] It draws `Dictation.Activity` and `Held` and keeps nothing of its own.
@MainActor
final class HUD {
    private static let width: CGFloat = 440
    private static let cornerRadius: CGFloat = 12
    /// How far the dismiss circle reaches past the face's top-left corner. The panel is that
    /// much larger than the face on those two sides, always, so the face stays put whether the
    /// circle shows or not. [LAW:dataflow-not-control-flow]
    private static let overhang: CGFloat = 8

    private let dismiss: @MainActor () -> Void

    init(dismiss: @escaping @MainActor () -> Void) {
        self.dismiss = dismiss
    }

    private lazy var panel: NSPanel = {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width + Self.overhang, height: 60),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // An agent app is never active, and a panel that hid on deactivation would never show.
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.contentView = area
        return panel
    }()

    /// The panel's whole area: the face, and the circle hanging off its corner, which the
    /// face's rounded clip would cut away if it were inside it.
    private lazy var area: NSView = {
        let area = NSView()
        face.translatesAutoresizingMaskIntoConstraints = false
        close.translatesAutoresizingMaskIntoConstraints = false
        area.addSubview(face)
        area.addSubview(close)
        // The circle's centre sits on the corner's arc, as a Notification Center banner's does.
        let onTheArc = Self.cornerRadius * (1 - 1 / 2.squareRoot())
        NSLayoutConstraint.activate([
            face.leadingAnchor.constraint(equalTo: area.leadingAnchor, constant: Self.overhang),
            face.trailingAnchor.constraint(equalTo: area.trailingAnchor),
            face.topAnchor.constraint(equalTo: area.topAnchor, constant: Self.overhang),
            face.bottomAnchor.constraint(equalTo: area.bottomAnchor),
            close.centerXAnchor.constraint(equalTo: face.leadingAnchor, constant: onTheArc),
            close.centerYAnchor.constraint(equalTo: face.topAnchor, constant: onTheArc),
        ])
        return area
    }()

    /// The panel's face, laid out at the panel's one width.
    private lazy var face: NSVisualEffectView = {
        let face = NSVisualEffectView()
        face.material = .hudWindow
        face.blendingMode = .behindWindow
        face.state = .active
        face.wantsLayer = true
        face.layer?.cornerRadius = Self.cornerRadius
        face.layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        face.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: face.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: face.trailingAnchor),
            content.topAnchor.constraint(equalTo: face.topAnchor),
            content.bottomAnchor.constraint(equalTo: face.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: Self.width),
        ])
        return face
    }()

    private lazy var content: NSStackView = {
        let content = NSStackView(views: [state, warning, heard])
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

    /// Why the words are held, beside the system's warning symbol, wrapped to the panel's width.
    private let warning: NSTextField = {
        let warning = NSTextField(wrappingLabelWithString: "")
        warning.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        warning.textColor = .systemOrange
        warning.preferredMaxLayoutWidth = HUD.width - 32
        return warning
    }()

    /// One line, cut at its head: the newest words are the ones the person is watching.
    private let heard: NSTextField = {
        let heard = NSTextField(labelWithString: "")
        heard.font = .systemFont(ofSize: NSFont.systemFontSize + 2)
        heard.lineBreakMode = .byTruncatingHead
        heard.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return heard
    }()

    private lazy var close: Dismiss = {
        let close = Dismiss { [unowned self] in dismiss() }
        return close
    }()

    func show(_ activity: Dictation.Activity, held: Held?) {
        // A press on its way carries what is held in its own insert, so only a panel with no
        // press asks for a click.
        let shown: (state: String?, words: Transcript, offer: String) = switch activity {
        case .idle: (nil, held?.words ?? Transcript(words: []), " Click into a text field to insert these words.")
        case .listening(let heard): ("Listening", heard, "")
        case .transcribing: ("Transcribing", held?.words ?? Transcript(words: []), "")
        }
        guard shown.state != nil || held != nil else { return panel.orderOut(nil) }
        draw(state: shown.state, held: held, words: shown.words, offer: shown.words.isBlank ? "" : shown.offer)
    }

    /// The panel with these lines, centred low on the screen the person is working on.
    private func draw(state: String?, held: Held?, words: Transcript, offer: String) {
        self.state.stringValue = state ?? ""
        self.state.isHidden = state == nil
        // One line per warning, each after the symbol, which says it is a warning, so the text
        // drops the word. The offer ends the last.
        let reasons = (held?.warnings ?? []).map { String($0.trimmingPrefix("WARNING: ")) }
        let warned = NSMutableAttributedString()
        for (index, reason) in reasons.enumerated() {
            let symbol = NSTextAttachment()
            symbol.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")
            warned.append(NSAttributedString(string: index == 0 ? "" : "\n"))
            warned.append(NSAttributedString(attachment: symbol))
            warned.append(NSAttributedString(string: " \(reason)\(index == reasons.count - 1 ? offer : "")"))
        }
        warning.attributedStringValue = warned
        warning.isHidden = held == nil
        // The first word carries the space the engine put before it, which a line has no use for.
        heard.stringValue = String(words.text.drop(while: \.isWhitespace))
        // A press with nothing read yet shows only its state, rather than an empty line.
        heard.isHidden = words.isBlank
        // The circle is there, and the panel takes clicks, only while there is something to dismiss.
        close.isHidden = held == nil
        panel.ignoresMouseEvents = held == nil
        // With no display attached there is nowhere for the panel to be.
        guard let screen = NSScreen.main?.visibleFrame else { return panel.orderOut(nil) }
        // Measured through the panel's area, whose constraints hold the content to its width.
        let size = area.fittingSize
        panel.setFrame(NSRect(x: screen.midX - Self.width / 2 - Self.overhang, y: screen.minY + screen.height * 0.12, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }
}

/// The circle on the panel's corner that lets held words go.
///
/// Answers the first click, though the panel is never key: the panel cannot become key, so
/// every click on it is a first one, and a button that waited for a second would never fire.
private final class Dismiss: NSButton {
    private let dismissed: @MainActor () -> Void

    init(_ dismissed: @escaping @MainActor () -> Void) {
        self.dismissed = dismissed
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Dismiss")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
                .applying(.init(paletteColors: [.white, .darkGray])))
        isBordered = false
        imagePosition = .imageOnly
        setAccessibilityLabel("Dismiss the held words")
        target = self
        action = #selector(clicked)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func clicked() { dismissed() }
}
