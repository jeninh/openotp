// swift-tools-version:5.9
import PackageDescription

// OpenOTPCore: pure logic (OTP detection, storage, models), no AppKit.
// OpenOTP: the macOS app (UI, networking, system integration), depends on OpenOTPCore.
let package = Package(
    name: "OpenOTP",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "OpenOTP", targets: ["OpenOTP"]),
        .library(name: "OpenOTPCore", targets: ["OpenOTPCore"]),
    ],
    targets: [
        .target(name: "OpenOTPCore"),
        .executableTarget(
            name: "OpenOTP",
            dependencies: ["OpenOTPCore"],
            path: "Sources/OpenOTPApp"
        ),
    ]
)
