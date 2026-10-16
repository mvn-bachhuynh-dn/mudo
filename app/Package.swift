// swift-tools-version: 6.2
import PackageDescription

var products: [Product] = [
    .library(name: "MuDoCore", targets: ["MuDoCore"]),
]
var targets: [Target] = [
    .target(name: "MuDoCore"),
    .testTarget(name: "MuDoCoreTests", dependencies: ["MuDoCore"]),
]

let package = Package(
    name: "MuDo",
    platforms: [.macOS("26.0")],
    products: products,
    targets: targets,
    swiftLanguageModes: [.v6]
)
