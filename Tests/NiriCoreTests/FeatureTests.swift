import Testing
@testable import NiriCore

@Test func borderGoesWithTiling() {
    #expect(Feature.allCases.allSatisfy { $0.isOn([]) })
    #expect(!Feature.border.isOn([.tiling]))
    #expect(!Feature.border.isOn([.border]))
    // Religar a fita traz a borda de volta, se ela não foi desligada por conta própria.
    #expect(Feature.border.isOn([.clipboard]))
    #expect(Feature.clipboard.isOn([.tiling]) && Feature.wallpaper.isOn([.tiling]))
}
