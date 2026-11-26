// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Clearspace",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "Clearspace",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/Clearspace"
        ),
        .testTarget(name: "ClearspaceTests", dependencies: ["Clearspace"], path: "Tests/ClearspaceTests"),
    ]
)
