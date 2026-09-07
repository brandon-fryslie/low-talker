/// How a decoder says what is wrong with the value in front of it.
///
/// [LAW:one-source-of-truth] Every hand-written decoder in this module refuses a value
/// the same way, so where a fault is placed is settled here rather than spelled again
/// at each one. The `codingPath` is what `ConfigError` renders as `modes[0].chord`, so
/// a refusal that goes through here arrives knowing where it happened.
extension Decoder {
    func fault(_ why: String) -> DecodingError {
        DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: why))
    }
}
