import Testing
@testable import NiriCore

// Os mesmos casos do Kinggie (King Bot v2, tests/kinggie-fundo.test.ts): o porte tem que dar os mesmos números.

private func pixels(_ w: Int, _ h: Int, _ rgb: (Int, Int) -> [UInt8]) -> [UInt8] {
    var p: [UInt8] = []
    for y in 0..<h { for x in 0..<w { p += rgb(x, y) + [255] } }
    return p
}

private func channel(_ p: [UInt8], _ k: Int) -> [UInt8] { stride(from: k, to: p.count, by: 4).map { p[$0] } }

@Test func ditherKeepsFourTonesAndMakesBayerCheckerOfGray() {
    var ramp = pixels(64, 8) { x, _ in [UInt8(x * 4), UInt8(255 - x * 4), 128] }
    WallpaperEffect.dither.apply(&ramp, width: 64, height: 8)
    #expect(Set((0..<3).flatMap { channel(ramp, $0) }).sorted() == [0, 85, 170, 255])
    #expect(Set(channel(ramp, 3)) == [255])
    var gray = pixels(4, 4) { _, _ in [128, 128, 128] }
    WallpaperEffect.dither.apply(&gray, width: 4, height: 4)
    let reds = channel(gray, 0)
    #expect(Set(reds).sorted() == [85, 170])
    #expect(reds.filter { $0 == 170 }.count == 8)
    var flat = pixels(4, 4) { x, _ in x < 2 ? [0, 0, 0] : [255, 255, 255] }
    WallpaperEffect.dither.apply(&flat, width: 4, height: 4)
    #expect([flat[0], flat[12]] == [0, 255])
}

@Test func halftoneLightsMoreWhereBrighterAndKeepsBlack() {
    func lit(_ v: UInt8) -> Int {
        var p = pixels(24, 24) { _, _ in [v, v, v] }
        WallpaperEffect.halftone.apply(&p, width: 24, height: 24)
        return channel(p, 0).filter { $0 > 40 }.count
    }
    #expect(lit(0) == 0)
    #expect(lit(40) < lit(120) && lit(120) < lit(250))
    #expect(lit(40) > 0 && lit(120) < 24 * 24)
}

@Test func scanlinesDimOneRowInThreeAndAsciiPicksGlyphByBrightness() {
    var p = pixels(2, 6) { _, _ in [100, 100, 100] }
    WallpaperEffect.scanlines.apply(&p, width: 2, height: 6)
    #expect((0..<6).map { p[$0 * 8] } == [110, 110, 38, 110, 110, 38])
    #expect(WallpaperEffect.glyphs.count == 10)
    #expect([0, 90, 200, 255].map { WallpaperEffect.glyph($0, $0, $0).index } == [0, 3, 7, 9])
}
