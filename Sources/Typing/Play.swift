import Foundation
import LowTalkerCore
import Pointing

/// A script of raw mouse reports at fixed times, for a harness that needs the same input
/// to reach macOS on every run: one absolute starting point, then reports at offsets from
/// a clock started once the cursor is there.
///
/// Raw and not corrected, because the point of a replay is that acceleration sees
/// identical input each time; a path the pointer's loop corrected would ask for different
/// counts on every run. The start is the one place the loop is used, before the clock.
///
/// [LAW:parse-dont-validate] A `Play` that exists is a script that can be played whole:
/// at least one report, times that never go backwards, and no button left held at the
/// end. Nothing downstream asks any of that again.
public struct Play: Hashable, Sendable {
    public let start: ScreenPoint
    public let events: [Timed]

    /// The latest a report may be due, in milliseconds: an hour, far past any measurement
    /// and far short of the nanoseconds an `Int64` holds, so a mistyped exponent is
    /// refused by name rather than trapping the conversion.
    public static let longest = 3_600_000.0

    /// One report and when it is due, as an offset from the clock's start.
    public struct Timed: Hashable, Sendable {
        public let at: Duration
        public let report: Report
    }

    /// The four acts `Pointing` performs, as data. [LAW:one-type-per-behavior]
    public enum Report: Hashable, Sendable {
        case move(Move)
        case wheel(Scroll)
        case down(Button)
        case up
    }

    /// Parses JSON Lines: `{"to":{"x":800,"y":500}}` first, then one report a line -
    /// `{"t_ms":0,"down":"left"}`, `{"t_ms":8.3,"move":{"dx":4,"dy":0}}`,
    /// `{"t_ms":16.7,"wheel":{"v":-1,"h":0}}`, `{"t_ms":1000,"up":true}`. Blank lines are
    /// skipped. A key a line does not take is refused, so a misspelt report is never
    /// played as something else. [LAW:no-silent-failure]
    public static func parse(_ text: String) throws -> Play {
        // Any newline, because "\r\n" is one Character and a split on "\n" never finds it.
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated()
            .map { (number: $0.offset + 1, text: $0.element.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.text.isEmpty }
        guard let first = lines.first, let last = lines.last, lines.count > 1 else {
            throw ScriptInvalid(line: lines.first?.number ?? 1, reason: "a script is a {\"to\":{\"x\":…,\"y\":…}} line and at least one report after it")
        }
        let start = try decode(StartLine.self, first).to
        let events = try lines.dropFirst().map { try decode(ReportLine.self, $0).timed }
        for (line, (previous, next)) in zip(lines.dropFirst(2), zip(events, events.dropFirst())) where next.at < previous.at {
            throw ScriptInvalid(line: line.number, reason: "t_ms goes backwards: \(next.at) after \(previous.at)")
        }
        let held = events.reduce(into: Set<Button>()) { held, event in
            switch event.report {
            case .down(let button): held.insert(button)
            case .up: held.removeAll()
            case .move, .wheel: break
            }
        }
        guard held.isEmpty else {
            throw ScriptInvalid(line: last.number, reason: "the script ends with button \(held.sorted().map { "\($0.rawValue)" }.joined(separator: ", ")) held: end it with {\"t_ms\":…,\"up\":true}")
        }
        return Play(start: start, events: events)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ line: (number: Int, text: String)) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: Data(line.text.utf8))
        } catch let refused as Refusal {
            throw ScriptInvalid(line: line.number, reason: refused.reason)
        } catch let DecodingError.keyNotFound(key, _) {
            throw ScriptInvalid(line: line.number, reason: "\(key.stringValue.debugDescription) is missing")
        } catch let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(_, context), let DecodingError.dataCorrupted(context) {
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            throw ScriptInvalid(line: line.number, reason: (path.isEmpty ? "" : "\(path): ") + context.debugDescription)
        }
    }

    /// A script line that is not what a script says, or reports that cannot be played whole.
    public struct ScriptInvalid: Error, CustomStringConvertible {
        public let line: Int
        public let reason: String

        public var description: String { "line \(line) of the script: \(reason)" }
    }
}

/// What a line's own decoding refuses, before anyone knows which line it was.
private struct Refusal: Error {
    let reason: String
}

private struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ name: String) { stringValue = name }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// A line's keys, refusing any it does not take by name.
private func container(_ decoder: Decoder, taking allowed: Set<String>) throws -> KeyedDecodingContainer<AnyKey> {
    let container = try decoder.container(keyedBy: AnyKey.self)
    let unknown = container.allKeys.map(\.stringValue).filter { !allowed.contains($0) }.sorted()
    guard unknown.isEmpty else {
        throw Refusal(reason: "unknown key \(unknown.map(\.debugDescription).joined(separator: ", ")): this line takes \(allowed.sorted().joined(separator: ", "))")
    }
    return container
}

private struct StartLine: Decodable {
    let to: ScreenPoint

    init(from decoder: Decoder) throws {
        to = try container(decoder, taking: ["to"]).decode(ScreenPoint.self, forKey: AnyKey("to"))
    }
}

/// `t_ms` and exactly one of the four reports.
private struct ReportLine: Decodable {
    static let reports: Set<String> = ["down", "move", "up", "wheel"]
    let timed: Play.Timed

    init(from decoder: Decoder) throws {
        let line = try container(decoder, taking: Self.reports.union(["t_ms"]))
        let named = line.allKeys.map(\.stringValue).filter(Self.reports.contains).sorted()
        guard named.count == 1, let report = named.first else {
            throw Refusal(reason: "a line carries exactly one of \(Self.reports.sorted().joined(separator: ", ")), and this one has \(named.isEmpty ? "none" : named.joined(separator: " and "))")
        }
        let milliseconds = try line.decode(Double.self, forKey: AnyKey("t_ms"))
        guard (0...Play.longest).contains(milliseconds) else {
            throw Refusal(reason: "t_ms is \(milliseconds), and it is milliseconds from the start, 0 through \(Int(Play.longest)), an hour")
        }
        let key = AnyKey(report)
        let decoded: Play.Report
        switch report {
        case "move":
            let (x, y) = try axes(line, key, "dx", "dy")
            decoded = .move(Move(x: x, y: y))
        case "wheel":
            let (vertical, horizontal) = try axes(line, key, "v", "h")
            decoded = .wheel(Scroll(vertical: vertical, horizontal: horizontal))
        case "down":
            decoded = .down(Button(try line.decode(MouseButton.self, forKey: key)))
        default:
            guard try line.decode(Bool.self, forKey: key) else { throw Refusal(reason: "up releases every button and is written \"up\":true") }
            decoded = .up
        }
        timed = Play.Timed(at: .nanoseconds(Int64((milliseconds * 1e6).rounded())), report: decoded)
    }
}

/// A report's two axes, each refused rather than clamped when the device cannot carry it:
/// a replay that quietly sent 127 for 200 would not be the script. [LAW:no-silent-failure]
private func axes(_ line: KeyedDecodingContainer<AnyKey>, _ report: AnyKey, _ first: String, _ second: String) throws -> (Count, Count) {
    let axes = try container(line.superDecoder(forKey: report), taking: [first, second])
    func count(_ axis: String) throws -> Count {
        let value = try axes.decode(Int.self, forKey: AnyKey(axis))
        guard (-Count.limit...Count.limit).contains(value) else {
            throw Refusal(reason: "\(report.stringValue).\(axis) is \(value), and a report carries -\(Count.limit) through \(Count.limit)")
        }
        return Count(clamping: value)
    }
    return try (count(first), count(second))
}
