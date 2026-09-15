// swift-tools-version: 6.0
// The probe scripts/live-paste-check and scripts/live-type-check read the screen through.
// A package of its own, beside the scripts rather than inside the app's, because it is a
// measuring instrument and not part of what ships; the scripts build it under .build.
import PackageDescription

let package = Package(
    name: "probe",
    platforms: [.macOS(.v15)],
    dependencies: [.package(name: "low-talker", path: "../..")],
    targets: [.executableTarget(name: "probe", dependencies: [.product(name: "LowTalkerCore", package: "low-talker")])]
)
