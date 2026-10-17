import CoreGraphics
import Testing
@testable import NiriCore

private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)

private func area(_ r: CGRect) -> CaptureArea {
    var a = CaptureArea(bounds: screen, scale: 2)
    a.select(from: r.origin, to: CGPoint(x: r.maxX, y: r.maxY))
    return a
}

@Test func selectsInAnyDirectionInsideTheScreen() {
    var a = CaptureArea(bounds: screen, scale: 2)
    a.select(from: CGPoint(x: 300, y: 200), to: CGPoint(x: 100, y: 50))
    #expect(a.rect == CGRect(x: 100, y: 50, width: 200, height: 150))
    a.select(from: CGPoint(x: 1700, y: 1100), to: CGPoint(x: 2000, y: -30))
    #expect(a.rect == CGRect(x: 1700, y: 0, width: 28, height: 1100))
    a.selectAll()
    #expect(a.rect == screen && a.pixels == CGRect(x: 0, y: 0, width: 3456, height: 2234))
}

@Test func edgesLandOnWholePixels() {
    var a = CaptureArea(bounds: screen, scale: 2)
    a.select(from: CGPoint(x: 10.3, y: 20.7), to: CGPoint(x: 110.2, y: 70.9))
    #expect(a.rect == CGRect(x: 10.5, y: 20.5, width: 99.5, height: 50.5))
    #expect(a.pixels == CGRect(x: 21, y: 41, width: 199, height: 101))
}

@Test func aClickIsNotAnArea() {
    var a = CaptureArea(bounds: screen, scale: 2)
    #expect(a.isEmpty)
    a.select(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 102, y: 300))
    #expect(a.isEmpty && a.grab(at: CGPoint(x: 101, y: 200), reach: 8) == nil)
}

@Test func movingStopsAtTheEdgeKeepingTheSize() {
    var a = area(CGRect(x: 100, y: 100, width: 200, height: 100))
    let start = a.rect
    a.drag(.inside, from: start, by: CGVector(dx: -500, dy: 50))
    #expect(a.rect == CGRect(x: 0, y: 150, width: 200, height: 100))
    a.drag(.inside, from: start, by: CGVector(dx: 5000, dy: 5000))
    #expect(a.rect == CGRect(x: 1528, y: 1017, width: 200, height: 100))
}

@Test func handleMovesOnlyItsEdgesAndFlipsPastTheOpposite() {
    var a = area(CGRect(x: 100, y: 100, width: 200, height: 100))
    let start = a.rect
    a.drag(.handle(.right), from: start, by: CGVector(dx: 50, dy: 80))
    #expect(a.rect == CGRect(x: 100, y: 100, width: 250, height: 100))
    // A esquerda arrastada 300 pt passa da direita (300): a área vira, com a direita parada.
    a.drag(.handle(.left), from: start, by: CGVector(dx: 300, dy: 0))
    #expect(a.rect == CGRect(x: 300, y: 100, width: 100, height: 100))
    a.drag(.handle(.topLeft), from: start, by: CGVector(dx: -500, dy: -500))
    #expect(a.rect == CGRect(x: 0, y: 0, width: 300, height: 200))
}

@Test func grabsTheNearestHandleThenTheInside() {
    let a = area(CGRect(x: 100, y: 100, width: 200, height: 100))
    #expect(a.grab(at: CGPoint(x: 103, y: 96), reach: 8) == .handle(.topLeft))
    #expect(a.grab(at: CGPoint(x: 200, y: 205), reach: 8) == .handle(.bottom))
    #expect(a.grab(at: CGPoint(x: 305, y: 150), reach: 8) == .handle(.right))
    #expect(a.grab(at: CGPoint(x: 150, y: 120), reach: 8) == .inside)
    #expect(a.grab(at: CGPoint(x: 50, y: 50), reach: 8) == nil)
}

@Test func toolbarGoesBelowThenAboveThenInside() {
    let bar = CGSize(width: 400, height: 40)
    #expect(area(CGRect(x: 600, y: 100, width: 300, height: 200)).toolbarOrigin(bar, margin: 8) == CGPoint(x: 500, y: 308))
    // Encostada embaixo: em cima. Encostada na esquerda: a barra não sai da tela.
    #expect(area(CGRect(x: 0, y: 900, width: 100, height: 200)).toolbarOrigin(bar, margin: 8) == CGPoint(x: 8, y: 852))
    // A tela toda: dentro, no pé.
    var all = CaptureArea(bounds: screen, scale: 2)
    all.selectAll()
    #expect(all.toolbarOrigin(bar, margin: 8) == CGPoint(x: 1320, y: 1069))
}
