/// What one Accessibility read established about an element's text - and, just as much,
/// what it did not.
///
/// **An app that answers with the empty string is not an app whose screen is empty.**
/// Measured on VS Code, frontmost, with a document open: the focused element answers
/// `kAXValue` with `.success` and a zero-length string. So does a genuinely empty
/// TextEdit document. A reader that hands both back as `""` has collapsed "there is
/// nothing on the screen" into "this app will not tell you", and the caller can never
/// pull them apart again - which is how a run that typed all 29 characters correctly,
/// proven by screenshot, reported `MISMATCH: the screen holds []`.
///
/// [LAW:parse-dont-validate] So the read is parsed here, at the one place a raw
/// Accessibility answer becomes a value, and `reads` is the only case that carries a
/// string. A caller holding one holds evidence about what is on the screen; a caller
/// holding either silence knows it has no verdict and must look at a screenshot
/// instead. [LAW:types-are-the-program] The distinction lives in the type rather than
/// in a convention every call site has to remember.
public enum ScreenText: Equatable, Sendable {
    /// The element answered, and there was text. The payload is `NonEmptyText`, so the
    /// empty reading is unrepresentable rather than merely undocumented: no call site,
    /// here or in a future importer, can construct the case that would print as `[]`.
    case reads(NonEmptyText)
    /// The element answered `kAXValue` with the empty string. Says nothing about the
    /// screen: an empty document and an app that never reports its contents produce
    /// this identical answer.
    case answeredEmpty
    /// The element has no `kAXValue` at all, or answered with something that is not a
    /// string.
    case noValue

    /// The classification, from the answer an Accessibility read came back with: nil
    /// where the call failed or the value was not a string, the string otherwise.
    ///
    /// Pure, and the whole of the rule. [LAW:effects-at-boundaries] The AX call is the
    /// caller's; what its answer means is decided here, where a test can ask without a
    /// window server.
    public init(answer: String?) {
        switch answer {
        case .none: self = .noValue
        // `NonEmptyText`'s refusal IS the classification: the answer that will not become
        // one is the empty answer, so there is no separate emptiness test to keep in step
        // with the payload's own rule. [LAW:one-source-of-truth]
        case .some(let text): self = NonEmptyText(text).map(ScreenText.reads) ?? .answeredEmpty
        }
    }

    /// Whether this reading shows `text` more often than `baseline` did - the check a run
    /// makes to prove its own keystrokes landed, rather than reading back text the screen
    /// was already holding before it typed.
    ///
    /// The two sides are deliberately not symmetric, because a silence does not mean the
    /// same thing in the two positions. A silence *now* is no verdict, so it is never a
    /// yes. A silence in the *baseline* is safely a zero: either the element really held
    /// nothing, and a later reading is honest evidence that the text arrived, or the app
    /// never reports its contents at all - in which case no later reading is ever `reads`
    /// and this cannot fire on it. Reading the empty baseline as a zero is what keeps an
    /// empty TextEdit document verifiable. [LAW:types-are-the-program]
    public func shows(_ text: String, moreThan baseline: ScreenText) -> Bool {
        guard case .reads(let now) = self else { return false }
        return now.value.occurrences(of: text) > baseline.alreadyHeld(text)
    }

    /// How many times a baseline reading is taken to have already held `text`: a silence
    /// held nothing, for the reason `shows` gives.
    private func alreadyHeld(_ text: String) -> Int {
        guard case .reads(let held) = self else { return 0 }
        return held.value.occurrences(of: text)
    }
}

extension ScreenText: CustomStringConvertible {
    /// [LAW:no-silent-failure] A silence describes itself as a silence, so a report that
    /// prints one cannot read as a claim about the screen. The empty answer says what it
    /// is worth, because the operator reading it is about to decide whether the run
    /// failed - and on VS Code and Slack it did not.
    public var description: String {
        switch self {
        case .reads(let text): "[\(text)]"
        case .answeredEmpty: "nothing readable: the element answered with the empty string, which the apps that never report their contents answer while holding text - read a screenshot instead"
        case .noValue: "nothing readable: the element carries no text value at all"
        }
    }
}
