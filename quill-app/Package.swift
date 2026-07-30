// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "quill-app",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "QuillApp",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            exclude: ["Info.plist"],
            linkerSettings: [
                // Embed Info.plist into the binary so TCC can attribute the
                // mic/system-audio permissions without an .app bundle.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/QuillApp/Info.plist",
                ]),
            ]
        ),
    ]
)
