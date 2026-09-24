import Darwin
import Flavors
import Foundation
@testable import Insertion
import DarwinCalls
import Security
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
        .refused(.secureInputIsOn),
        .refused(.senderIsNotThisInstallationsApp),
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

    /// An insert that reports no characters is a real answer - a zero-length request arrives
    /// as an empty request and is answered honestly - so nothing here may turn it away.
    @Test func anInsertOfNothingIntoARealAppStillCrosses() {
        let nothing = InsertionAnswer.inserted(characters: 0, into: "com.example.editor")
        #expect(Wire.answer(of: Wire.answer(nothing)) == nothing)
    }
}


/// Long enough that the runner's own stall cannot spend it: `DirectoryChangesTests` records
/// a CI machine that freezes this process for seconds at a time, and `InputMethodInserter`
/// hands each of its four phases a quarter of what it is given. Said once, because it is one
/// fact about the machine rather than five. [LAW:one-source-of-truth] The cases that ARE
/// timing under test set their own budget and say so.
let aBudgetTheRunnerCannotSpend = Duration.seconds(20)

/// The app a hosted double says it committed into. Any name at all: what crosses the wire is
/// what the far end said, and no case here is about which app that was.
private let anEditor = "com.example.editor"

/// The channel, end to end, against a port standing in for the input method, with the suite
/// on both ends: this process sends, and this process is the one both requirements name.
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
        let port = try hostInsertion(name: name) { text in
            seen.record(text)
            return .inserted(characters: text.count, into: anEditor)
        }

        let answer = try await inserter(name).insert("hello there")
        #expect(answer == Inserted(characters: 11, into: anEditor))
        #expect(seen.text == "hello there")
        withExtendedLifetime(port) {}
    }

    /// Nothing to say is still something to send. `inserted(characters: 0)` is a modelled
    /// outcome, and a zero-length payload has to arrive as an empty request rather than as
    /// no request, or it would be answered `requestWasNotText` and the count never reached.
    @Test func anEmptyRequestCrossesAsAnEmptyRequest() async throws {
        let name = aPortNobodyElseUses()
        let port = try hostInsertion(name: name) { .inserted(characters: $0.count, into: anEditor) }

        #expect(try await inserter(name).insert("") == Inserted(characters: 0, into: anEditor))
        withExtendedLifetime(port) {}
    }

    /// Larger than the buffer a request is first received into, so the receive has to grow
    /// to it and take the same message again rather than lose it.
    @Test func aLongRequestCrossesWhole() async throws {
        let name = aPortNobodyElseUses()
        let port = try hostInsertion(name: name) { .inserted(characters: $0.count, into: anEditor) }

        let long = String(repeating: "dictated words ", count: 10_000)
        #expect(try await inserter(name).insert(long) == Inserted(characters: long.count, into: anEditor))
        withExtendedLifetime(port) {}
    }

    /// A refusal crosses the wire as an answer and is thrown past it, by name: to the caller
    /// it is a failure like any other, since the words are not at the cursor.
    @Test func aRefusalIsThrownByName() async throws {
        let name = aPortNobodyElseUses()
        let port = try hostInsertion(name: name) { _ in .refused(.noClientHasFocus) }

        await #expect(throws: Refusal.noClientHasFocus) { try await inserter(name).insert("hello") }
        withExtendedLifetime(port) {}
    }

    /// Bytes that are not text are answered rather than dropped, so a sender learns why
    /// instead of waiting out its timeout. [LAW:no-silent-failure]
    @Test func bytesThatAreNotTextAreRefusedByName() async throws {
        let name = aPortNobodyElseUses()
        let port = try hostInsertion(name: name) { .inserted(characters: $0.count, into: anEditor) }

        // Sent by hand, because no `Inserter` can put bytes that are not text onto the wire,
        // and on a thread of its own for the reason the suite doc gives.
        let answer = try await onAThreadOfItsOwn { try roundTrip(Data([0xFF, 0xFE]), to: name) }
        #expect(Wire.answer(of: answer) == .refused(.requestWasNotText))
        withExtendedLifetime(port) {}
    }

    /// A second port on one name is refused rather than built onto nothing, and the first
    /// goes on answering with its own closure.
    @Test func aSecondPortOnOneNameIsRefused() async throws {
        let name = aPortNobodyElseUses()
        let first = try hostInsertion(name: name) { .inserted(characters: $0.count, into: anEditor) }

        #expect {
            _ = try hostInsertion(name: name) { _ in .refused(.noClientHasFocus) }
        } throws: { error in
            guard case InsertionPort.NotHosted.nameIsTaken(name)? = error as? InsertionPort.NotHosted else { return false }
            return true
        }
        #expect(try await inserter(name).insert("hello") == Inserted(characters: 5, into: anEditor))
        withExtendedLifetime(first) {}
    }
}

/// Who gets through, with a real second process on the sending end: the check is only worth
/// what it refuses, and the process it has to refuse is never the one checking.
/// [LAW:verifiable-goals]
@Suite struct SenderTests {
    /// The exposure low-input-method-s71.6tk closes: a process that computed the name and
    /// sent to it. Its words never reach the insert, it is told why, and the log line says
    /// who it was and who was required.
    @Test func aSenderThatIsNotTheOneNamedIsRefused() async throws {
        let name = aPortNobodyElseUses()
        let seen = Seen()
        let told = Told()
        let us = try OwnProcess.identity()
        let port = try InsertionPort(portName: name, senders: us, queue: DispatchQueue(label: name), told: told.record) { text in
            seen.record(text)
            return .inserted(characters: text.count, into: anEditor)
        }

        let printed = try await Probe.send("type this", to: name, answeredBy: us)
        #expect(printed == Refusal.senderIsNotThisInstallationsApp.description)
        #expect(seen.text == nil)
        guard case .turnedAway(_, .someoneElse(.adHoc), us)? = told.events.first, told.events.count == 1 else {
            Issue.record("told \(told.events), not once that the probe was turned away as itself")
            return
        }
        #expect(told.events[0].description.contains(us.description))
        withExtendedLifetime(port) {}
    }

    /// Signed by a real certificate, as the identifier required: answered as the app is.
    @Test func theSenderTheIdentityNamesIsAnswered() async throws {
        let name = aPortNobodyElseUses()
        let seen = Seen()
        let probe = try await Probe.signed(as: "ai.promptctl.low-talker.test.probe")
        defer { try? FileManager.default.removeItem(at: probe.url) }
        let port = try InsertionPort(
            portName: name, senders: probe.identity, queue: DispatchQueue(label: name), told: { Issue.record("told \($0)") }
        ) { text in
            seen.record(text)
            return .inserted(characters: text.count, into: anEditor)
        }

        let printed = try await Probe.send("type this", to: name, answeredBy: try OwnProcess.identity(), from: probe.url)
        #expect(printed == "inserted 9 into \(anEditor)")
        #expect(seen.text == "type this")
        withExtendedLifetime(port) {}
    }

    /// The same certificate is not enough: signed as anything but the app, the sender is
    /// someone else, and the log names who.
    @Test func aSenderSignedAsAnotherIdentifierIsRefused() async throws {
        let name = aPortNobodyElseUses()
        let told = Told()
        let probe = try await Probe.signed(as: "ai.promptctl.low-talker.test.probe")
        defer { try? FileManager.default.removeItem(at: probe.url) }
        let required = PeerIdentity.signed(identifier: "ai.promptctl.low-talker.test.app", certificate: probe.certificate)
        let port = try InsertionPort(portName: name, senders: required, queue: DispatchQueue(label: name), told: told.record) {
            .inserted(characters: $0.count, into: anEditor)
        }

        let printed = try await Probe.send("type this", to: name, answeredBy: try OwnProcess.identity(), from: probe.url)
        #expect(printed == Refusal.senderIsNotThisInstallationsApp.description)
        guard case .turnedAway(_, .someoneElse(probe.identity), required)? = told.events.first else {
            Issue.record("told \(told.events), not that \(probe.identity) was turned away")
            return
        }
        withExtendedLifetime(port) {}
    }

    /// The other direction: a name anyone can compute is a name anyone can hold, so the app
    /// asks who holds it before saying anything, and a stranger never hears the words.
    @Test func aStrangerHoldingTheNameNeverHearsTheWords() async throws {
        let name = aPortNobodyElseUses()
        let seen = Seen()
        let port = try hostInsertion(name: name) { text in
            seen.record(text)
            return .inserted(characters: text.count, into: anEditor)
        }

        let us = try OwnProcess.identity()
        let elsewhere = PeerIdentity.adHoc(cdhash: String(repeating: "0", count: 40))
        let asking = InputMethodInserter(portName: name, timeout: aBudgetTheRunnerCannotSpend, answerer: .success(elsewhere))
        await #expect(throws: Unreachable.answeredByAStranger(port: name, pid: getpid(), because: .someoneElse(us), required: elsewhere)) {
            try await asking.insert("hello")
        }
        #expect(seen.text == nil)
        withExtendedLifetime(port) {}
    }

    /// A build that cannot say who its input method is says so on each insert, rather than
    /// sending to whoever answers.
    @Test func anInserterThatCannotNameItsInputMethodSaysSo() async {
        let asking = InputMethodInserter(portName: aPortNobodyElseUses(), timeout: .seconds(1), answerer: .failure(.noCertificate))
        await #expect(throws: PeerIdentity.Unreadable.noCertificate) { try await asking.insert("hello") }
    }
}

/// Reading a process's identity off the kernel, against processes whose signatures this
/// suite knows.
@Suite struct PeerIdentityTests {
    /// Read off the running process the way `codesign` reads it off the file.
    @Test func aSignedProcessIsReadAsItsIdentifierAndCertificate() async throws {
        let probe = try await Probe.signed(as: "ai.promptctl.low-talker.test.probe")
        defer { try? FileManager.default.removeItem(at: probe.url) }
        let name = aPortNobodyElseUses()
        let read = Read()
        let port = try InsertionPort(portName: name, queue: DispatchQueue(label: name), told: { _ in }) { request in
            read.record(Result { () throws(PeerIdentity.Unreadable) in try PeerIdentity.of(request.sender) })
            return Wire.answer(.refused(.noClientHasFocus))
        }

        _ = try await Probe.send("hello", to: name, answeredBy: try OwnProcess.identity(), from: probe.url)
        #expect(try read.result?.get() == probe.identity)
        withExtendedLifetime(port) {}
    }

    /// A certificate vouches for code only when nothing else can be loaded into it, so a
    /// signed process without the hardened runtime is not read as signed at all.
    @Test func aSignedProcessWithoutTheHardenedRuntimeIsNotReadAsSigned() async throws {
        let probe = try await Probe.signed(as: "ai.promptctl.low-talker.test.probe", hardened: false)
        defer { try? FileManager.default.removeItem(at: probe.url) }
        let name = aPortNobodyElseUses()
        let read = Read()
        let port = try InsertionPort(portName: name, queue: DispatchQueue(label: name), told: { _ in }) { request in
            read.record(Result { () throws(PeerIdentity.Unreadable) in try PeerIdentity.of(request.sender) })
            return Wire.answer(.refused(.noClientHasFocus))
        }

        _ = try await Probe.send("hello", to: name, answeredBy: try OwnProcess.identity(), from: probe.url)
        #expect(read.result.map { if case .failure(.notHardened) = $0 { true } else { false } } == true)
        withExtendedLifetime(port) {}
    }

    @Test func aTokenNamingNoProcessIsUnreadable() throws {
        var token = audit_token_t()
        token.val.5 = UInt32(bitPattern: 99_999_999)
        #expect(throws: PeerIdentity.Unreadable.self) { try PeerIdentity.of(token) }
    }
}

/// The ways the transport can fail to carry the question, each seen as its own named error.
/// Named, because each one means something different to do.
///
/// All but `failed`, which is the bucket for a Mach status nothing here asks for - a channel
/// that broke under us - and there is no way to ask the kernel for one.
@Suite struct UnreachableTests {
    @Test func nothingListeningIsSaidByName() async {
        let name = aPortNobodyElseUses()
        await #expect(throws: Unreachable.nothingIsListening(port: name)) {
            try await inserter(name, timeout: .seconds(1)).insert("hello")
        }
    }

    /// A request nobody ever takes, which is a different failure from an answer that never
    /// comes back, and is said as one.
    ///
    /// The far end is a port whose queue is suspended - the name resolves, so this is not
    /// "nothing is listening", and nothing ever dequeues, so the queue behind it fills and
    /// the send has nowhere left to go. Filled by sending until a send says so rather than by
    /// counting to the limit, which is the kernel's number and not this suite's. Nothing here
    /// can be hurried by a busy machine either: a queue nobody drains does not drain later.
    /// [LAW:no-ambient-temporal-coupling]
    @Test func aRequestThatIsNeverTakenIsSaidByName() async throws {
        let name = aPortNobodyElseUses()
        let held = DispatchQueue(label: name)
        held.suspend()
        // Resumed before the port goes, because a suspended queue released is a crash; the
        // port then drains and answers what was queued, to nobody.
        defer { held.resume() }
        let port = try InsertionPort(portName: name, senders: try OwnProcess.identity(), queue: held, told: { _ in }) {
            .inserted(characters: $0.count, into: anEditor)
        }

        let budget = Duration.milliseconds(200)
        let filled = try await onAThreadOfItsOwn {
            var remote = mach_port_t()
            try #require(lt_bootstrap_look_up(name, &remote) == KERN_SUCCESS)
            defer { mach_port_deallocate(mach_task_self_, remote) }
            for _ in 0 ..< 64 {
                let sent = Mach.send(
                    Data("x".utf8), id: 0, to: remote, disposition: mach_msg_type_name_t(MACH_MSG_TYPE_COPY_SEND),
                    replyTo: Mach.noPort, timeout: budget)
                if sent == MACH_SEND_TIMED_OUT { return true }
            }
            return false
        }
        #expect(filled, "the queue behind the port never filled, so no send timeout can be asked for")

        await #expect(throws: Unreachable.requestWasNotTaken(port: name, after: budget / 4)) {
            try await inserter(name, timeout: budget).insert("hello")
        }
        withExtendedLifetime(port) {}
    }

    /// A live input method that does not finish in time is not a missing one, and the two
    /// are not said the same way.
    @Test func anAnswerThatDoesNotArriveIsSaidByName() async throws {
        let name = aPortNobodyElseUses()
        let port = try hostInsertion(name: name) { text in
            Thread.sleep(forTimeInterval: 30)
            return .inserted(characters: text.count, into: anEditor)
        }

        // Quartered, because the four phases of an insert share the caller's budget and the
        // error names the phase's own bound rather than a number nobody waited. Five seconds
        // a phase rather than the least that works: which phase ran out is the whole of what
        // this case asks, and the runner freeze the budget above is sized against would
        // otherwise fail it in the greeting. The five seconds this case does spend are the
        // last receive, which is the wait under test.
        let timeout = Duration.seconds(20)
        await #expect(throws: Unreachable.answerDidNotArrive(port: name, after: timeout / 4)) {
            try await inserter(name, timeout: timeout).insert("hello")
        }
        withExtendedLifetime(port) {}
    }

    /// A far end that never says who it is is not sent the words, and says so rather than
    /// that they may have landed.
    @Test func aGreetingThatIsNotAnsweredIsSaidByName() async throws {
        let name = aPortNobodyElseUses()
        let port = try InsertionPort(portName: name, queue: DispatchQueue(label: name), told: { _ in }) { _ in
            Thread.sleep(forTimeInterval: 30)
            return Data()
        }

        let timeout = Duration.seconds(4)
        await #expect(throws: Unreachable.didNotSayWhoItIs(port: name, after: timeout / 4)) {
            try await inserter(name, timeout: timeout).insert("hello")
        }
        withExtendedLifetime(port) {}
    }

    /// A far end that takes the words and lets go of the way back is said at once, rather
    /// than waited out as an answer that is merely late.
    @Test func anAnswerAbandonedIsSaidByName() async throws {
        let name = aPortNobodyElseUses()
        let right = try ReceiveRight(sendable: true)
        try #require(lt_bootstrap_register(name, right.port) == KERN_SUCCESS)
        Thread {
            guard case .received(let greeting) = Mach.receive(on: right.port, timeout: aBudgetTheRunnerCannotSpend) else { return }
            _ = greeting.answer(Data())
            guard case .received(let words) = Mach.receive(on: right.port, timeout: aBudgetTheRunnerCannotSpend) else { return }
            words.discardReply()
        }.start()

        await #expect(throws: Unreachable.answerWasAbandoned(port: name)) {
            try await inserter(name).insert("hello")
        }
        withExtendedLifetime(right) {}
    }

    /// An answer nobody can read is a skew between the two halves, and saying so names the
    /// only thing that fixes it. Never mistaken for a refusal: a refusal is a fact about
    /// the cursor, and this is a fact about the build.
    @Test func anAnswerNobodyCanReadIsSaidByName() async throws {
        let name = aPortNobodyElseUses()
        let port = try InsertionPort(portName: name, queue: DispatchQueue(label: name), told: { _ in }) { _ in Data("nonsense".utf8) }

        await #expect(throws: Unreachable.answerWasNotReadable(port: name, bytes: 8)) {
            try await inserter(name).insert("hello")
        }
        withExtendedLifetime(port) {}
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
