import CoreGraphics
import Testing
@testable import NiriCore

// Tela do MacBook (1728x1117 pt), área útil com margem de 12 e barra de menu de 33.
private let bounds = CGRect(x: 0, y: 0, width: 1728, height: 1117)
private let area = CGRect(x: 12, y: 45, width: 1704, height: 1060)

private func makeLayout(_ n: Int, proportion: Double = 1.0 / 3) -> Layout {
    var config = LayoutConfig()
    config.centerFocusedColumn = .never
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
    l.snapToTargets()
    return f
}

private func rect(_ f: [WindowFrame], _ id: WindowID) -> CGRect { f.first { $0.window == id }!.rect }
private func parked(_ r: CGRect) -> Bool { r.minX == bounds.maxX - 1 || r.maxX == bounds.minX + 1 }

/// A do meio sai da fita: as vizinhas fecham o buraco, ela fica solta no meio do lugar dela (altura de 2/3 da área), com
/// o foco, e o 1º frame é o lugar de antes (anda de lá).
@Test func floatLeavesTheStripFromWhereItWas() {
    var l = makeLayout(3)
    _ = l.focusNeighbor(1, at: 0)
    let before = rect(settle(&l), 2)
    let floated = l.float(2, at: 0)
    #expect(floated)
    #expect(l.columns.map(\.windows) == [[1], [3]])
    #expect(l.isFloating(2) && l.floatingFocused && l.focusedWindow == 2)
    #expect(rect(l.frames(at: 0), 2) == before)
    let f = settle(&l)
    let r = rect(f, 2)
    #expect(r.width == before.width && r.height == (area.height * 2 / 3).rounded())
    #expect(abs(r.midX - before.midX) <= 1 && abs(r.midY - before.midY) <= 1)
    #expect(rect(f, 3).minX - rect(f, 1).maxX == 12)
}

/// Volta pra fita à direita da coluna focada, anda de onde estava solta e, solta de novo, vai pro lugar em que a pessoa
/// tinha deixado.
@Test func embedGoesRightOfFocusedAndRemembersTheFloatingFrame() {
    var l = makeLayout(3)
    l.float(2, at: 0)
    _ = settle(&l)
    let dragged = CGRect(x: 300, y: 200, width: 500, height: 400)
    l.setFloatingFrame(2, dragged)
    #expect(l.toggleFloatingFocus() == 1)
    let embedded = l.embed(2, proportion: 0.5, at: 0)
    #expect(embedded)
    #expect(l.columns.map(\.windows) == [[1], [2], [3]])
    #expect(!l.floatingFocused && l.focusedWindow == 2)
    #expect(rect(l.frames(at: 0), 2) == dragged)
    let f = settle(&l)
    #expect(rect(f, 2).width == CGFloat(l.pixelWidth(0.5).rounded()) && rect(f, 2).height == area.height)
    l.float(2, at: 0)
    #expect(rect(settle(&l), 2) == dragged)
}

/// Option Tab vai pra solta de cima e volta pra coluna focada; as setas, com o foco na solta, também voltam pra fita.
@Test func focusMovesBetweenTheStripAndTheTopFloating() {
    var l = makeLayout(2)
    l.addFloating(10, frame: CGRect(x: 100, y: 100, width: 400, height: 300), focus: false)
    l.addFloating(11, frame: CGRect(x: 600, y: 100, width: 400, height: 300), focus: false)
    #expect(l.focusedWindow == 1)
    #expect(l.toggleFloatingFocus() == 11)
    l.focus(10, at: 0)
    #expect(l.focusedWindow == 10 && l.floating.last?.window == 10)
    #expect(l.focusNeighbor(1, at: 0) == 1)  // da solta, volta pra focada da fita sem rolar
    #expect(l.toggleFloatingFocus() == 10)
    #expect(l.toggleFloatingFocus() == 1)
}

/// Com o foco numa solta, os atalhos de coluna não mexem na fita.
@Test func columnActionsIgnoreTheStripWhileAFloatingIsFocused() {
    var l = makeLayout(2)
    l.addFloating(10, frame: CGRect(x: 100, y: 100, width: 400, height: 300), focus: true)
    l.resizeFocused(toPresetIn: [1.0 / 3, 0.5, 2.0 / 3, 1], direction: 1, at: 0)
    l.toggleFullWidthFocused(at: 0)
    let moved = l.moveFocusedColumn(1, at: 0), stacked = l.consumeOrExpel(1, at: 0)
    #expect(!moved && !stacked)
    #expect(l.columns.allSatisfy { abs($0.proportion - 1.0 / 3) < 0.001 && $0.savedProportion == nil })
    #expect(l.columns.map(\.windows) == [[1], [2]])
}

/// Fechar a solta focada devolve o foco pra fita; fechar a última coluna passa o foco pra solta.
@Test func closingMovesFocusBetweenLayers() {
    var l = makeLayout(1)
    l.addFloating(10, frame: CGRect(x: 100, y: 100, width: 400, height: 300), focus: true)
    l.remove(10, at: 0)
    #expect(!l.floatingFocused && l.focusedWindow == 1)
    l.addFloating(10, frame: CGRect(x: 100, y: 100, width: 400, height: 300), focus: false)
    l.remove(1, at: 0)
    #expect(l.focusedWindow == 10)
}

/// Janela que sai da tela entra pra área útil; na tela, fica onde está.
@Test func addedFloatingFitsTheArea() {
    var l = makeLayout(1)
    l.addFloating(10, frame: CGRect(x: 1500, y: 0, width: 600, height: 2000), focus: false)
    let r = l.floating[0].frame
    #expect(area.contains(r) && r.width == 600 && r.height == area.height)
    l.addFloating(11, frame: CGRect(x: 200, y: 300, width: 400, height: 300), focus: false)
    #expect(l.floating[1].frame == CGRect(x: 200, y: 300, width: 400, height: 300))  // dentro: fica onde está
    // Na tela, mesmo passando da área útil (a do Premiere abre com a largura da tela): fica onde o app pôs.
    l.addFloating(12, frame: CGRect(x: 0, y: 71, width: 1728, height: 1046), focus: false)
    #expect(l.floating[2].frame == CGRect(x: 0, y: 71, width: 1728, height: 1046))
}

/// Com a mesa, a solta sai pela borda mais perto do meio dela e estaciona com 1 pt; ao voltar, fica onde estava.
@Test func desktopTakesTheFloatingOut() {
    var l = makeLayout(1)
    let home = CGRect(x: 1100, y: 300, width: 400, height: 300)
    l.addFloating(10, frame: home, focus: false)
    l.setDesktop(true, at: 0)
    #expect(rect(settle(&l), 10).minX == bounds.maxX - 1)
    l.setDesktop(false, at: 0)
    #expect(rect(settle(&l), 10) == home)
}

/// A solta é do workspace: sai com ele na troca (estacionada no fim), volta no mesmo lugar e, mandada pra outro, continua
/// solta no mesmo lugar.
@Test func floatingBelongsToItsWorkspace() {
    var w = Workspaces(names: ["1", "2"], area: area, bounds: bounds, config: LayoutConfig())
    w[0].append(1)
    w[1].append(2)
    let home = CGRect(x: 300, y: 300, width: 400, height: 300)
    w[0].addFloating(10, frame: home, focus: false)
    w.snapToTargets()
    #expect(w.index(of: 10) == 0)
    w.switchTo(1, at: 0)
    var t = 0.0
    while !w.isSettled(at: t) && t < 2 { t += 1.0 / 120 }
    #expect(parked(w.frames(at: t).first { $0.window == 10 }!.rect))
    w.snapToTargets()
    w.switchTo(0, at: 0)
    t = 0
    while !w.isSettled(at: t) && t < 2 { t += 1.0 / 120 }
    #expect(w.frames(at: t).first { $0.window == 10 }!.rect == home)
    w.snapToTargets()
    w.move(10, to: 1, at: 0)
    #expect(w.index(of: 10) == 1 && w[1].isFloating(10) && w[1].floating[0].frame == home && w[1].focusedWindow == 10)
}

/// Apagar o workspace leva as soltas dele pro da tela, soltas.
@Test func removedWorkspaceHandsItsFloatingToTheCurrentOne() {
    var w = Workspaces(names: ["1", "2"], area: area, bounds: bounds, config: LayoutConfig())
    w[1].addFloating(10, frame: CGRect(x: 300, y: 300, width: 400, height: 300), focus: false)
    w.setNames(["1"], at: 0)
    #expect(w.index(of: 10) == 0 && w[0].isFloating(10))
}

/// A gaveta: com o foco na fita, a solta de outro app sai pela borda mais perto do meio dela e estaciona com 1 pt; a do
/// mesmo app da focada e a fixada ficam. O Option Tab abre a gaveta (todas na tela) e voltar pra fita fecha.
@Test func drawerKeepsOnlyPinnedAndSameAppFloatingWhileTheStripIsFocused() {
    var l = makeLayout(2)
    let app: [WindowID: String] = [1: "a", 2: "b", 10: "c", 11: "a"]
    func update() { l.updateDrawer(at: 0) { app[$0] == app[$1] } }
    let left = CGRect(x: 100, y: 200, width: 400, height: 300), right = CGRect(x: 1100, y: 200, width: 400, height: 300)
    l.addFloating(10, frame: left, focus: false)
    l.addFloating(11, frame: right, focus: false)
    update()
    var f = settle(&l)
    #expect(rect(f, 10).maxX == bounds.minX + 1 && rect(f, 11) == right)  // a 1 (app a) focada: a 11 fica
    _ = l.toggleFloatingFocus()
    update()
    f = settle(&l)
    #expect(l.drawerOpen && rect(f, 10) == left && rect(f, 11) == right)
    _ = l.toggleFloatingFocus()
    update()
    #expect(!l.drawerOpen && rect(settle(&l), 10).maxX == bounds.minX + 1)
    #expect(l.togglePinned(10) == true)
    update()
    #expect(rect(settle(&l), 10) == left)
    _ = l.focusNeighbor(1, at: 0)  // a 2, de outro app: a 11 vai pra gaveta, a fixada fica
    update()
    f = settle(&l)
    #expect(rect(f, 10) == left && rect(f, 11).minX == bounds.maxX - 1)
}
