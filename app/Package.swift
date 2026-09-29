// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Awan",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Sparkle 2 (MIT) — updates: EdDSA-signed appcast, download, install on quit, relaunch.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Awan",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Awan",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("QuickLookUI"),
                .linkedFramework("PDFKit"),
                // Sparkle.framework sits next to the binary in .build, and in Contents/Frameworks in Awan.app.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                              "-Xlinker", "-rpath", "-Xlinker", "@executable_path"]),
            ]
        ),
        .testTarget(
            name: "AwanTests",
            dependencies: ["Awan"],
            path: "Tests/AwanTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
