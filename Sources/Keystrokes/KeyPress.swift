/// Something that holds keys down and lets them all go.
///
/// The two acts a HID keyboard performs, and the whole of what has to be true of a thing
/// for text to be typed on it. What is on the other side - the driver in this process, or
/// a root daemon across an XPC boundary - is not a fact anything above here needs, which
/// is what lets the same typing code run under `sudo` against the device and unprivileged
/// against the helper. [LAW:composability]
///
/// There is no `up(_:)`. A caller that released one key at a time would be deciding what
/// the device is holding, and the device is the only thing that can know: it derives every
/// report from its own set of held keys, so a report composed anywhere else is a report
/// that can disagree with what is actually down. Releasing everything is the act that
/// cannot disagree. [LAW:one-source-of-truth]
public protocol KeyPress {
    func down(_ usage: Usage) throws
    func releaseAll() throws
}
