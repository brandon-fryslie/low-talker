/// A rule for turning what was known and what was said into actions. Dictation is the
/// default route; everything in the power layer is another route, written into the
/// config file rather than into code.
///
/// [LAW:composability] A route is a match half and an emit half so that any way of
/// claiming an utterance combines with any way of acting on it. Command mode adds
/// cases to each half, and every one it adds meets every one already here.
///
/// [LAW:effects-at-boundaries] Routes are data, and routing is a pure function of the
/// Context and Transcript. Nothing here posts events, types text, or
/// launches programs; the app's executor does that with the Actions returned.
public struct Route: Hashable, Sendable, CustomStringConvertible {
    public let when: Match
    public let then: Emit

    public init(when: Match, then: Emit) {
        self.when = when
        self.then = then
    }

    /// The rule as one line, the way `lowtalker config check` lists it under a mode.
    public var description: String { "\(when) → \(then)" }

    /// Any context, any transcript, the words go to whatever has focus.
    public static let dictation = Route(when: .always, then: .insertTranscript)

    /// What a route claims. Command mode adds cases here: the chord that started
    /// listening, the frontmost app, a keyword at the start of the transcript.
    public enum Match: Hashable, Sendable, CustomStringConvertible {
        case always

        public func matches(_ context: Context, _ transcript: Transcript) -> Bool {
            switch self {
            case .always: true
            }
        }

        /// Whether it claims every utterance before a word of it is heard, so the route it
        /// belongs to decides an utterance that is still being spoken.
        public var claimsUnheard: Bool {
            switch self {
            case .always: true
            }
        }

        /// What this match claims, in a person's words. A case added here has to say
        /// what it claims before it compiles, so a report can never list a match it
        /// has no words for.
        public var description: String {
            switch self {
            case .always: "always"
            }
        }
    }

    /// What a claimed utterance becomes.
    public enum Emit: Hashable, Sendable, CustomStringConvertible {
        /// The transcript's text, inserted at the cursor as one action. A blank
        /// transcript — nothing said — produces no action rather than an action that
        /// does nothing.
        case insertTranscript

        public func actions(for transcript: Transcript, in context: Context) -> [Action] {
            switch self {
            case .insertTranscript: Self.insert(transcript)
            }
        }

        /// What each run of words becomes as it is confirmed, while the utterance is still
        /// being spoken, or nil for an emit that acts on the whole transcript and so waits
        /// for it. The runs' actions, in order, are the whole transcript's.
        public var asHeard: (@Sendable (Transcript) -> [Action])? {
            switch self {
            case .insertTranscript: { Self.insert($0) }
            }
        }

        private static func insert(_ transcript: Transcript) -> [Action] {
            transcript.isBlank ? [] : [.insertText(text: transcript.text)]
        }

        public var description: String {
            switch self {
            case .insertTranscript: "insert at the cursor"
            }
        }
    }
}

/// Consults routes in order; the first whose match claims the utterance decides the
/// actions. An utterance no route claims produces none, which is what "the config
/// has no route for this" should do at speaking time; `lowtalker config check` is
/// where such a gap is reported, not here.
public struct Router: Hashable, Sendable {
    public let routes: [Route]

    /// Speak, and the words are typed wherever the focus is - the whole of what a mode
    /// that names no routes does. Named here, beside the route it is made of, so the
    /// default mode and a config file with no `routes` key mean it by one name instead
    /// of each assembling it. [LAW:one-source-of-truth]
    public static let dictation = Router(routes: [.dictation])

    public init(routes: [Route]) {
        self.routes = routes
    }

    public func actions(for transcript: Transcript, in context: Context) -> [Action] {
        routes.first { $0.when.matches(context, transcript) }
            .map { $0.then.actions(for: transcript, in: context) } ?? []
    }

    /// What each run of confirmed words becomes while the utterance is still being spoken:
    /// the first route's, when it claims every utterance unheard and acts on words as they
    /// come. Nil when the route that decides cannot be known until the words are, or acts
    /// on the whole transcript, such as a spoken edit: such a mode waits for the press to end.
    public var asHeard: (@Sendable (Transcript) -> [Action])? {
        routes.first.flatMap { $0.when.claimsUnheard ? $0.then.asHeard : nil }
    }
}
