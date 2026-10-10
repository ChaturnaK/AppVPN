// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AppVPN",
    platforms: [.macOS("26.0")],
    targets: [.executableTarget(name: "AppVPN", path: "Sources")]
)
