// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "CompanionCore", platforms: [.macOS(.v14), .iOS(.v17)], products: [.library(name: "CompanionCore", targets: ["CompanionCore"])], dependencies: [.package(path: "../../firmware/wp2-apps/ios/WireKit")], targets: [.target(name: "CompanionCore", dependencies: ["WireKit"]), .testTarget(name: "CompanionCoreTests", dependencies: ["CompanionCore", "WireKit"])])
