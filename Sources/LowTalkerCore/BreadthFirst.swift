/// The first element, breadth first from `roots`, that `matches`: every element at one
/// depth is looked at before any at the next. Each element that does not match has
/// its children read as it is passed, so an earlier sibling's children are read before
/// a later sibling matches; nothing below those children is.
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
