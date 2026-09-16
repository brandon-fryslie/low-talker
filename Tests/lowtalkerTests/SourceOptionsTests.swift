@testable import lowtalker
import LowTalkerCore
import Testing

@Suite struct SourceOptionsTests {
    /// One flag names both kinds of source, so the scheme alone decides: a directory
    /// whose name looks like a host is still a directory.
    @Test(arguments: [
        ("https://github.com/o/r/releases/download/models-1/", "published"),
        ("http://127.0.0.1:8000", "published"),
        ("/tmp/store", "store"),
        ("relative/store", "store"),
        ("huggingface.co", "store"),
    ])
    func fromIsAPublishedBaseOnlyForHTTP(argument: String, kind: String) {
        let parsed: String? = switch ModelSource(argument: argument) {
        case .published: "published"
        case .store: "store"
        case .huggingFace, nil: nil
        }
        #expect(parsed == kind)
    }
}
