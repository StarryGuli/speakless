// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Speakless",
    platforms: [.macOS(.v13)],
    targets: [
        // 一小段 Objective-C：把 AVFoundation 抛出的异常转成普通错误，避免整个 App 崩溃
        .target(name: "CatchObjC", path: "Sources/CatchObjC", publicHeadersPath: "include"),
        .executableTarget(name: "Speakless", dependencies: ["CatchObjC"], path: "Sources/Speakless"),
    ]
)
