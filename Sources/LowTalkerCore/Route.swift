/// A rule for turning what was known and what was said into actions. Dictation is the
/// default route; everything in the power layer is another route, written into the
/// config file rather than into code.
///
/// [LAW:composability] A route is a match half and an emit half so that any way of
/// claiming an utterance combines with any way of acting on it. "Send to Slack from
/// anywhere" is the dictation emit with a different target, not a new kind of route.
///
/// [LAW:effects-at-boundaries] Routes are data, and routing is a pure function of the
/// Context and Transcript. Nothing here reads the clipboard, posts events, or
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
    public static let dictation = Route(when: .always, then: .insertTranscript(target: .focus))

    /// What a route claims. Command mode adds cases here: the chord that started
    /// listening, the frontmost app, a keyword at the start of the transcript.
    public enum Match: Hashable, Sendable, CustomStringConvertible {
        case always

        public func matches(_ context: Context, _ transcript: Transcript) -> Bool {
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
        /// The transcript's text, inserted as one action. An empty transcript inserts
        /// nothing, so it produces no action rather than an action that does nothing.
        case insertTranscript(target: InsertTarget)

        public func actions(for transcript: Transcript, in context: Context) -> [Action] {
            switch self {
            case .insertTranscript(let target):
                transcript.text.isEmpty ? [] : [.insertText(text: transcript.text, target: target)]
            }
        }

        public var description: String {
            switch self {
            case .insertTranscript(let target): "insert into \(target)"
            }
        }

        /// The apps this emit names, which is none for every emit that names none.
        ///
        /// A list rather than an optional, so an emit that grows a second target
        /// contributes both without changing what asks. Whether such an app is
        /// installed is not a question this module can answer - it is a fact about one
        /// Mac - so `ConfigGap` asks it at the edge and this only says which ids were
        /// named. [LAW:dataflow-not-control-flow]
        public var appsNamed: [BundleID] {
            switch self {
            case .insertTranscript(let target): target.appsNamed
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

    public init(routes: [Route]) {
        self.routes = routes
    }

    public func actions(for transcript: Transcript, in context: Context) -> [Action] {
        routes.first { $0.when.matches(context, transcript) }
            .map { $0.then.actions(for: transcript, in: context) } ?? []
    }
}
