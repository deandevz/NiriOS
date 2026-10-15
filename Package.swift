// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NiriOS",
    platforms: [.macOS(.v14)],
    targets: [
        // Modelo de layout e animação. Sem AppKit, sem AX: dá pra testar sem mexer em janela nenhuma.
        .target(name: "NiriCore"),
        // O gerenciador em si: atalhos, Acessibilidade, SkyLight.
        .executableTarget(name: "niri-os", dependencies: ["NiriCore"], path: "Sources/NiriOS"),
        .testTarget(name: "NiriCoreTests", dependencies: ["NiriCore"]),
    ],
    swiftLanguageModes: [.v5]
)
