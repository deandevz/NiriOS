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

/// Janela que volta (de tela cheia, minimizada) entra no lugar de onde saiu. Entrando à esquerda da focada, o
/// foco continua na mesma janela e nada pula no primeiro frame.
@Test func insertAtPositionKeepsFocusAndDoesNotJump() {
    var l = makeLayout(3, center: .always)
    _ = l.focusNeighbor(2, at: 0)
    _ = settle(&l)
    let before = l.frames(at: 0)
    l.insert(99, position: 1, focus: false, at: 0)
    #expect(l.windows == [1, 99, 2, 3])
    #expect(l.focusedWindow == 3)
    #expect(l.frames(at: 0).filter { $0.window != 99 }.map(\.rect) == before.map(\.rect))
    let f = settle(&l)
    #expect(f.map(\.rect.minX) == f.map(\.rect.minX).sorted())
}

/// O foco adiado sai quando falta pouco: perto do fim, antes de a mola assentar de vez.
@Test func nearComesBeforeSettled() {
    var l = makeLayout(4, center: .always)
    _ = l.focusNeighbor(1, at: 0)
    var t = 0.0
    while !l.isNear(at: t, within: 3) { t += 1.0 / 120 }
    #expect(!l.isSettled(at: t))
    #expect(t > 0.15 && t < 0.35, "t=\(t)")
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

/// Option+Shift+< >: a focada troca de lugar com a vizinha, com larguras diferentes. Nada pula no primeiro frame; em
/// todo frame só as duas que trocam se cruzam (as outras continuam a `gap` exato e ninguém chega a menos de `gap` delas);
/// no fim a ordem é a nova, com o foco na mesma janela. Na ponta, nada muda.
@Test(arguments: [CenterMode.never, .always, .onOverflow])
func moveColumnSwapsWithNeighborWithoutJumping(center: CenterMode) {
    var config = LayoutConfig()
    config.centerFocusedColumn = center
    var l = Layout(area: area, bounds: bounds, config: config)
    for (i, p) in [0.3, 0.5, 0.4, 2.0 / 3, 0.3].enumerated() { l.append(WindowID(i + 1), proportion: p) }
    _ = l.focusNeighbor(2, at: 0)
    _ = settle(&l)
    for (delta, order) in [(1, [1, 2, 4, 3, 5]), (-1, [1, 2, 3, 4, 5]), (-1, [1, 3, 2, 4, 5]), (-1, [3, 1, 2, 4, 5])] {
        let before = Dictionary(uniqueKeysWithValues: l.frames(at: 0).map { ($0.window, $0.rect) })
        #expect(l.moveFocusedColumn(delta, at: 0) == true)
        #expect(l.windows == order.map(WindowID.init))
        #expect(l.focusedWindow == 3)
        #expect(l.frames(at: 0).allSatisfy { before[$0.window] == $0.rect })
        let pair: Set = [WindowID(3), l.windows[l.focusedIndex! - delta]]
        var t = 0.0
        while t < 1 {
            let f = l.frames(at: t), shown = f.filter { !parked($0.rect) }
            for (a, b) in zip(f, f.dropFirst()) where !pair.contains(a.window) && !pair.contains(b.window) && !parked(a.rect) && !parked(b.rect) {
                #expect(b.rect.minX - a.rect.maxX == 12, "t=\(t): \(a.rect) e \(b.rect)")
            }
            for a in shown {
                for b in shown where a.window < b.window && !(pair.contains(a.window) && pair.contains(b.window)) {
                    #expect(a.rect.maxX + 12 <= b.rect.minX || b.rect.maxX + 12 <= a.rect.minX, "t=\(t): \(a.rect) e \(b.rect)")
                }
            }
            t += 1.0 / 120
        }
        let f = settle(&l).filter { !parked($0.rect) }
        for (a, b) in zip(f, f.dropFirst()) { #expect(b.rect.minX - a.rect.maxX == 12) }
    }
    #expect(l.moveFocusedColumn(-1, at: 0) == false)
    #expect(l.windows == [3, 1, 2, 4, 5])
}

/// Outra troca no meio da animação (a tecla repetindo) também não pula.
@Test func moveColumnMidAnimationDoesNotJump() {
    var l = makeLayout(4, proportion: 0.3, center: .always)
    _ = l.focusNeighbor(1, at: 0)
    _ = settle(&l)
    l.moveFocusedColumn(1, at: 0)
    let mid = Dictionary(uniqueKeysWithValues: l.frames(at: 0.08).map { ($0.window, $0.rect) })
    l.moveFocusedColumn(1, at: 0.08)
    #expect(l.windows == [1, 3, 4, 2])
    #expect(l.frames(at: 0.08).allSatisfy { mid[$0.window] == $0.rect })
    let f = settle(&l).filter { !parked($0.rect) }
    #expect(f.map(\.window) == [1, 3, 4, 2])
    for (a, b) in zip(f, f.dropFirst()) { #expect(b.rect.minX - a.rect.maxX == 12) }
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

/// Centralizar a 1ª ou a última coluna deixaria papel de parede do lado: nas pontas a fita encosta
/// na borda da tela, inclusive ao encolher a coluna da ponta.
@Test(arguments: [CenterMode.always, .onOverflow])
func endsOfStripTouchScreenEdges(center: CenterMode) {
    var l = makeLayout(3, proportion: 1, center: center)
    #expect(settle(&l)[0].rect.minX == 12)
    l.resizeFocused(by: -0.5, at: 0)
    var f = settle(&l)
    #expect(f[0].rect.minX == 12)
    #expect(f[1].rect.minX - f[0].rect.maxX == 12)
    _ = l.focusNeighbor(2, at: 0)
    l.resizeFocused(by: -0.5, at: 0)
    f = settle(&l)
    #expect(f[2].rect.maxX == 1716)
    #expect(f[2].rect.minX - f[1].rect.maxX == 12)
}

/// Se a fita inteira cabe na tela, ela fica no centro e trocar o foco não rola nada.
@Test func stripThatFitsStaysCentered() {
    var l = makeLayout(2, proportion: 0.3, center: .always)
    let f = settle(&l)
    #expect(abs((f[0].rect.minX + f[1].rect.maxX) / 2 - area.midX) <= 1)
    _ = l.focusNeighbor(1, at: 0)
    #expect(settle(&l).map(\.rect) == f.map(\.rect))
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
    l.setMinWidth(1, 1704, at: 0)  // a área toda: leitura de app que ainda não aplicou o tamanho
    #expect(l.columns[0].minWidth == 0)
    l.append(3, proportion: 1, minWidth: 1728)
    #expect(l.columns[2].minWidth == 0)
    l.resizeFocused(by: -0.1, at: 0)
    #expect(settle(&l)[0].rect.width < 1704)
}

/// Option+/- pula entre larguras prontas (como no niri), partindo de qualquer largura atual.
@Test func presetsStepToNextWidth() {
    var l = makeLayout(2, proportion: 0.77)
    let presets = [1.0 / 3, 0.5, 2.0 / 3, 1]
    l.resizeFocused(toPresetIn: presets, direction: -1, at: 0)
    #expect(abs(l.columns[0].proportion - 0.667) < 0.001)
    l.resizeFocused(toPresetIn: presets, direction: 1, at: 0)
    l.resizeFocused(toPresetIn: presets, direction: 1, at: 0)
    #expect(l.columns[0].proportion == 1)
    l.resizeFocused(toPresetIn: presets, direction: 1, at: 0)  // na ponta: nada muda
    #expect(l.columns[0].proportion == 1)
    for _ in 0..<5 { l.resizeFocused(toPresetIn: presets, direction: -1, at: 0) }
    #expect(abs(l.columns[0].proportion - 0.333) < 0.001)
}

@Test func configReloadSlidesWithoutJumping() {
    var l = makeLayout(3, proportion: 0.3, center: .always)
    let before = l.frames(at: 0)
    var c = l.config
    c.gap = 30
    c.stiffness = 400
    l.setConfig(c, at: 0)
    l.setArea(area.insetBy(dx: 18, dy: 18), bounds: bounds, at: 0)  // gap maior também encolhe a área
    // Na hora do reload nada pula na horizontal (altura e topo mudam direto: não são animados).
    #expect(l.frames(at: 0).map { [$0.rect.minX, $0.rect.width] } == before.map { [$0.rect.minX, $0.rect.width] })
    let after = settle(&l)
    for (a, b) in zip(after, after.dropFirst()) { #expect(b.rect.minX - a.rect.maxX == 30) }
}

private func parked(_ r: CGRect) -> Bool { r.minX == bounds.maxX - 1 || r.maxX == bounds.minX + 1 }

/// Option+D: cada janela sai pela borda mais próxima e fica estacionada com 1 pt; de novo, tudo volta
/// exatamente pro lugar.
@Test func desktopParksEveryWindowAtNearestEdgeAndComesBack() {
    var l = makeLayout(3, center: .always)
    _ = l.focusNeighbor(1, at: 0)
    let before = settle(&l)
    l.setDesktop(true, at: 0)
    let shown = settle(&l)
    #expect(shown.allSatisfy { parked($0.rect) })
    #expect(shown.map { $0.rect.minX < bounds.midX } == [true, false, false])  // a focada (no meio) vai pra direita
    l.setDesktop(false, at: 0)
    #expect(settle(&l).map(\.rect) == before.map(\.rect))
}

/// Em todo frame da saída e da volta: ninguém se sobrepõe, vizinhas do mesmo lado continuam a `gap`
/// exato, e quem estava estacionada não entra na tela.
@Test(arguments: [CenterMode.never, .always])
func desktopAnimationKeepsGapsAndNeverOverlaps(center: CenterMode) {
    var l = makeLayout(5, proportion: 0.4, center: center)
    _ = l.focusNeighbor(2, at: 0)
    _ = settle(&l)
    let split = l.frames(at: 0).prefix { $0.rect.midX < bounds.midX }.count
    for on in [true, false] {
        l.setDesktop(on, at: 0)
        var t = 0.0
        while t < 1 {
            let f = l.frames(at: t)
            for (i, (a, b)) in zip(f, f.dropFirst()).enumerated() where !parked(a.rect) && !parked(b.rect) {
                #expect(b.rect.minX - a.rect.maxX >= 12, "t=\(t): \(a.rect) e \(b.rect)")
                if i + 1 != split { #expect(b.rect.minX - a.rect.maxX == 12, "t=\(t): \(a.rect) e \(b.rect)") }
            }
            for p in f where parked(p.rect) {
                #expect(p.rect.maxX <= area.minX || p.rect.minX >= area.maxX, "estacionada invadindo: \(p.rect)")
            }
            t += 1.0 / 120
        }
        l.snapToTargets()
    }
}

/// Janela nova ou foco (Cmd+Tab, Dock) trazem a fita de volta; fechar uma janela escondida não.
@Test func desktopEndsOnNewWindowOrFocusButNotOnClose() {
    var l = makeLayout(3, center: .always)
    l.setDesktop(true, at: 0)
    _ = settle(&l)
    l.remove(1, at: 0)
    #expect(l.showsDesktop)
    #expect(settle(&l).allSatisfy { parked($0.rect) })
    l.focus(l.focusedWindow!, at: 0)
    #expect(!l.showsDesktop)
    #expect(!settle(&l).allSatisfy { parked($0.rect) })
    l.setDesktop(true, at: 0)
    l.insert(99, focus: true, at: 0)
    #expect(!l.showsDesktop)
    let f = settle(&l)
    #expect(f.contains { $0.window == 99 && !parked($0.rect) })
}

// MARK: - Janelas empilhadas na coluna (Option+Cmd)

private func frame(_ f: [WindowFrame], _ id: WindowID) -> CGRect { f.first { $0.window == id }!.rect }

/// Janelas da mesma coluna: mesmo x e largura, a de cima encosta no topo da área, a de baixo no pé, e entre elas `gap`.
private func expectStacked(_ f: [WindowFrame], _ ids: [WindowID], _ note: String = "") {
    let r = ids.map { frame(f, $0) }
    #expect(r.first!.minY == area.minY && r.last!.maxY == area.maxY, "\(note) \(r)")
    for (a, b) in zip(r, r.dropFirst()) {
        #expect(b.minY - a.maxY == 12, "\(note) \(a) e \(b)")
        #expect(a.minX == b.minX && a.width == b.width, "\(note) \(a) e \(b)")
    }
}

private func overlapping(_ f: [WindowFrame]) -> [(CGRect, CGRect)] {
    let shown = f.map(\.rect).filter { !parked($0) }
    return shown.indices.flatMap { i in shown.indices.filter { $0 > i }.map { (shown[i], shown[$0]) } }
        .filter { let x = $0.0.intersection($0.1); return !x.isNull && x.width > 0 && x.height > 0 }
}

/// Option+Cmd+, .: sozinha, a focada entra na coluna vizinha (embaixo das da esquerda, em cima das da direita) e a coluna
/// fica com a largura das duas somadas; empilhada, sai pra uma coluna só dela daquele lado e as duas ficam com a metade.
/// Nada pula no primeiro frame, em nenhum frame uma janela fica por cima de outra (as duas fases), e no fim a coluna
/// empilhada divide a altura por igual com `gap` exato.
@Test(arguments: [CenterMode.never, .always, .onOverflow])
func consumeStacksIntoNeighborAndExpelSplitsItBack(center: CenterMode) {
    var config = LayoutConfig()
    config.centerFocusedColumn = center
    var l = Layout(area: area, bounds: bounds, config: config)
    for (i, p) in [0.5, 0.3, 0.4].enumerated() { l.append(WindowID(i + 1), proportion: p) }
    _ = l.focusNeighbor(1, at: 0)
    _ = settle(&l)
    let steps: [(Int, [[WindowID]], Double)] = [(-1, [[1, 2], [3]], 0.8), (1, [[1], [2], [3]], 0.4), (1, [[1], [2, 3]], 0.8), (-1, [[1], [2], [3]], 0.4)]
    for (delta, columns, width) in steps {
        let before = Dictionary(uniqueKeysWithValues: l.frames(at: 0).map { ($0.window, $0.rect) })
        #expect(l.consumeOrExpel(delta, at: 0) == true)
        #expect(l.columns.map(\.windows) == columns)
        #expect(l.focusedWindow == 2)
        #expect(l.frames(at: 0).allSatisfy { before[$0.window] == $0.rect }, "pulou no primeiro frame")
        var t = 0.0
        while t < 1.5 {
            let f = l.frames(at: t)
            #expect(f.allSatisfy { $0.rect.width > 0 && $0.rect.height > 0 }, "t=\(t)")
            #expect(overlapping(f).isEmpty, "t=\(t): \(overlapping(f))")
            t += 1.0 / 120
        }
        let f = settle(&l)
        #expect(frame(f, 2).width == CGFloat(l.pixelWidth(width).rounded()))
        for c in l.columns { expectStacked(f, c.windows) }
        let shown = l.columns.map { frame(f, $0.windows[0]) }.filter { !parked($0) }
        for (a, b) in zip(shown, shown.dropFirst()) { #expect(b.minX - a.maxX == 12) }
    }
    _ = l.focusNeighbor(-1, at: 0)
    #expect(l.consumeOrExpel(-1, at: 0) == false)  // sozinha na ponta: nada muda
    #expect(l.columns.map(\.windows) == [[1], [2], [3]])
}

/// Option+Cmd +/-: a altura pula entre 1/3, 1/2 e 2/3, e em todo frame as duas continuam encostadas no topo e no pé, com
/// `gap` exato entre elas. Na ponta da lista, ou sozinha na coluna, nada muda.
@Test func heightPresetsKeepGapExactInEveryFrame() {
    var l = makeLayout(2)
    #expect(l.resizeFocusedHeight(toPresetIn: [1.0 / 3, 0.5, 2.0 / 3], direction: 1, at: 0) == false)
    _ = l.focusNeighbor(1, at: 0)
    l.consumeOrExpel(-1, at: 0)
    _ = settle(&l)
    let avail = area.height - 12
    for (dir, share) in [(1, 2.0 / 3), (1, nil), (-1, 0.5), (-1, 1.0 / 3), (-1, nil), (1, 0.5)] as [(Int, Double?)] {
        #expect(l.resizeFocusedHeight(toPresetIn: [1.0 / 3, 0.5, 2.0 / 3], direction: dir, at: 0) == (share != nil))
        var t = 0.0
        while t < 1 {
            expectStacked(l.frames(at: t), [1, 2], "t=\(t)")
            t += 1.0 / 120
        }
        let f = settle(&l)
        if let share { #expect(abs(frame(f, 2).height - share * avail) <= 1) }
    }
}

/// A tecla repetindo no meio da animação: nada pula e o `gap` continua exato.
@Test func heightResizeMidAnimationDoesNotJump() {
    var l = makeLayout(2)
    _ = l.focusNeighbor(1, at: 0)
    l.consumeOrExpel(-1, at: 0)
    _ = settle(&l)
    l.resizeFocusedHeight(toPresetIn: [1.0 / 3, 0.5, 2.0 / 3], direction: -1, at: 0)
    let mid = l.frames(at: 0.08)
    l.resizeFocusedHeight(toPresetIn: [1.0 / 3, 0.5, 2.0 / 3], direction: 1, at: 0.08)
    #expect(l.frames(at: 0.08) == mid)
    var t = 0.08
    while t < 1 {
        expectStacked(l.frames(at: t), [1, 2], "t=\(t)")
        t += 1.0 / 120
    }
}

/// O app que não encolhe tanto: a outra janela fica com o resto, e a tecla não passa do limite.
@Test func heightRespectsAppMinimum() {
    var l = makeLayout(2)
    _ = l.focusNeighbor(1, at: 0)
    l.consumeOrExpel(-1, at: 0)
    l.setMinHeight(1, 600, at: 0)
    var f = settle(&l)
    #expect(frame(f, 1).height == 600)
    expectStacked(f, [1, 2])
    #expect(l.resizeFocusedHeight(toPresetIn: [1.0 / 3, 0.5, 2.0 / 3], direction: 1, at: 0) == false)
    #expect(l.resizeFocusedHeight(toPresetIn: [1.0 / 3, 0.5, 2.0 / 3], direction: -1, at: 0) == true)
    f = settle(&l)
    #expect(abs(frame(f, 2).height - (area.height - 12) / 3) <= 1)
    l.setMinHeight(2, area.height, at: 0)  // leitura de app que ainda não aplicou o tamanho: ignorada
    #expect(l.columns[0].tiles[1].minHeight == 0)
}

/// Fechar (ou minimizar) uma empilhada: a coluna fica, a outra cresce de onde estava e ganha o foco. Voltando, ela entra
/// no mesmo lugar da coluna.
@Test func closingAStackedWindowKeepsTheColumnAndItComesBackToIt() {
    var l = makeLayout(3, center: .always)
    _ = l.focusNeighbor(1, at: 0)
    l.consumeOrExpel(-1, at: 0)
    let stacked = settle(&l)
    let c = l.remove(2, at: 0)
    #expect(c?.windows == [2] && c?.proportion == 1)
    #expect(l.columns.map(\.windows) == [[1], [3]])
    #expect(l.focusedWindow == 1)
    #expect(frame(l.frames(at: 0), 1) == frame(stacked, 1))
    var f = settle(&l)
    #expect(frame(f, 1).minY == area.minY && frame(f, 1).height == area.height)
    #expect(l.stack(c!, with: 1, above: false, focus: true, at: 0) == true)
    #expect(l.columns.map(\.windows) == [[1, 2], [3]] && l.focusedWindow == 2)
    #expect(frame(l.frames(at: 0), 1) == frame(f, 1))
    f = settle(&l)
    expectStacked(f, [1, 2])
    #expect(f.map(\.rect) == stacked.map(\.rect))
    #expect(false == l.stack(Column(tiles: [], proportion: 0.5, width: Spring(0), offset: Spring(0)), with: 99, above: true, focus: false, at: 0))
}

/// Cada coluna lembra a janela focada dela: voltando pra coluna, o foco vai pra mesma.
@Test func focusRemembersTheActiveWindowOfEachColumn() {
    var l = makeLayout(3)
    _ = l.focusNeighbor(1, at: 0)
    l.consumeOrExpel(-1, at: 0)
    #expect(l.focusInColumn(1) == nil)
    #expect(l.focusInColumn(-1) == 1)
    #expect(l.focusNeighbor(1, at: 0) == 3)
    #expect(l.focusNeighbor(-1, at: 0) == 1)
    l.focus(2, at: 0)
    #expect(l.focusedWindow == 2 && l.focusedIndex == 0)
}

/// Estado salvo: a janela empilhada volta embaixo da anterior, com a parte dela da altura.
@Test func appendStackedRestoresTheColumn() {
    var l = Layout(area: area, bounds: bounds, config: LayoutConfig())
    l.append(1, proportion: 0.5, share: 1)
    l.append(2, share: 2, stacked: true)
    l.append(3, proportion: 0.5)
    l.retarget(at: 0)
    l.snapToTargets()
    #expect(l.columns.map(\.windows) == [[1, 2], [3]])
    let f = l.frames(at: 0)
    expectStacked(f, [1, 2])
    #expect(abs(frame(f, 2).height - 2 * (area.height - 12) / 3) <= 1)
}

/// Option+D com coluna empilhada: as duas saem pelo mesmo lado e voltam pro mesmo lugar.
@Test func desktopMovesAStackedColumnTogether() {
    var l = makeLayout(3, center: .always)
    _ = l.focusNeighbor(1, at: 0)
    l.consumeOrExpel(1, at: 0)  // [[1], [2, 3]]
    let before = settle(&l)
    l.setDesktop(true, at: 0)
    let shown = settle(&l)
    #expect(shown.allSatisfy { parked($0.rect) })
    #expect(frame(shown, 2).minX == frame(shown, 3).minX)
    l.setDesktop(false, at: 0)
    #expect(settle(&l).map(\.rect) == before.map(\.rect))
}

/// Duas de 1/2 lado a lado viram uma coluna da tela toda, partida no meio; separando, voltam a ser duas de 1/2.
@Test func stackingTwoHalvesFillsTheScreenAndSplittingGivesThemBack() {
    var l = makeLayout(2, center: .always)
    let side = settle(&l)
    _ = l.focusNeighbor(1, at: 0)
    l.consumeOrExpel(-1, at: 0)
    let f = settle(&l)
    #expect(frame(f, 1).minX == area.minX && frame(f, 1).width == area.width)
    expectStacked(f, [1, 2])
    l.consumeOrExpel(1, at: 0)
    #expect(settle(&l).map(\.rect) == side.map(\.rect))
}

/// As alturas mínimas dos apps não cabem juntas na coluna (Discord 500 pt e WhatsApp 600 pt em 1048, no uso): não
/// empilha, nem voltando de escondida.
@Test func stackingIsRefusedWhenMinimumHeightsDoNotFit() {
    var l = makeLayout(2)
    l.setMinHeight(1, 500, at: 0)
    l.setMinHeight(2, 600, at: 0)
    _ = l.focusNeighbor(1, at: 0)
    #expect(l.consumeOrExpel(-1, at: 0) == false)
    #expect(l.columns.map(\.windows) == [[1], [2]])
    let c = l.remove(2, at: 0)!
    #expect(l.stack(c, with: 1, above: false, focus: true, at: 0) == false)
}

/// Limite descoberto depois de empilhar, que não cabe: cada uma fica no mínimo dela, sem uma por cima da outra (a de
/// baixo passa do pé da tela), e aprender o mesmo limite de novo não muda nada.
@Test func minimumHeightsThatDoNotFitNeverOverlap() {
    var l = makeLayout(2)
    _ = l.focusNeighbor(1, at: 0)
    l.consumeOrExpel(-1, at: 0)
    #expect(l.setMinHeight(2, 600, at: 0) == true)
    #expect(l.setMinHeight(1, 500, at: 0) == true)
    #expect(l.setMinHeight(1, 500, at: 0) == false)
    let f = settle(&l)
    #expect(frame(f, 1).height == 500 && frame(f, 2).height == 600)
    #expect(frame(f, 2).minY - frame(f, 1).maxY == 12)
    #expect(overlapping(f).isEmpty)
}
