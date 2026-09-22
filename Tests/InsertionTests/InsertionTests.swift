import Flavors
import Foundation
@testable import Insertion
import Testing

/// What goes onto the wire comes back off it.
///
/// [LAW:behavior-not-structure] Held against the values and never against the bytes: the
/// contract is that an answer survives the crossing, not that it is spelled any particular
/// way, and a test that pinned the JSON would fail on a change that broke nothing.
@Suite struct WireTests {
    @Test(arguments: [
        InsertionAnswer.inserted(characters: 0),
        .inserted(characters: 12),
        .refused(.noClientHasFocus),
        .refused(.requestWasNotText),
    ])
    func everyAnswerSurvivesTheCrossing(answer: InsertionAnswer) {
        #expect(Wire.answer(of: Wire.answer(answer)) == answer)
    }

    /// Text is what the request carries, and the alphabet is not this program's to choose:
    /// dictation puts out apostrophes and em dashes, and a person may be dictating into any
    /// language the machine can show.
    @Test(arguments: ["", "hello", "it's a test - really", "🫠 emoji", "日本語", String(repeating: "x", count: 10_000)])
    func everyTextSurvivesTheCrossing(text: String) {
        #expect(Wire.text(of: Wire.request(text)) == text)
    }

    @Test func bytesThatAreNotTextAreNotText() {
        #expect(Wire.text(of: Data([0xFF, 0xFE, 0xFD])) == nil)
    }

    @Test func nonsenseIsNotAnAnswer() {
        #expect(Wire.answer(of: Data("nonsense".utf8)) == nil)
    }
}

/// The channel, end to end, against a port standing in for the input method.
@Suite struct InserterTests {
    @Test func theTextArrivesAndTheAnswerComesBack() throws {
        let name = aPortNobodyElseUses()
        let seen = Seen()
        let port = try PortOnItsOwnThread.insertion(name: name) { text in
            seen.record(text)
            return .inserted(characters: text.count)
        }
        defer { port.stop() }

        let answer = try InputMethodInserter(portName: name, timeout: .seconds(5)).insert("hello there")
        #expect(answer == .inserted(characters: 11))
        #expect(seen.text == "hello there")
    }

    /// A refusal is an answer: it comes back, it does not throw, and it says which refusal
    /// it is - which is what low-input-method-s71.b26 switches on to reach the clipboard.
    @Test func aRefusalComesBackAsAnAnswer() throws {
        let name = aPortNobodyElseUses()
        let port = try PortOnItsOwnThread.insertion(name: name) { _ in .refused(.noClientHasFocus) }
        defer { port.stop() }

        #expect(try InputMethodInserter(portName: name, timeout: .seconds(5)).insert("hello")
            == .refused(.noClientHasFocus))
    }

    /// Bytes that are not text are answered rather than dropped, so a sender learns why
    /// instead of waiting out its timeout. [LAW:no-silent-failure]
    @Test func bytesThatAreNotTextAreRefusedByName() throws {
        let name = aPortNobodyElseUses()
        let port = try PortOnItsOwnThread.insertion(name: name) { .inserted(characters: $0.count) }
        defer { port.stop() }

        let remote = try #require(CFMessagePortCreateRemote(nil, name as CFString))
        var reply: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(
            remote, 0, Data([0xFF, 0xFE]) as CFData, 5, 5, CFRunLoopMode.defaultMode.rawValue, &reply
        )
        #expect(status == kCFMessagePortSuccess)
        let data = try #require(reply?.takeRetainedValue() as Data?)
        #expect(Wire.answer(of: data) == .refused(.requestWasNotText))
    }

    /// One name is one port, so a second `InsertionPort` here is not a second listener.
    ///
    /// Measured 2026-09-22, because the documented "returns NULL if the name is taken" is
    /// only half the story: within ONE process `CFMessagePortCreateLocal` is get-or-create
    /// and hands back the identical object. It refuses across processes, which is the case
    /// `NameIsTaken` exists for and the one no in-process test can stage.
    ///
    /// Held here because the design rests on it: the input method makes exactly one port,
    /// and if a second ever appeared it would share this one's lifetime, not compete with
    /// it - invalidating either would close the door for both. [LAW:one-source-of-truth]
    @Test func oneNameIsOnePort() throws {
        let name = aPortNobodyElseUses()
        let first = try InsertionPort(portName: name) { .inserted(characters: $0.count) }
        let second = try InsertionPort(portName: name) { _ in .refused(.noClientHasFocus) }
        #expect(first.hosts(second))
    }
}

/// Every way the transport can fail to carry the question, each seen as its own named
/// error. Named, because each one means something different to do.
@Suite struct UnreachableTests {
    @Test func nothingListeningIsSaidByName() {
        let name = aPortNobodyElseUses()
        #expect(throws: Unreachable.nothingIsListening(port: name)) {
            try InputMethodInserter(portName: name, timeout: .seconds(1)).insert("hello")
        }
    }

    /// A live input method that does not finish in time is not a missing one, and the two
    /// are not answered the same way: this one may have inserted the words.
    @Test func anAnswerThatDoesNotArriveIsSaidByName() throws {
        let name = aPortNobodyElseUses()
        let port = try PortOnItsOwnThread.insertion(name: name) { text in
            Thread.sleep(forTimeInterval: 2)
            return .inserted(characters: text.count)
        }
        defer { port.stop() }

        let timeout = Duration.milliseconds(200)
        #expect(throws: Unreachable.answerDidNotArrive(port: name, after: timeout)) {
            try InputMethodInserter(portName: name, timeout: timeout).insert("hello")
        }
    }

    /// An answer nobody can read is a skew between the two halves, and saying so names the
    /// only thing that fixes it. Never mistaken for a refusal: a refusal is a fact about
    /// the cursor, and this is a fact about the build.
    @Test func anAnswerNobodyCanReadIsSaidByName() throws {
        let name = aPortNobodyElseUses()
        let port = try PortOnItsOwnThread.raw(name: name) { _ in Data("nonsense".utf8) }
        defer { port.stop() }

        #expect(throws: Unreachable.answerWasNotReadable(port: name, bytes: 8)) {
            try InputMethodInserter(portName: name, timeout: .seconds(5)).insert("hello")
        }
    }
}

/// Each flavor reaches its own input method and never the other's.
@Suite struct FlavorPortTests {
    @Test func theTwoInstallationsDoNotShareAPort() {
        #expect(Set(Flavor.allCases.map(\.inputMethodPortName)).count == Flavor.allCases.count)
    }

    /// Beside the text input system's connection, never equal to it: that one is opened by
    /// macOS and speaks its protocol, not ours.
    @Test(arguments: Flavor.allCases)
    func theInsertPortIsNotTheConnection(flavor: Flavor) {
        #expect(flavor.inputMethodPortName != flavor.inputMethodConnectionName)
        #expect(flavor.inputMethodPortName.hasPrefix(flavor.inputMethodBundleIdentifier))
    }
}

/// What the hosted port saw, across the thread it saw it on.
private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: String?

    func record(_ text: String) {
        lock.lock()
        seen = text
        lock.unlock()
    }

    var text: String? {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }
}
