import LowTalkerCore
import Testing

/// 1 has a deep branch 10 → 100; 2 is a root beside it.
private func children(_ n: Int) -> [Int] { [1: [10], 10: [100]][n] ?? [] }

@Suite struct BreadthFirstTests {
    /// The match at the root wins over the deeper one a depth-first walk would reach first.
    @Test func theShallowMatchIsFoundBeforeTheDeepBranchIsWalked() {
        #expect(breadthFirst(from: [1, 2], children: children, where: { $0 == 2 || $0 == 100 }) == 2)
        #expect(breadthFirst(from: [1, 2], children: children, where: { $0 == 100 }) == 100)
    }

    @Test func noMatchIsNil() {
        #expect(breadthFirst(from: [1, 2], children: children, where: { $0 == 7 }) == nil)
    }

    struct Unreadable: Error {}

    @Test func aFailedChildReadIsThrown() {
        #expect(throws: Unreadable.self) {
            try breadthFirst(from: [1], children: { _ in throw Unreadable() }, where: { _ in false })
        }
    }
}
