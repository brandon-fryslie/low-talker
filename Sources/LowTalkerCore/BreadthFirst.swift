/// The first element, breadth first from `roots`, that `matches`: every element at one
/// depth is looked at before any at the next, so a match near the top is found before
/// a deep branch is walked at all.
///
/// [LAW:effects-at-boundaries] The walk knows nothing of where children come from; a
/// caller reading them out of another process passes that read in.
public func breadthFirst<Element>(
    from roots: [Element],
    children: (Element) throws -> [Element],
    where matches: (Element) throws -> Bool
) rethrows -> Element? {
    var queue = roots
    var next = queue.startIndex
    while next < queue.endIndex {
        let element = queue[next]
        next += 1
        if try matches(element) { return element }
        queue += try children(element)
    }
    return nil
}
