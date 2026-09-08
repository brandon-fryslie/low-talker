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
