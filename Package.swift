// swift-tools-version: 5.9
import PackageDescription
// Apple SDKs already expose SQLite3. Use the installed Windows SDK for the same store tests.
#if os(Windows)
let sqliteTargets: [Target] = [.systemLibrary(name: "SQLite3", path: "Scripts/WindowsSQLite")]
let sqliteDependencies: [Target.Dependency] = ["SQLite3"]
#else
let sqliteTargets: [Target] = []
let sqliteDependencies: [Target.Dependency] = []
#endif

let package = Package(name: "CompanionCore", platforms: [.iOS(.v17), .macOS(.v12)], targets: sqliteTargets + [
    .target(name: "CompanionCore", dependencies: sqliteDependencies, path: "Shared", exclude: ["Scene.swift", "Companion.entitlements"], resources: [.copy("Characters")]),
    .testTarget(name: "CompanionCoreTests", dependencies: ["CompanionCore"], path: "Tests")
])
