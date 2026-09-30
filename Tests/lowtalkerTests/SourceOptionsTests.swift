@testable import LowTalkerCommands
import LowTalkerCore
import ModelInstall
import Testing

@Suite struct SourceOptionsTests {
    /// One flag names every kind of source, so the text alone decides: two commits are a
    /// revision on the hub, and a directory whose name looks like a host is still a directory.
    @Test(arguments: [
        ("https://github.com/o/r/releases/download/models-1/", "published"),
        ("http://127.0.0.1:8000", "published"),
        ("/tmp/store", "store"),
        ("relative/store", "store"),
        ("huggingface.co", "store"),
        ("\(String(repeating: "a", count: 40))-\(String(repeating: "b", count: 40))", "huggingFace"),
        (String(repeating: "a", count: 40), "store"),
    ])
    func fromNamesTheKindOfSourceByItsText(argument: String, kind: String) {
        let parsed: String? = switch ModelSource(argument: argument) {
        case .published: "published"
        case .store: "store"
        case .huggingFace(_?): "huggingFace"
        case .huggingFace(nil), nil: nil
        }
        #expect(parsed == kind)
    }
}
