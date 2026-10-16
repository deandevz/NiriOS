import CoreGraphics
import Testing
@testable import NiriCore

private let bounds = CGRect(x: 0, y: 0, width: 1728, height: 1117)
private let area = CGRect(x: 12, y: 45, width: 1704, height: 1060)

/// `counts[i]` janelas no workspace i, numeradas a partir de 1 + 10 * i.
private func makeWorkspaces(_ counts: [Int]) -> Workspaces {
    var w = Workspaces(names: counts.indices.map { "\($0 + 1)" }, area: area, bounds: bounds, config: LayoutConfig())
    for (i, n) in counts.enumerated() {
        for j in 0..<n { w[i].append(WindowID(1 + 10 * i + j)) }
        w[i].retarget(at: 0)
    }
    w.snapToTargets()
    return w
}

private func parked(_ r: CGRect) -> Bool { r.minX == bounds.maxX - 1 || r.maxX == bounds.minX + 1 }

private func rect(_ f: [WindowFrame], _ id: WindowID) -> CGRect { f.first { $0.window == id }!.rect }

/// Roda a animação até assentar e devolve todos os frames, a 120 Hz.
private func run(_ w: inout Workspaces, from t0: Double = 0) -> [[WindowFrame]] {
    var t = t0, out: [[WindowFrame]] = []
    while !w.isSettled(at: t) && t < t0 + 2 { out.append(w.frames(at: t)); t += 1.0 / 120 }
    #expect(t < t0 + 2, "animação não assentou em 2 s")
    out.append(w.frames(at: t))
    w.snapToTargets()
    return out
}

@Test func onlyTheFirstWorkspaceStartsOnScreen() {
    let w = makeWorkspaces([2, 2, 1])
    let f = w.frames(at: 0)
    #expect(!parked(rect(f, 1)) && !parked(rect(f, 2)))
    #expect([11, 12, 21].allSatisfy { parked(rect(f, $0)) })
}

/// Em todo frame da troca: nada se sobrepõe na tela, as duas fitas andam juntas (a nova encosta na velha) e,
/// no fim, a velha está estacionada à esquerda e a nova no lugar de sempre.
@Test func switchSlidesBothStripsTogether() {
    var w = makeWorkspaces([2, 2])
    let home = w.frames(at: 0).filter { $0.window < 10 }.map(\.rect)
    w.switchTo(1, at: 0)
    let frames = run(&w)
    for f in frames {
        let shown = f.map(\.rect).filter { !parked($0) }
        for (i, a) in shown.enumerated() {
            for b in shown[(i + 1)...] { #expect(a.intersection(b).width <= 0, "sobreposição: \(a) e \(b)") }
        }
    }
    let end = frames.last!
    #expect(rect(end, 1).maxX == bounds.minX + 1 && rect(end, 2).maxX == bounds.minX + 1)
    #expect([rect(end, 11), rect(end, 12)] == home)
}

/// Fita mais larga que a tela (duas colunas de largura total, como o Discord e o WhatsApp no 2): na troca, a
/// coluna fora da viewport fica estacionada o tempo todo, nos dois sentidos, e nada se sobrepõe na tela.
@Test func offscreenColumnsOfWideStripStayParkedWhileSwitching() {
    var w = Workspaces(names: ["2", "T"], area: area, bounds: bounds, config: LayoutConfig())
    w[0].append(1, proportion: 1)
    w[0].append(2, proportion: 1)
    w[1].append(11, proportion: 1)
    for i in 0..<2 { w[i].retarget(at: 0) }
    w.snapToTargets()
    for k in [1, 0] {  // o 2 sai pela esquerda, depois entra por ela
        w.switchTo(k, at: 0)
        for f in run(&w) {
            #expect(parked(rect(f, 2)), "a coluna fora da viewport entrou na tela: \(rect(f, 2))")
            let shown = f.map(\.rect).filter { !parked($0) }
            for (i, a) in shown.enumerated() {
                for b in shown[(i + 1)...] { #expect(a.intersection(b).width <= 0, "sobreposição: \(a) e \(b)") }
            }
        }
    }
}

/// Coluna só em parte na tela, passando da borda `side`: desliza colada na vizinha `pair` a troca inteira, nos
/// dois sentidos (antes sumia na troca e aparecia no fim, o WhatsApp ao lado do Discord de 2/3), sem sobrepor
/// nada na tela. `far`, fora da viewport, fica estacionada o tempo todo. No fim, tudo volta pro lugar.
private func checkPartlyVisibleColumnSlides(_ w: inout Workspaces, from k0: Int, to k1: Int,
                                            pair: (WindowID, WindowID), partial: WindowID, far: WindowID) {
    let before = w.frames(at: 0)
    let p = rect(before, partial)
    #expect(!parked(p) && (p.minX < bounds.minX || p.maxX > bounds.maxX))  // o pedaço que passa da borda
    for k in [k1, k0] {
        w.switchTo(k, at: 0)
        let frames = run(&w)
        for f in frames {
            let a = rect(f, pair.0), b = rect(f, pair.1)
            if !parked(a) && !parked(b) { #expect(b.minX - a.maxX == 12, "a coluna em parte na tela descolou da vizinha: \(a) e \(b)") }
            #expect(parked(rect(f, far)), "a coluna fora da viewport entrou na tela: \(rect(f, far))")
            let shown = f.map(\.rect).filter { !parked($0) }
            for (i, a) in shown.enumerated() {
                for b in shown[(i + 1)...] { #expect(a.intersection(b).width <= 0, "sobreposição: \(a) e \(b)") }
            }
        }
        #expect(frames.filter { !parked(rect($0, partial)) }.count > frames.count / 2, "a coluna em parte na tela sumiu na troca")
    }
    #expect(w.frames(at: 0) == before)
}

/// O 2 do uso: Discord de 2/3 focado e WhatsApp de largura total passando da borda direita, mais uma coluna
/// fora da viewport. O 2 sai pela esquerda e volta por ela.
@Test func partlyVisibleColumnOnTheRightSlidesWithItsStrip() {
    var w = Workspaces(names: ["2", "T"], area: area, bounds: bounds, config: LayoutConfig())
    w[0].append(1, proportion: 2.0 / 3)
    w[0].append(2, proportion: 1)
    w[0].append(3, proportion: 0.5)
    w[1].append(11, proportion: 1)
    for i in 0..<2 { w[i].retarget(at: 0) }
    w.snapToTargets()
    checkPartlyVisibleColumnSlides(&w, from: 0, to: 1, pair: (1, 2), partial: 2, far: 3)
}

/// Espelho: a focada é a última, a do lado passa da borda esquerda e outra está fora da viewport à esquerda. O
/// workspace sai pela direita e volta por ela (o pedaço escondido aparece ao andar pra direita).
@Test func partlyVisibleColumnOnTheLeftSlidesWithItsStrip() {
    var w = Workspaces(names: ["1", "2"], area: area, bounds: bounds, config: LayoutConfig())
    w[0].append(1, proportion: 1)
    w[1].append(11, proportion: 0.5)
    w[1].append(12, proportion: 1)
    w[1].append(13, proportion: 2.0 / 3)
    w[1].focus(13, at: 0)
    for i in 0..<2 { w[i].retarget(at: 0) }
    w.switchTo(1, at: 0)
    w.snapToTargets()
    checkPartlyVisibleColumnSlides(&w, from: 1, to: 0, pair: (12, 13), partial: 12, far: 11)
}

/// Do 1 pro 3, o 2 não atravessa a tela; voltando pro 2, ele entra pela esquerda.
@Test func skippedWorkspaceNeverCrossesTheScreen() {
    var w = makeWorkspaces([1, 1, 1])
    w.switchTo(2, at: 0)
    #expect(run(&w).allSatisfy { parked(rect($0, 11)) })
    w.switchTo(1, at: 0)
    let frames = run(&w)
    let firstShown = frames.map { rect($0, 11) }.first { !parked($0) }!
    #expect(firstShown.minX < 0)
    #expect(parked(rect(frames.last!, 21)) && rect(frames.last!, 21).minX == bounds.maxX - 1)
}

/// Voltar no meio da troca não pula: a posição continua de onde estava e nenhum frame anda mais que um
/// pico de mola (~150 pt a 120 Hz pra uma tela de 1728).
@Test func reversingMidSwitchIsContinuous() {
    var w = makeWorkspaces([1, 1])
    w.switchTo(1, at: 0)
    let mid = w.frames(at: 0.1)
    w.switchTo(0, at: 0.1)
    #expect(w.frames(at: 0.1) == mid)
    var last = mid
    var t = 0.1
    while !w.isSettled(at: t) && t < 3 {
        t += 1.0 / 120
        let f = w.frames(at: t)
        for (a, b) in zip(last, f) { #expect(abs(a.rect.minX - b.rect.minX) < 200) }
        last = f
    }
    #expect(!parked(rect(last, 1)) && parked(rect(last, 11)))
}

/// Mandar a focada pro outro workspace: sai da tela na hora, vira a focada de lá, o foco daqui vai pra
/// vizinha, e em nenhum frame ela ou as vizinhas se sobrepõem.
@Test func moveParksWindowAndFocusesNeighbor() {
    var w = makeWorkspaces([3, 1])
    _ = w[0].focusNeighbor(1, at: 0)
    w.snapToTargets()
    w.move(2, to: 1, at: 0)
    #expect(rect(w.frames(at: 0), 2).minX == bounds.maxX - 1)
    #expect(w[0].windows == [1, 3] && w[0].focusedWindow == 3)
    #expect(w[1].windows == [11, 2] && w[1].focusedWindow == 2)
    let frames = run(&w)
    for f in frames {
        let shown = f.map(\.rect).filter { !parked($0) }
        for (i, a) in shown.enumerated() {
            for b in shown[(i + 1)...] { #expect(a.intersection(b).width <= 0, "sobreposição: \(a) e \(b)") }
        }
    }
    let end = frames.last!
    #expect(rect(end, 2).minX == bounds.maxX - 1)
    #expect(rect(end, 3).minX - rect(end, 1).maxX == 12)
    w.switchTo(1, at: 0)
    #expect(!parked(rect(run(&w).last!, 2)))
}

/// Largura mínima e a de antes do Option+F vão junto com a janela.
@Test func moveKeepsColumnWidths() {
    var w = makeWorkspaces([2, 0])
    w[0].setMinWidth(1, 900, at: 0)
    w[0].toggleFullWidthFocused(at: 0)
    w.move(1, to: 1, at: 0)
    let c = w[1].columns[0]
    #expect(c.minWidth == 900 && c.proportion == 1 && c.savedProportion == 0.5)
}

@Test func renamingWorkspacesNeverLosesWindows() {
    var w = makeWorkspaces([2, 1, 1])
    let all = Set(w.windows)
    w.setNames(["2", "T"], at: 0)
    #expect(w.names == ["2", "T"] && w.active == 0)
    #expect(Set(w.windows) == all)
    #expect(Set(w[0].windows) == [11, 1, 2, 21])  // os do 1 e do 3 vieram pro atual
}

/// Nome novo no lugar de um que saiu é o mesmo workspace: as janelas ficam nele, inclusive no da tela.
@Test func renamingInPlaceKeepsWindows() {
    var w = makeWorkspaces([2, 1, 1])
    #expect(w.setNames(["A", "W", "3"], at: 0) == ["1": "A", "2": "W"])
    #expect(w.names == ["A", "W", "3"] && w.active == 0)
    #expect(w[0].windows == [1, 2] && w[1].windows == [11] && w[2].windows == [21])
    // Trocar de lugar e incluir um novo não é renomear.
    #expect(w.setNames(["W", "A", "N", "3"], at: 0).isEmpty)
    #expect(w.active == 1 && w[0].windows == [11] && w[1].windows == [1, 2] && w[2].windows.isEmpty)
}

/// Com a mesa à mostra, trocar leva a fita direto pro lado dela; voltando, ela aparece normal.
@Test func switchingWithDesktopShownRestoresIt() {
    var w = makeWorkspaces([2, 1])
    w[0].setDesktop(true, at: 0)
    _ = run(&w)
    w.switchTo(1, at: 0)
    #expect(!w[0].showsDesktop)
    #expect(run(&w).allSatisfy { parked(rect($0, 1)) && parked(rect($0, 2)) })
    w.switchTo(0, at: 0)
    #expect(!parked(rect(run(&w).last!, 1)))
}

/// Mandar uma empilhada pra outro workspace: só ela vai, numa coluna só dela com a largura da coluna (as duas de 1/2
/// juntas: a tela toda); a de cima fica e cresce até o pé.
@Test func movingAStackedWindowLeavesTheRestOfTheColumn() {
    var w = makeWorkspaces([3, 0])
    _ = w[0].focusNeighbor(1, at: 0)
    w[0].consumeOrExpel(-1, at: 0)
    _ = run(&w)
    w.move(2, to: 1, at: 0)
    #expect(w[0].columns.map(\.windows) == [[1], [3]] && w[1].columns.map(\.windows) == [[2]])
    #expect(w[1].columns[0].proportion == 1)
    let end = run(&w).last!
    #expect(rect(end, 1).minY == area.minY && rect(end, 1).height == area.height)
}
