// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VPSMonitor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VPSMonitor", targets: ["VPSMonitor"]),
        .executable(name: "vpsmon-mac", targets: ["vpsmon-mac"]),
    ],
    targets: [
        // Pure logic: the contract's types, health rules, formatting, the SSH client and the observable model.
        .target(name: "MonitorCore"),
        // The popover's SwiftUI views, shared by the app and by `vpsmon-mac render`.
        .target(name: "MonitorUI", dependencies: ["MonitorCore"]),
        .executableTarget(name: "VPSMonitor", dependencies: ["MonitorCore", "MonitorUI"]),
        .executableTarget(name: "vpsmon-mac", dependencies: ["MonitorCore", "MonitorUI"]),
        .testTarget(name: "MonitorCoreTests", dependencies: ["MonitorCore"]),
    ]
)
