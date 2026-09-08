import DriverExtension
import Foundation
import Testing
@testable import lowtalker_keyboardd

/// Filing this keyboard's answer with Keyboard Setup Assistant, which the helper does as
/// it starts so the assistant never takes the first line typed.
///
/// The cache is a shared system file holding every keyboard this Mac has ever met - it
/// held fourteen entries when this was written - so the property under test throughout is
/// that writing our one answer leaves all of them alone. Asserted against the merge and a
/// file of the test's own, never against /Library/Preferences: root is not needed to
/// prove any of this, and a test that clobbered the real cache would be the very bug.
/// [LAW:behavior-not-structure]
@Suite struct KeyboardTypeAnswerTests {
    private let key = VirtualKeyboardIdentity.keyboardTypeKey
    private let ansi = VirtualKeyboardIdentity.ansiKeyboardType

    @Test func theAnswerIsFiledUnderThisKeyboardsOwnKey() {
        #expect(KeyboardTypeAnswer.filed(into: [:]) == [key: ansi])
    }

    /// The one thing this must never do. The Mac this was written on already held an
    /// entry from an unrelated country-33 device, and the tempting shortcut in the 3ti.7
    /// notes was to make this keyboard claim country 33 so it would collide with that
    /// entry - a device declaring something untrue about itself, and only until the
    /// unrelated entry was cleared. We add ours and touch nobody else's.
    @Test func everyOtherDevicesAnswerSurvives() {
        let others = ["10203-5824-33": 40, "1031-4176-0": 40, "256-13416-0": 41]
        let filed = KeyboardTypeAnswer.filed(into: others)
        #expect(filed[key] == ansi)
        for (device, answer) in others { #expect(filed[device] == answer, "\(device)") }
    }

    /// Filed on every start, so a start that finds it already there has to leave the same
    /// cache behind rather than a second entry or a changed one.
    @Test func filingTwiceLeavesWhatFilingOnceLeft() {
        let once = KeyboardTypeAnswer.filed(into: ["1031-4176-0": 40])
        #expect(KeyboardTypeAnswer.filed(into: once) == once)
    }

    /// A cache that says this keyboard is something other than ANSI is corrected, because
    /// ANSI is what the reverse map every keystroke goes through is built against: leaving
    /// a stale verdict standing would type the wrong characters rather than raise a dialog.
    @Test func anAnswerThatDisagreesWithTheLayoutIsCorrected() {
        #expect(KeyboardTypeAnswer.filed(into: [key: 41])[key] == ansi)
    }

    // MARK: - the file

    private func scratch(_ name: String) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("keyboardtype-\(name)-\(UUID().uuidString).plist").path
    }

    private func write(_ root: [String: Any], to path: String) throws {
        try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
            .write(to: URL(fileURLWithPath: path))
    }

    private func read(_ path: String) throws -> [String: Any] {
        try PropertyListSerialization.propertyList(
            from: try Data(contentsOf: URL(fileURLWithPath: path)), options: [], format: nil) as? [String: Any] ?? [:]
    }

    /// A Mac that has met no keyboard has no file, and that is an answer rather than a
    /// failure: the assistant has nothing cached, and this is the first entry in it.
    @Test func aMacWithNoCacheYetGetsOne() throws {
        let path = scratch("absent")
        try KeyboardTypeAnswer.file(into: path)
        #expect(try read(path)["keyboardtype"] as? [String: Int] == [key: ansi])
    }

    /// The whole round trip on a file of the test's own: other devices' answers, and the
    /// top-level keys beside the answers, are all still there afterwards.
    @Test func filingKeepsEverythingElseTheFileHeld() throws {
        let path = scratch("populated")
        try write(["keyboardtype": ["10203-5824-33": 40], "somethingElse": "kept"], to: path)
        try KeyboardTypeAnswer.file(into: path)
        let root = try read(path)
        #expect(root["keyboardtype"] as? [String: Int] == ["10203-5824-33": 40, key: ansi])
        #expect(root["somethingElse"] as? String == "kept")
    }

    /// Every start files it, and the write is the merge's result - so a start that finds
    /// its answer already there writes nothing, which is not an operation skipped but an
    /// empty one. It matters because this is a read-modify-write of a file shared with
    /// Keyboard Setup Assistant itself, and every rewrite is another window for a writer
    /// landing between the read and the write to have its entry overwritten by the
    /// snapshot this took. Leaving that window open on the one start that has something
    /// to file, and on no start after it, is the whole of what can be done here.
    ///
    /// Which start it was is the returned value and not a silence: "already there" is the
    /// ordinary case on every boot after the first, and a helper that had stopped filing
    /// anything would look identical without it. [LAW:no-silent-failure]
    @Test func aStartThatFindsTheAnswerAlreadyThereFilesNothing() throws {
        let path = scratch("twice")
        #expect(try KeyboardTypeAnswer.file(into: path) == .filed)
        let filed = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(try KeyboardTypeAnswer.file(into: path) == .alreadyFiled)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == filed)
    }

    /// And that the two outcomes reach a reader as two different sentences, which is the
    /// entire reason there are two of them rather than a Bool nobody looks at. The helper
    /// interpolates the case into the line it logs as it starts, so a reader running
    /// README's `log show` can tell a start that filed the answer from one that found it
    /// already there - and, through that, a working helper from one that has stopped
    /// filing anything.
    ///
    /// Held here because it went missing here once: the enum was justified by a log line
    /// that differed per case while the caller discarded the value and logged one
    /// sentence either way, so the justification was true of the type and false of the
    /// program. [LAW:one-source-of-truth]
    ///
    /// Over every case rather than the two named here, so an outcome added later has to
    /// find its own words instead of quietly sharing another's.
    @Test func theOutcomesSayDifferentThingsToAReader() {
        let said = KeyboardTypeAnswer.Filing.allCases.map { "\($0)" }
        #expect(Set(said).count == said.count, "outcomes a reader cannot tell apart: \(said)")
        #expect(said.allSatisfy { !$0.isEmpty }, "an outcome says nothing to a reader: \(said)")
    }

    /// A cache holding somebody else's answers and not ours is a start with something to
    /// file, so the merge is written and said to have been.
    @Test func aStartThatHasSomethingToAddSaysItFiledIt() throws {
        let path = scratch("others")
        try write(["keyboardtype": ["10203-5824-33": 40]], to: path)
        #expect(try KeyboardTypeAnswer.file(into: path) == .filed)
    }

    /// Onboarding reads this file with no privilege at all, so the mode it is left in is
    /// part of filing the answer and not a detail of how it was written: a cache this
    /// helper tightened would leave the assistant's row permanently unreadable for every
    /// ordinary user, with the answer inside it perfectly correct.
    ///
    /// Every starting condition is here because the filing reaches them by different
    /// paths - measured on this platform, an atomic replace keeps the existing file's
    /// mode while an atomic create takes the writer's umask, and a start with nothing to
    /// file writes nothing at all - and the contract over all of them is one: whoever
    /// wrote it and whatever was there before, the file a reader has to read is
    /// world-readable afterwards. Stated over the conditions rather than the paths, so
    /// it holds a start that repairs the mode and writes nothing else to the same bar as
    /// the one that wrote the file.
    /// [LAW:behavior-not-structure]
    @Test(arguments: Start.allCases)
    func theFiledCacheIsLeftWorldReadable(start: Start) throws {
        let path = scratch("mode")
        // Tightened rather than left as written, because 0600 is the mode every one of
        // these has to be repaired from - the one an atomic replace carries forward.
        if let cached = start.cached {
            try write(["keyboardtype": cached], to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
        try KeyboardTypeAnswer.file(into: path)
        let left = try #require(
            FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)
        #expect(left.int32Value == 0o644, "left \(String(left.int32Value, radix: 8))")
    }

    /// What a start finds on disk, as the conditions themselves rather than as a file and
    /// a mode that would have to be kept agreeing - there is no cache with no file, and a
    /// mode belongs to a file that exists. [LAW:types-are-the-program] `CaseIterable`, so
    /// a condition worth naming later is covered by the contract above the moment it is
    /// named rather than when somebody remembers to list it.
    enum Start: CaseIterable {
        /// A Mac that has met no keyboard: nothing to replace, so the file is created and
        /// takes whatever umask this process inherited from launchd.
        case noCacheYet
        /// Somebody else's answers, tightened. The merge has ours to add, so the file is
        /// replaced - carrying the 0600 forward, which is the path that bites.
        case othersAnswersTightened
        /// Our answer already there, tightened. The merge has nothing to add, so nothing
        /// is written and the mode is the only thing left to repair - the case that made
        /// the guarantee hold on the first boot and never again, because a mode wrong for
        /// any reason after the first filing was read past on every start after it.
        case ourAnswerAlreadyThereTightened

        /// The answers already cached, and nothing at all where there is no file yet.
        var cached: [String: Int]? {
            switch self {
            case .noCacheYet: nil
            case .othersAnswersTightened: ["10203-5824-33": 40]
            case .ourAnswerAlreadyThereTightened:
                [VirtualKeyboardIdentity.keyboardTypeKey: VirtualKeyboardIdentity.ansiKeyboardType]
            }
        }
    }

    /// A mode that could not be set is reported as itself, and not as a lost answer.
    ///
    /// The two failures cost different things and only one of them is about the assistant:
    /// by the time the mode is asserted the answer is filed, so an operator told the
    /// keyboard may swallow the first line typed would be watching for a dialog that is
    /// never going to appear, while the failure that did happen - onboarding can no longer
    /// read the file - went unnamed. Every one of these used to say the same sentence.
    /// [LAW:no-silent-failure]
    ///
    /// Made to fail with the immutable flag, which is what `chmod(2)` refuses: the file is
    /// there and its answers are already this keyboard's, so the merge writes nothing and
    /// the mode is the only thing left to set. It has to start at a mode other than 644,
    /// because macOS lets a no-op chmod through the flag.
    @Test func aModeThatCouldNotBeSetIsReportedAsTheModeAndNotAsALostAnswer() throws {
        let path = scratch("immutable")
        try write(["keyboardtype": [key: ansi]], to: path)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600, .immutable: true], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: path) }

        let failure = #expect(throws: KeyboardTypeAnswer.Unwritable.self) {
            try KeyboardTypeAnswer.file(into: path)
        }
        guard case .modeNotSet = failure else {
            Issue.record("the mode failing was reported as \(String(describing: failure))")
            return
        }
        let said = "\(try #require(failure))"
        #expect(said.contains("is filed"), "the report does not say the answer is filed")
        #expect(!said.contains("may take the first line typed"),
                "the report sends the reader to watch for a dialog that will not appear")
    }

    /// [LAW:no-silent-failure] A file that is there and cannot be understood is refused,
    /// and refused before anything is written. Reading it as "no answers yet" would have
    /// this write back a cache holding one entry where every other keyboard's used to be -
    /// silent data loss on a system file, discovered by the assistant returning for
    /// devices that had already answered it.
    @Test func aCacheThatCannotBeReadIsRefusedAndLeftAlone() throws {
        let path = scratch("garbage")
        try Data("not a plist".utf8).write(to: URL(fileURLWithPath: path))
        #expect(throws: KeyboardTypeAnswer.Unwritable.self) { try KeyboardTypeAnswer.file(into: path) }
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("not a plist".utf8))
    }

    /// The same refusal for a file that parses but holds answers this cannot merge into.
    @Test func answersThisCannotMergeIntoAreRefused() throws {
        let path = scratch("wrong-shape")
        try write(["keyboardtype": "not a dictionary"], to: path)
        #expect(throws: KeyboardTypeAnswer.Unwritable.self) { try KeyboardTypeAnswer.file(into: path) }
        #expect(try read(path)["keyboardtype"] as? String == "not a dictionary")
    }

    // MARK: - why the helper is the one that files it

    /// The reason this is the helper's job and not the app's, kept as a check rather than
    /// as a sentence: the daemon the helper cannot start without lives *inside* the driver
    /// package's own payload. So on a Mac with no driver there is no helper either, and
    /// the app has no root to reach - which is why onboarding names the driver install to
    /// a reader instead of taking it. If this ever stops being true, the ticket's account
    /// of what blocks a self-installing driver row stops being true with it.
    @Test func theDaemonTheHelperNeedsIsInsideThePackageItCouldNotInstall() {
        #expect(DaemonProcess.executable.hasPrefix(DriverProbe.supportDirectory))
    }
}
