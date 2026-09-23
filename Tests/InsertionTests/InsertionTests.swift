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
        InsertionAnswer.inserted(characters: 0, into: "com.example.editor"),
        .inserted(characters: 12, into: "com.example.editor"),
        .refused(.noClientHasFocus),
        .refused(.cursorIsInAnotherApp),
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

    /// An insert that names no app is not an answer either. It reads as well-formed JSON, so
    /// nothing else would stop it, and a caller renders it as a line ending in nothing at
    /// all - worse than a line naming no app, which is the standard `Client.init?` sets at
    /// the far border. Our own input method cannot send one; what can is whatever else holds
    /// a port name anyone can derive. [LAW:parse-dont-validate]
    @Test func anInsertThatNamesNoAppIsNotAnAnswer() {
        let named = InsertionAnswer.inserted(characters: 11, into: "")
        #expect(Wire.answer(of: Wire.answer(named)) == nil)
    }

    /// And the check is on the app rather than on the case: an insert that reports no
    /// characters is a real answer - a zero-length request arrives as an empty request and
    /// is answered honestly - so nothing here may turn it away.
    @Test func anInsertOfNothingIntoARealAppStillCrosses() {
        let nothing = InsertionAnswer.inserted(characters: 0, into: "com.example.editor")
        #expect(Wire.answer(of: Wire.answer(nothing)) == nothing)
    }
}

/// Long enough that the runner's own stall cannot spend it: `DirectoryChangesTests` records
/// a CI machine that freezes this process for seconds at a time, and `InputMethodInserter`
/// hands each phase of the round trip half of what it is given. Said once, because it is one
/// fact about the machine rather than five. [LAW:one-source-of-truth] The cases that ARE
/// timing under test set their own budget and say so.
private let aBudgetTheRunnerCannotSpend = Duration.seconds(20)

/// The app a hosted double says it committed into. Any name at all: what crosses the wire is
/// what the far end said, and no case here is about which app that was.
private let anEditor = "com.example.editor"

/// The channel, end to end, against a port standing in for the input method.
///
/// Every case here awaits rather than calling the blocking `insert` on its own thread, and
/// that is not a style choice: a test body runs on the cooperative pool, and this repo has
/// already measured what blocking there costs - `HelperKeyboardTests` records four blocking
/// calls holding every thread of a three-core runner until no other test ran at all. The
/// awaited overload puts the wait on a thread of its own, which is what it is for.
/// [LAW:no-ambient-temporal-coupling]
@Suite struct InserterTests {
    @Test func theTextArrivesAndTheAnswerComesBack() async throws {
        let name = aPortNobodyElseUses()
        let seen = Seen()
        let port = try PortOnItsOwnThread.insertion(name: name) { text in
            seen.record(text)
            return .inserted(characters: text.count, into: anEditor)
        }
        defer { port.stop() }

        let answer = try await InputMethodInserter(portName: name, timeout: aBudgetTheRunnerCannotSpend)
            .insert("hello there")
        #expect(answer == Inserted(characters: 11, into: anEditor))
        #expect(seen.text == "hello there")
    }

    /// Nothing to say is still something to send. `inserted(characters: 0)` is a modelled
    /// outcome, and whether an empty request survives the transport is a fact about
    /// `CFMessagePort` rather than about `Wire`: the callback is handed an optional, so a
    /// zero-length payload arriving as nothing at all would be answered `requestWasNotText`
    /// and the count would never be reached. Measured here rather than read: it arrives as an
    /// empty `CFData`. [LAW:behavior-not-structure]
    @Test func anEmptyRequestCrossesAsAnEmptyRequest() async throws {
        let name = aPortNobodyElseUses()
        let port = try PortOnItsOwnThread.insertion(name: name) { .inserted(characters: $0.count, into: anEditor) }
        defer { port.stop() }

        #expect(try await InputMethodInserter(portName: name, timeout: aBudgetTheRunnerCannotSpend).insert("")
            == Inserted(characters: 0, into: anEditor))
    }

    /// A refusal crosses the wire as an answer and is thrown past it, by name: to the caller
    /// it is a failure like any other, since the words are not at the cursor.
    @Test func aRefusalIsThrownByName() async throws {
        let name = aPortNobodyElseUses()
        let port = try PortOnItsOwnThread.insertion(name: name) { _ in .refused(.noClientHasFocus) }
        defer { port.stop() }

        await #expect(throws: Refusal.noClientHasFocus) {
            try await InputMethodInserter(portName: name, timeout: aBudgetTheRunnerCannotSpend).insert("hello")
        }
    }

    /// Bytes that are not text are answered rather than dropped, so a sender learns why
    /// instead of waiting out its timeout. [LAW:no-silent-failure]
    @Test func bytesThatAreNotTextAreRefusedByName() async throws {
        let name = aPortNobodyElseUses()
        let port = try PortOnItsOwnThread.insertion(name: name) { .inserted(characters: $0.count, into: anEditor) }
        defer { port.stop() }

        // On a thread of its own for the reason the suite doc gives: this one sends by hand
        // rather than through the awaited overload, because no `Inserter` can put bytes that
        // are not text onto the wire.
        let data = try await onAThreadOfItsOwn {
            let remote = try #require(CFMessagePortCreateRemote(nil, name as CFString))
            var reply: Unmanaged<CFData>?
            let status = CFMessagePortSendRequest(
                remote, 0, Data([0xFF, 0xFE]) as CFData,
                aBudgetTheRunnerCannotSpend.seconds, aBudgetTheRunnerCannotSpend.seconds,
                CFRunLoopMode.defaultMode.rawValue, &reply
            )
            #expect(status == kCFMessagePortSuccess)
            return try #require(reply?.takeRetainedValue() as Data?)
        }
        #expect(Wire.answer(of: data) == .refused(.requestWasNotText))
    }

    /// A second port on one name is refused rather than built onto nothing.
    ///
    /// The documented "returns NULL if the name is taken" is only half the story, measured
    /// 2026-09-22: within ONE process `CFMessagePortCreateLocal` is get-or-create, hands
    /// back the identical object, and that object carries the FIRST creator's callback
    /// context. So the second `InsertionPort` would construct without complaint while its
    /// `answer` could never once be called - a door reporting itself open onto nothing.
    /// [LAW:no-silent-failure]
    @Test func aSecondPortOnOneNameIsRefused() async throws {
        let name = aPortNobodyElseUses()
        // On its own thread, so the first port is answering on a run loop that is actually
        // being run. Hosted on the test's thread it would answer only while a blocking send
        // pumped that thread for it, which is the sender servicing the far end - and a far
        // end that only works while someone is waiting on it proves nothing about either.
        let first = try PortOnItsOwnThread.insertion(name: name) { .inserted(characters: $0.count, into: anEditor) }
        defer { first.stop() }

        // Refused before any source is added, so the attempt leaves nothing behind on
        // whatever thread made it.
        #expect(throws: InsertionPort.NameIsTaken.self) {
            _ = try InsertionPort(portName: name) { _ in .refused(.noClientHasFocus) }
        }
        // The first is still the one answering, and answering with its own closure.
        #expect(try await InputMethodInserter(portName: name, timeout: aBudgetTheRunnerCannotSpend).insert("hello")
            == Inserted(characters: 5, into: anEditor))
    }
}

/// The ways the transport can fail to carry the question, each seen as its own named error.
/// Named, because each one means something different to do.
///
/// Four of the five, and the fifth says why: `sendFailed` is the bucket for a status
/// `CFMessagePort` hands out for reasons of its own - a channel that broke under us - and
/// there is no way to ask it for one. What the cases below do cover is that each way the
/// channel fails is said by its own name.
@Suite struct UnreachableTests {
    @Test func nothingListeningIsSaidByName() async {
        let name = aPortNobodyElseUses()
        await #expect(throws: Unreachable.nothingIsListening(port: name)) {
            try await InputMethodInserter(portName: name, timeout: .seconds(1)).insert("hello")
        }
    }

    /// A request nobody ever takes, which is a different failure from an answer that never
    /// comes back, and is said as one.
    ///
    /// The far end is a port with no run loop behind it - the name resolves, so this is not
    /// "nothing is listening", and nothing ever dequeues, so the queue behind it fills and
    /// the send has nowhere left to go. Filled by sending until a send says so rather than by
    /// counting to the limit, which is the kernel's number and not this suite's. Nothing here
    /// can be hurried by a busy machine either: a queue nobody drains does not drain later.
    /// [LAW:no-ambient-temporal-coupling]
    @Test func aRequestThatIsNeverTakenIsSaidByName() async throws {
        let name = aPortNobodyElseUses()
        let answeringNobody: CFMessagePortCallBack = { _, _, _, _ in nil }
        var context = CFMessagePortContext()
        let port = try #require(CFMessagePortCreateLocal(nil, name as CFString, answeringNobody, &context, nil))
        defer { CFMessagePortInvalidate(port) }

        let budget = Duration.milliseconds(200)
        let filled = try await onAThreadOfItsOwn {
            let remote = try #require(CFMessagePortCreateRemote(nil, name as CFString))
            for _ in 0 ..< 64 {
                let status = CFMessagePortSendRequest(
                    remote, 0, Data("x".utf8) as CFData, budget.seconds, 0, nil, nil
                )
                if status == kCFMessagePortSendTimeout { return true }
            }
            return false
        }
        #expect(filled, "the queue behind the port never filled, so no send timeout can be asked for")

        await #expect(throws: Unreachable.requestWasNotTaken(port: name, after: budget / 2)) {
            try await InputMethodInserter(portName: name, timeout: budget).insert("hello")
        }
    }

    /// A live input method that does not finish in time is not a missing one, and the two
    /// are not said the same way.
    @Test func anAnswerThatDoesNotArriveIsSaidByName() async throws {
        let name = aPortNobodyElseUses()
        let port = try PortOnItsOwnThread.insertion(name: name) { text in
            Thread.sleep(forTimeInterval: 30)
            return .inserted(characters: text.count, into: anEditor)
        }
        defer { port.stop() }

        // Halved, because the two phases of the round trip share the caller's budget and the
        // error names the phase's own bound rather than a number nobody waited. Five seconds
        // for the send half rather than the least that works: which phase ran out is the
        // whole of what this case asks, and the runner freeze the budget above is sized
        // against would otherwise fail it as a send that never landed. The five seconds this
        // case does spend are the receive half, which is the wait under test.
        let timeout = Duration.seconds(10)
        await #expect(throws: Unreachable.answerDidNotArrive(port: name, after: timeout / 2)) {
            try await InputMethodInserter(portName: name, timeout: timeout).insert("hello")
        }
    }

    /// An answer nobody can read is a skew between the two halves, and saying so names the
    /// only thing that fixes it. Never mistaken for a refusal: a refusal is a fact about
    /// the cursor, and this is a fact about the build.
    @Test func anAnswerNobodyCanReadIsSaidByName() async throws {
        let name = aPortNobodyElseUses()
        let port = try PortOnItsOwnThread.raw(name: name) { _ in Data("nonsense".utf8) }
        defer { port.stop() }

        await #expect(throws: Unreachable.answerWasNotReadable(port: name, bytes: 8)) {
            try await InputMethodInserter(portName: name, timeout: aBudgetTheRunnerCannotSpend).insert("hello")
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
