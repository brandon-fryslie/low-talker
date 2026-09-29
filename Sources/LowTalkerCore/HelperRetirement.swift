import Foundation
import ServiceManagement
import os

/// What one launch did about one label the keyboard helper was registered under by a build
/// before v0.1.0-alpha.5, which removed the helper: the registration it found, and what
/// unregistering it answered.
///
/// A value, so the app writes one log line per label from it and a test can read the same
/// line without launching the app. [LAW:effects-at-boundaries] `retire(label:)` is the
/// effect; everything else here is what it meant.
///
/// Goes, with the plists the bundle carries for it, once no installation from before
/// alpha.5 is left to upgrade: low-cleanup-azl.
public struct HelperRetirement: Sendable, CustomStringConvertible {
    public enum Outcome: Sendable, Equatable {
        /// The job was registered and launchd has dropped it.
        case unregistered
        /// There was no job under this label: `SMAppService` documents unregistering one
        /// as `kSMErrorJobNotFound`, and macOS 15 was measured answering success after
        /// reading `.notRegistered`, so either answer means this.
        case nothingRegistered
        /// Anything else, which leaves the job where it was.
        case failed(String)
    }

    public let label: String
    public let found: SMAppService.Status
    public let outcome: Outcome

    public init(label: String, found: SMAppService.Status, unregisterError: (any Error)?) {
        self.label = label
        self.found = found
        let error = unregisterError.map { $0 as NSError }
        self.outcome = switch error {
        case nil: found == .notRegistered ? .nothingRegistered : .unregistered
        case let error? where error.domain == SMAppServiceErrorDomain && error.code == kSMErrorJobNotFound:
            .nothingRegistered
        case let error?: .failed(error.description)
        }
    }

    /// Unregisters the job the bundle's plist for `label` names, reading its registration first.
    ///
    /// Every launch, whatever that registration reads: every answer is an outcome above, so
    /// there is nothing to decide first. [LAW:dataflow-not-control-flow] Nonisolated, so the
    /// status read, a round trip to smd, never holds the main thread.
    public static func retire(label: String) async -> HelperRetirement {
        let helper = SMAppService.daemon(plistName: "\(label).plist")
        let found = helper.status
        do {
            try await helper.unregister()
            return HelperRetirement(label: label, found: found, unregisterError: nil)
        } catch {
            return HelperRetirement(label: label, found: found, unregisterError: error)
        }
    }

    /// Only a failure is an error: a label with nothing under it is the ordinary answer on
    /// every launch after the one that retired it.
    public var level: OSLogType {
        if case .failed = outcome { .error } else { .default }
    }

    public var description: String {
        let answer = switch outcome {
        case .unregistered: "unregistered"
        case .nothingRegistered: "nothing registered"
        case .failed(let error): "unregister failed: \(error)"
        }
        return "retired keyboard helper \(label): SMAppService.Status \(found.rawValue) before, \(answer)"
    }
}
