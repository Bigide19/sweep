// swift-tools-version: 6.0
import PackageDescription

// 로직은 전부 SweepCore에 두고, CLI와 메뉴바 앱은 얇은 껍데기로 둡니다.
// 룰 검증을 CLI로 먼저 돌려볼 수 있어야 UI 없이도 안전성을 확인할 수 있습니다.
let package = Package(
    name: "sweep",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SweepCore", targets: ["SweepCore"]),
        .executable(name: "sweep", targets: ["SweepCLI"]),
        .executable(name: "SweepApp", targets: ["SweepApp"]),
    ],
    targets: [
        // Swift 5 언어 모드를 씁니다. 파일시스템 병렬 스캔에서 Sendable 규칙이
        // 엄격하게 걸리는 지점이 많아, 우선 동작을 확보하고 점진적으로 옮깁니다.
        .target(
            name: "SweepCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "SweepCLI",
            dependencies: ["SweepCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "SweepApp",
            dependencies: ["SweepCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
