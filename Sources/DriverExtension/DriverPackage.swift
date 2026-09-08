/// The public package the driver extension ships in, as someone who has to fetch it by
/// hand would name it.
///
/// [LAW:decomposition] Apart from `DriverProbe`, which is about finding the driver on
/// this Mac: this is about the artifact that puts it there, and the two answer different
/// questions to different readers. Onboarding names these to a reader who installed
/// LowTalker.app and has no clone of this repo, for whom `scripts/virtual-hid-driver
/// install` is not an instruction that can be followed.
///
/// [LAW:one-source-of-truth] `scripts/virtual-hid-driver` is the file that actually
/// fetches and checksums the package, so it holds the pin it acts on; this is the copy
/// the app reads out loud, and `make check-docs` fails when the two disagree.
public enum DriverPackage {
    public static let version = "8.4.0"

    /// pqrs's release asset for that version. Built from the version rather than written
    /// out beside it, so a version bump cannot leave a URL pointing at the old release.
    public static var url: String {
        "https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/releases/download/v\(version)/Karabiner-DriverKit-VirtualHIDDevice-\(version).pkg"
    }
}
