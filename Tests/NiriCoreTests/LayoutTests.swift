import CoreGraphics
import Testing
@testable import NiriCore

// Tela do MacBook (1728x1117 pt), área útil com margem de 12 e barra de menu de 33.
private let bounds = CGRect(x: 0, y: 0, width: 1728, height: 1117)
private let area = CGRect(x: 12, y: 45, width: 1704, height: 1060)

private func makeLayout(_ n: Int, proportion: Double = 0.5, center: CenterMode = .never) -> Layout {
    var config = LayoutConfig()
    config.centerFocusedColumn = center
    var l = Layout(area: area, bounds: bounds, config: config)
    for i in 0..<n { l.append(WindowID(i + 1), proportion: proportion) }
    l.retarget(at: 0)
    l.snapToTargets()
    return l
}

private func settle(_ l: inout Layout) -> [WindowFrame] {
    var t = 0.0
    while !l.isSettled(at: t) && t < 2 { t += 1.0 / 120 }
    #expect(t < 2, "animação não assentou em 2 s")
    let f = l.frames(at: t)
    l.snapToTargets()  // os testes reutilizam t = 0, então congela o estado final
    return f
}

@Test func springConvergesAndKeepsVelocityOnRetarget() {
    var s = Spring(0)
    s.retarget(1000, at: 0)
    #expect(s.value(at: 0) == 0)
    #expect(s.isSettled(at: 0.6))
    let mid = s.value(at: 0.1), vel = s.velocity(at: 0.1)
    s.retarget(500, at: 0.1)
    #expect(abs(s.value(at: 0.1) - mid) < 1e-9)
    #expect(abs(s.velocity(at: 0.1) - vel) < 1e-9)
}

@Test func twoHalvesFillTheArea() {
    var l = makeLayout(2)
    let f = settle(&l)
    #expect(f[0].rect.minX == 12)
    #expect(f[1].rect.maxX == 1716)
    #expect(f[1].rect.minX - f[0].rect.maxX == 12)
}

@Test func focusRightScrollsMinimally() {
    var l = makeLayout(4)
    #expect(l.focusNeighbor(1, at: 0) == 2)   // a 2 já está visível: não rola
    #expect(settle(&l)[0].rect.minX == 12)
    #expect(l.focusNeighbor(1, at: 0) == 3)   // a 3 está fora: rola até ela encostar na direita
    let f = settle(&l)
    #expect(f[2].rect.maxX == 1716)
    #expect(l.focusNeighbor(-1, at: 0) == 2)  // a 2 ainda está visível: não rola
    #expect(settle(&l)[2].rect.maxX == 1716)
}

@Test func offscreenWindowsParkAtEdgeWithOnePointVisible() {
    var l = makeLayout(4)
    let f = settle(&l)
    #expect(f[2].rect.minX == 1727)
    #expect(f[3].rect.minX == 1727)
}

@Test func growAndFullWidthToggle() {
    var l = makeLayout(2)
    l.resizeFocused(by: 0.1, at: 0)
    #expect(abs(l.columns[0].proportion - 0.6) < 1e-9)
    l.toggleFullWidthFocused(at: 0)
    var f = settle(&l)
    #expect(f[0].rect.width == 1704)
    #expect(f[0].rect.minX == 12)
    l.toggleFullWidthFocused(at: 0)
    f = settle(&l)
    #expect(abs(l.columns[0].proportion - 0.6) < 1e-9)
    #expect(f[0].rect.width == CGFloat(l.pixelWidth(0.6).rounded()))
}

@Test func shrinkStopsAtMinimum() {
    var l = makeLayout(1, proportion: 0.2)
    l.resizeFocused(by: -0.1, at: 0)
    l.resizeFocused(by: -0.1, at: 0)
    #expect(abs(l.columns[0].proportion - 0.1) < 1e-9)
}

@Test func insertGoesRightOfFocusedWithoutShrinking() {
    var l = makeLayout(2)
    l.insert(99, focus: true, at: 0)
    #expect(l.windows == [1, 99, 2])
    #expect(l.focusedWindow == 99)
    // A coluna 2 começa onde estava e desliza; ninguém mudou de largura.
    let start = l.frames(at: 0)
    #expect(start[2].rect.minX == CGFloat(12 + 846 + 12))
    let f = settle(&l)
    #expect(f.allSatisfy { $0.rect.width == 846 })
}

@Test func removeFocusedFocusesRightNeighborAndSlides() {
    var l = makeLayout(3)
    _ = l.focusNeighbor(1, at: 0)
    _ = settle(&l)
    l.remove(2, at: 0)
    #expect(l.focusedWindow == 3)
    let f = settle(&l)
    #expect(f.map(\.rect.minX) == [12, 870])
}

@Test func removingLeftOfFocusedDoesNotJump() {
    var l = makeLayout(4)
    _ = l.focusNeighbor(3, at: 0)
    _ = settle(&l)
    let before = l.frames(at: 10)
    l.remove(1, at: 10)
    let after = l.frames(at: 10)
    #expect(before.dropFirst().map(\.rect) == after.map(\.rect))
}

/// Em todo frame de resize, rolagem e tela cheia: janelas vizinhas visíveis ficam a exatamente
/// `gap` uma da outra (nunca encostam, nunca se sobrepõem), e as estacionadas não invadem a área.
@Test(arguments: [CenterMode.never, .always, .onOverflow])
func gapIsExactInEveryFrame(center: CenterMode) {
    var l = makeLayout(4, proportion: 0.3, center: center)
    let actions: [(inout Layout) -> Void] = [
        { $0.resizeFocused(by: 0.1, at: 0) },
        { _ = $0.focusNeighbor(3, at: 0) },
        { $0.toggleFullWidthFocused(at: 0) },
        { $0.toggleFullWidthFocused(at: 0) },
        { $0.resizeFocused(by: -0.1, at: 0) },
        { _ = $0.focusNeighbor(-3, at: 0) },
    ]
    for act in actions {
        act(&l)
        var t = 0.0
        while t < 1 {
            let f = l.frames(at: t)
            // Estacionada = presa na borda da tela pelo clamp, com 1 pt visível.
            func parked(_ r: CGRect) -> Bool { r.minX == bounds.maxX - 1 || r.maxX == bounds.minX + 1 }
            for (a, b) in zip(f, f.dropFirst()) where !parked(a.rect) && !parked(b.rect) {
                #expect(b.rect.minX - a.rect.maxX == 12, "t=\(t): \(a.rect) e \(b.rect)")
            }
            for p in f where parked(p.rect) {
                #expect(p.rect.maxX <= area.minX || p.rect.minX >= area.maxX, "estacionada invadindo: \(p.rect)")
            }
            t += 1.0 / 120
        }
        l.snapToTargets()
    }
}

@Test func alwaysCenterKeepsFocusedInTheMiddleWhenShrinking() {
    var l = makeLayout(3, proportion: 0.8, center: .always)
    _ = l.focusNeighbor(1, at: 0)
    var f = settle(&l)
    #expect(abs(f[1].rect.midX - area.midX) <= 1)
    l.resizeFocused(by: -0.2, at: 0)
    f = settle(&l)
    #expect(abs(f[1].rect.midX - area.midX) <= 1)
    // As vizinhas aparecem igual dos dois lados.
    #expect(abs((f[1].rect.minX - area.minX) - (area.maxX - f[1].rect.maxX)) <= 1)
}

@Test func shrinkStopsAtAppMinimumWidth() {
    var l = makeLayout(2, center: .always)
    l.setMinWidth(1, 700, at: 0)
    for _ in 0..<5 { l.resizeFocused(by: -0.1, at: 0) }
    let f = settle(&l)
    #expect(f[0].rect.width == 700)
    #expect(f[1].rect.minX - f[0].rect.maxX == 12)
    // No limite, Option+ cresce na hora (não precisa "desfazer" os toques que não fizeram nada).
    l.resizeFocused(by: 0.1, at: 0)
    #expect(settle(&l)[0].rect.width > 700)
}

/// Largura mínima maior que a área útil é leitura errada (app assíncrono): ignorada ao aprender e
/// ao carregar do estado salvo, senão a coluna fica mais larga que a tela e não encolhe mais.
@Test func minWidthWiderThanAreaIsIgnored() {
    var l = makeLayout(2, proportion: 1, center: .always)
    l.setMinWidth(1, 1728, at: 0)
    #expect(l.columns[0].minWidth == 0)
    l.append(3, proportion: 1, minWidth: 1728)
    #expect(l.columns[2].minWidth == 0)
    l.resizeFocused(by: -0.1, at: 0)
    #expect(settle(&l)[0].rect.width < 1704)
}
