// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ImgSlicer",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ImgSlicer", targets: ["ImgSlicer"])
    ],
    targets: [
        .executableTarget(
            name: "ImgSlicer",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("Vision")
            ]
        ),
        .testTarget(
            name: "ImgSlicerTests",
            dependencies: ["ImgSlicer"]
        )
    ]
)
