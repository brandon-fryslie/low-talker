/// A string with at least one character in it.
///
/// [LAW:types-are-the-program] The theorem "this text is not empty" held as a type rather
/// than as a sentence in a doc comment. A caller holding one cannot be holding `""`, so
/// nothing downstream re-checks and no future call site can quietly reintroduce the empty
/// case - which for `ScreenText` is the difference between a reading and the `[]` that
/// once passed for one.
public struct NonEmptyText: Equatable, Sendable, CustomStringConvertible {
    public let value: String

    /// Refuses the empty string. [LAW:parse-dont-validate] The one crossing, and its
    /// output type is the proof it was made.
    public init?(_ value: String) {
        guard !value.isEmpty else { return nil }
        self.value = value
    }

    public var description: String { value }
}
