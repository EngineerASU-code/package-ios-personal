// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "CompanionCore", targets: [
    .target(name: "CompanionCore", path: "Shared", exclude: ["Store.swift", "Scene.swift", "Companion.entitlements"], resources: [.copy("Characters")]),
    .testTarget(name: "CompanionCoreTests", dependencies: ["CompanionCore"], path: "Tests")
])
