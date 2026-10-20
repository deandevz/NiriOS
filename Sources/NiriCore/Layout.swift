import CoreGraphics

public typealias WindowID = UInt32

/// Quando a viewport rola pra centralizar a coluna focada (mesmos nomes do niri).
public enum CenterMode: String {
    /// Sempre no centro, menos nas pontas da fita, que encostam na borda da tela.
    case always
    /// Rola o mínimo pra coluna caber inteira.
    case never
    /// Só centraliza quando precisa rolar; se já está inteira na tela, não mexe.
    case onOverflow = "on-overflow"
}

public struct LayoutConfig: Equatable {
    /// Espaço entre colunas (pt).
    public var gap: Double = 12
    /// Largura de janela nova, como fração da área útil.
    public var defaultProportion: Double = 0.5
    public var minProportion: Double = 0.1
    /// Rigidez da mola. 800 é o padrão do niri (~0,35 s pra assentar).
    public var stiffness: Double = 800
    /// Quantos pontos de uma janela fora da viewport ficam na borda da tela.
    /// O macOS puxa de volta pra 40 pt visíveis qualquer janela 100% fora da tela,
    /// então o mínimo que funciona é 1.
    public var sliver: Double = 1
    public var centerFocusedColumn: CenterMode = .always

    public init() {}
}

/// Uma janela da coluna. As de uma coluna ficam uma embaixo da outra, com `gap` entre elas.
public struct Tile {
    public let window: WindowID
    /// Parte da altura útil da coluna (a altura menos os gaps), relativa às outras da coluna.
    public internal(set) var share = 1.0
    /// Menor largura e altura que o app aceita (pt), descobertas quando ele recusa encolher. 0 = sem limite conhecido.
    public internal(set) var minWidth = 0.0
    public internal(set) var minHeight = 0.0
    /// Onde ficou solta da última vez (ver `Layout.float`), pra voltar pro mesmo lugar.
    public internal(set) var floatingFrame: CGRect?
    var height: Spring
    /// Deslocamento animado de onde a janela estava quando mudou de coluna ou de lugar na coluna (outra entrou ou saiu):
    /// ela continua no mesmo lugar e tamanho na tela e anda até o novo, como a coluna com o `offset`.
    var dx: Spring, dy: Spring, dw: Spring

    func isNear(at t: Double, within d: Double) -> Bool {
        height.isNear(at: t, within: d) && dx.isNear(at: t, within: d) && dy.isNear(at: t, within: d) && dw.isNear(at: t, within: d)
    }

    func isSettled(at t: Double) -> Bool {
        height.isSettled(at: t) && dx.isSettled(at: t) && dy.isSettled(at: t) && dw.isSettled(at: t)
    }

    mutating func snap() {
        height.snap()
        dx.snap()
        dy.snap()
        dw.snap()
    }
}

public struct Column {
    /// De cima pra baixo. Quase sempre uma só.
    public internal(set) var tiles: [Tile]
    /// A janela focada da coluna: a que ganha o foco quando a coluna é focada.
    public internal(set) var active = 0
    /// Largura alvo como fração da área útil (0.1 a 1.0).
    public internal(set) var proportion: Double
    /// Largura antes do Option+F, pra voltar no segundo toque.
    public internal(set) var savedProportion: Double?
    var width: Spring
    /// Deslocamento extra animado. Abrir ou fechar janela muda a posição das vizinhas no modelo
    /// na hora; esse deslocamento faz elas deslizarem até lá em vez de pular.
    var offset: Spring

    public var windows: [WindowID] { tiles.map(\.window) }
    /// Menor largura que os apps da coluna aceitam: a coluna não fica mais estreita que a janela que mais pede.
    public var minWidth: Double { tiles.map(\.minWidth).max() ?? 0 }
}

/// Janela solta da fita, por cima dela, como a camada flutuante do niri: é do workspace (sai com ele na troca e com a
/// mesa), mas não rola com a fita. A pessoa arrasta e redimensiona com o mouse. Sem o foco, vai pra gaveta (ver
/// `Layout.updateDrawer`).
public struct Floating {
    public let window: WindowID
    /// Onde fica na tela, sem a troca de workspace, a mesa e a gaveta.
    public internal(set) var frame: CGRect
    /// Fixada (Option Shift P): fica na tela mesmo com o foco na fita, fora da gaveta.
    public internal(set) var pinned = false
    /// Deslocamento animado de onde estava (a coluna de onde saiu), como o `dx`/`dy`/`dw` das janelas da coluna.
    var dx: Spring, dy: Spring, dw: Spring, dh: Spring
    /// Quanto já entrou na gaveta, em milésimos do caminho até a borda (0 = na tela), como a mesa.
    var out: Spring

    func rect(at t: Double) -> CGRect {
        CGRect(x: frame.minX + dx.value(at: t), y: frame.minY + dy.value(at: t),
               width: frame.width + dw.value(at: t), height: frame.height + dh.value(at: t))
    }

    var springs: [Spring] { [dx, dy, dw, dh, out] }

    mutating func update(_ f: (inout Spring) -> Void) {
        f(&dx); f(&dy); f(&dw); f(&dh); f(&out)
    }
}

public struct WindowFrame: Equatable {
    public let window: WindowID
    public let rect: CGRect
}

/// Fita horizontal de colunas (uma ou mais janelas empilhadas por coluna) e a viewport que rola sobre ela.
/// Uma por workspace (ver `Workspaces`).
///
/// Coordenadas: as do AX, origem no canto superior esquerdo da tela principal.
/// `x` de coluna é relativo ao início da fita; a tela mostra [view, view + area.width].
public struct Layout {
    public private(set) var columns: [Column] = []
    public private(set) var focusedIndex: Int?
    /// Área onde as janelas ficam (tela menos barra de menu, Dock e margens).
    public private(set) var area: CGRect
    /// Tela inteira. Usada pra estacionar janelas fora da viewport.
    public private(set) var bounds: CGRect
    public private(set) var config: LayoutConfig
    var view: Spring
    /// Mesa à mostra (Option+D): as janelas saíram pela borda mais próxima. Focar uma janela, abrir uma
    /// nova ou o próximo atalho trazem a fita de volta.
    public private(set) var showsDesktop = false
    /// Quanto a fita já saiu, em milésimos do caminho (0 = normal, 1000 = fora da tela): a precisão de
    /// meio ponto da mola vira meio milésimo.
    var desktop: Spring
    /// As colunas antes deste índice saem pela esquerda; as outras, pela direita.
    var desktopSplit = 0
    /// Deslocamento da fita inteira (pt), pra trocar de workspace (ver `Workspaces`): 0 na tela, ± a largura
    /// da tela fora dela.
    var shift: Spring
    /// As soltas, de trás pra frente: a última é a de cima (a focada por último).
    public private(set) var floating: [Floating] = []
    /// O foco está na solta de cima, e não na coluna focada (que continua guardada pra volta).
    public private(set) var floatingFocused = false

    public init(area: CGRect, bounds: CGRect, config: LayoutConfig) {
        self.area = area
        self.bounds = bounds
        self.config = config
        self.view = Spring(0, stiffness: config.stiffness)
        self.desktop = Spring(0, stiffness: config.stiffness)
        self.shift = Spring(0, stiffness: config.stiffness)
    }

    public var focusedWindow: WindowID? {
        floatingFocused ? floating.last?.window : stripFocus.map { columns[$0].tiles[columns[$0].active].window }
    }
    /// A janela focada da fita, mesmo com o foco numa solta: pra onde o foco volta.
    public var stripWindow: WindowID? { focusedIndex.map { columns[$0].tiles[columns[$0].active].window } }
    /// A coluna focada, se o foco está na fita (e não numa solta): só nela os atalhos de coluna fazem algo.
    private var stripFocus: Int? { floatingFocused ? nil : focusedIndex }
    /// As da fita e as soltas.
    public var windows: [WindowID] { columns.flatMap(\.windows) + floating.map(\.window) }
    public func contains(_ window: WindowID) -> Bool { index(of: window) != nil || isFloating(window) }
    public func isFloating(_ window: WindowID) -> Bool { floating.contains { $0.window == window } }
    /// A coluna da janela (nil se ela está solta).
    public func index(of window: WindowID) -> Int? { columns.firstIndex { $0.windows.contains(window) } }
    /// A coluna da janela e o lugar dela na coluna (0 = a de cima).
    func place(of window: WindowID) -> (column: Int, row: Int)? {
        index(of: window).map { ($0, columns[$0].windows.firstIndex(of: window)!) }
    }

    /// Largura em pontos de uma fração, contando os gaps: duas colunas de 0.5 cabem exatas na área.
    public func pixelWidth(_ proportion: Double) -> Double {
        proportion * (area.width + config.gap) - config.gap
    }

    /// Inverso de `pixelWidth`, arredondado pro passo mais próximo. Usado ao adotar janelas já abertas.
    public func proportion(forWidth w: Double, step: Double) -> Double {
        let p = (w + config.gap) / (area.width + config.gap)
        return clamp((p / step).rounded() * step)
    }

    private func clamp(_ p: Double) -> Double {
        min(1, max(config.minProportion, (p * 1000).rounded() / 1000))
    }

    private func spring(_ v: Double) -> Spring { Spring(v, stiffness: config.stiffness) }

    private func tile(_ window: WindowID) -> Tile {
        Tile(window: window, height: spring(area.height), dx: spring(0), dy: spring(0), dw: spring(0))
    }

    /// Altura alvo de cada janela da coluna: a parte dela da altura útil, mas nunca menos do que o app aceita (quem tem
    /// limite fica nele, e as outras dividem o resto na mesma proporção). Se nem os limites cabem, cada uma fica no dela e
    /// a de baixo passa do pé da tela: espremida, ela recusava e ficava por cima da outra (Discord 500 pt e WhatsApp
    /// 600 pt numa coluna de 1048, visto no uso em 2026-10-16), e a conferência mandava o tamanho de novo sem parar.
    func heights(_ c: Column) -> [Double] {
        let n = c.tiles.count, avail = area.height - Double(n - 1) * config.gap
        var fixed = Set<Int>()
        while true {
            let loose = c.tiles.indices.filter { !fixed.contains($0) }
            let free = avail - fixed.reduce(0) { $0 + c.tiles[$1].minHeight }
            let total = loose.reduce(0) { $0 + c.tiles[$1].share }
            let h = c.tiles.indices.map { fixed.contains($0) || total <= 0 ? c.tiles[$0].minHeight : free * c.tiles[$0].share / total }
            guard let i = loose.first(where: { h[$0] < c.tiles[$0].minHeight - 0.5 }) else { return h }
            fixed.insert(i)
        }
    }

    /// As alturas mínimas conhecidas dessas janelas cabem empilhadas numa coluna.
    func fits(_ tiles: [Tile]) -> Bool {
        tiles.reduce(0) { $0 + $1.minHeight } + Double(tiles.count - 1) * config.gap <= area.height
    }

    /// Largura que a coluna ocupa: a pedida, ou o limite do app se ele não encolhe tanto.
    func slotWidth(_ c: Column) -> Double { max(pixelWidth(c.proportion), c.minWidth).rounded() }

    // MARK: - Mudanças na fita

    /// Coloca uma janela no fim, sem animar. Só pra montar o estado inicial. `stacked`: embaixo das da última coluna.
    public mutating func append(_ window: WindowID, proportion: Double? = nil, savedProportion: Double? = nil,
                                minWidth: Double = 0, minHeight: Double = 0, share: Double = 1, stacked: Bool = false) {
        var t = tile(window)
        t.minWidth = minWidth >= area.width - 1 ? 0 : minWidth
        t.minHeight = minHeight >= area.height - 1 ? 0 : minHeight
        t.share = share > 0 ? share : 1
        if stacked, !columns.isEmpty {
            columns[columns.count - 1].tiles.append(t)
            return
        }
        var c = Column(tiles: [t], proportion: clamp(proportion ?? config.defaultProportion), savedProportion: savedProportion,
                       width: spring(0), offset: spring(0))
        c.width = spring(slotWidth(c))
        columns.append(c)
        if focusedIndex == nil { focusedIndex = 0 }
    }

    /// Janela nova entra à direita da focada, ou na coluna `position` (a que volta pro lugar de onde saiu).
    /// As vizinhas da direita deslizam; ninguém encolhe.
    public mutating func insert(_ window: WindowID, proportion: Double? = nil, position: Int? = nil, focus: Bool, at t: Double) {
        insert(Column(tiles: [tile(window)], proportion: clamp(proportion ?? config.defaultProportion), savedProportion: nil,
                      width: spring(0), offset: spring(0)), position: position, focus: focus, at: t)
    }

    /// Coluna entra à direita da focada (ou em `position`), com a largura dela (vinda de outro workspace ou
    /// voltando de tela cheia: mantém a largura, a mínima e a de antes do Option+F).
    public mutating func insert(_ column: Column, position: Int? = nil, focus: Bool, at t: Double) {
        guard column.windows.allSatisfy({ index(of: $0) == nil }) else { return }
        var c = column
        c.width = spring(slotWidth(c))
        c.offset = spring(0)
        for (r, h) in heights(c).enumerated() {
            c.tiles[r].height = spring(h)
            (c.tiles[r].dx, c.tiles[r].dy, c.tiles[r].dw) = (spring(0), spring(0), spring(0))
        }
        let k = min(position ?? focusedIndex.map { $0 + 1 } ?? columns.count, columns.count)
        showsDesktop = false  // janela nova aparece
        columns.insert(c, at: k)
        for i in (k + 1)..<columns.count {
            columns[i].offset.displace(by: -(c.width.target + config.gap), at: t)
        }
        if focus || focusedIndex == nil { focusedIndex = k } else if let f = focusedIndex, k <= f { focusedIndex = f + 1 }
        if focus { floatingFocused = false }
        retarget(at: t)
    }

    /// Tira a janela. Se era a focada, o foco vai pra vizinha da direita (ou da esquerda, se era a última). Numa coluna
    /// com outras, só ela sai: o foco vai pra de baixo (ou a de cima) e as outras crescem. Devolve uma coluna só com ela,
    /// com a largura da de onde saiu. Solta, só sai (nil); se era a focada, o foco vai pra solta de baixo, ou pra fita.
    @discardableResult
    public mutating func remove(_ window: WindowID, at t: Double) -> Column? {
        if let i = floating.firstIndex(where: { $0.window == window }) {
            floating.remove(at: i)
            if floating.isEmpty { floatingFocused = false }
            return nil
        }
        guard let (k, r) = place(of: window) else { return nil }
        guard columns[k].tiles.count > 1 else {
            defer { if columns.isEmpty && !floating.isEmpty { floatingFocused = true } }  // a fita esvaziou: o foco vai pra solta
            return removeColumn(k, at: t)
        }
        let before = placements(at: t)
        let tile = columns[k].tiles.remove(at: r)
        if r < columns[k].active || columns[k].active == columns[k].tiles.count { columns[k].active -= 1 }
        retarget(at: t)
        restore(before.filter { columns[k].windows.contains($0.key) }, at: t)
        var single = columns[k]
        single.tiles = [tile]
        single.tiles[0].share = 1
        single.active = 0
        return single
    }

    private mutating func removeColumn(_ k: Int, at t: Double) -> Column {
        let removed = columns[k]
        let freed = columns[k].width.value(at: t) + config.gap
        columns.remove(at: k)
        if k < desktopSplit { desktopSplit -= 1 }
        guard let f = focusedIndex else { return removed }
        if columns.isEmpty {
            focusedIndex = nil
        } else if k < f {
            // Fechou algo à esquerda: a viewport acompanha pra nada visível pular.
            focusedIndex = f - 1
            view.shift(by: -freed)
            for i in 0..<k { columns[i].offset.displace(by: -freed, at: t) }
        } else {
            for i in k..<columns.count { columns[i].offset.displace(by: freed, at: t) }
            if k == f { focusedIndex = min(k, columns.count - 1) }
        }
        retarget(at: t)
        return removed
    }

    /// A janela volta pra coluna de `sibling`, de onde saiu sem fechar (minimizada, escondida no X): logo embaixo dela
    /// ou, com `above`, logo em cima. As da coluna dividem a altura por igual. false se `sibling` não está na fita.
    /// Se as alturas mínimas não cabem juntas, também false (ela volta numa coluna própria).
    public mutating func stack(_ column: Column, with sibling: WindowID, above: Bool, focus: Bool, at t: Double) -> Bool {
        guard let (k, r) = place(of: sibling), let tile = column.tiles.first, index(of: tile.window) == nil,
              fits(columns[k].tiles + [tile]) else { return false }
        let before = placements(at: t).filter { columns[k].windows.contains($0.key) }, row = above ? r : r + 1
        let active = columns[k].active
        join(tile, into: k, row: row)
        if focus { (focusedIndex, floatingFocused) = (k, false) } else { columns[k].active = active < row ? active : active + 1 }
        showsDesktop = false  // janela aparece
        retarget(at: t)
        columns[k].tiles[row].height.snap()  // ela aparece já no lugar; as outras saem de onde estão
        restore(before, at: t)
        return true
    }

    /// Põe a janela na coluna `k`, como a ativa dela, e divide a altura por igual.
    private mutating func join(_ tile: Tile, into k: Int, row: Int) {
        var t = tile
        (t.dx, t.dy, t.dw) = (spring(0), spring(0), spring(0))
        columns[k].tiles.insert(t, at: row)
        for i in columns[k].tiles.indices { columns[k].tiles[i].share = 1 }
        columns[k].active = row
    }

    /// Option+Cmd+, .: a focada, sozinha na coluna, entra na vizinha (`delta` -1 esquerda, 1 direita): embaixo das janelas
    /// da esquerda ou em cima das da direita, como o `consume-or-expel-window-left/right` do niri, e a altura fica
    /// dividida por igual. A coluna fica com a largura das duas somadas (duas de 1/2 lado a lado viram uma da tela toda,
    /// partida no meio); no niri ela fica com a da coluna de destino, e a pilha aparecia estreita no meio da tela. Numa
    /// coluna com outras, ela sai pra uma coluna só dela daquele lado, e as duas ficam com metade da largura. O foco fica
    /// nela. Sozinha na ponta, ou se as alturas mínimas dos apps não cabem juntas, nada muda.
    @discardableResult
    public mutating func consumeOrExpel(_ delta: Int, at t: Double) -> Bool {
        guard let f = stripFocus, abs(delta) == 1 else { return false }
        let before = placements(at: t), mates = columns[f].windows
        if columns[f].tiles.count == 1 {
            guard columns.indices.contains(f + delta), fits(columns[f + delta].tiles + columns[f].tiles) else { return false }
            let moving = Set(columns[f + delta].windows + mates), width = columns[f].proportion + columns[f + delta].proportion
            let tile = removeColumn(f, at: t).tiles[0]
            let k = delta < 0 ? f - 1 : f
            join(tile, into: k, row: delta < 0 ? columns[k].tiles.count : 0)
            columns[k].proportion = clamp(width)
            columns[k].savedProportion = nil
            focusedIndex = k
            retarget(at: t)
            restore(before.filter { moving.contains($0.key) }, at: t)
            // Primeiro a altura, cada uma ainda na coluna dela; depois as duas alargam, uma em cima e a outra embaixo.
            postpone(horizontal: true, of: moving, at: t)
        } else {
            var c = columns[f]
            let tile = c.tiles.remove(at: c.active)
            c.active = min(c.active, c.tiles.count - 1)
            c.proportion = clamp(c.proportion / 2)  // com o gap: duas de p/2 ocupam exatamente o espaço de uma de p
            c.savedProportion = nil
            columns[f] = c
            c.tiles = [tile]
            c.tiles[0].share = 1
            c.active = 0
            insert(c, position: delta < 0 ? f : f + 1, focus: true, at: t)
            restore(before.filter { mates.contains($0.key) }, at: t)
            // Primeiro a largura, cada uma ainda na sua altura; depois as duas crescem até o pé, lado a lado.
            postpone(horizontal: false, of: Set(mates), at: t)
        }
        return true
    }

    /// Juntar e separar em duas fases, pra nenhuma janela passar por cima da outra: animando tudo junto, a que entra na
    /// coluna atravessava a outra no caminho (visto no uso em 2026-10-16). A segunda fase (`horizontal`: a largura e a
    /// rolagem; senão a altura) espera a primeira chegar a 0,7% do caminho, quando as janelas já não se cruzam: 7/ω,
    /// 0,25 s com a mola padrão.
    private mutating func postpone(horizontal: Bool, of windows: Set<WindowID>, at t: Double) {
        let t1 = t + 7 / config.stiffness.squareRoot()
        if horizontal {
            view.postpone(from: t, to: t1)
            for k in columns.indices {
                columns[k].offset.postpone(from: t, to: t1)
                columns[k].width.postpone(from: t, to: t1)
            }
        }
        for k in columns.indices {
            for r in columns[k].tiles.indices where windows.contains(columns[k].tiles[r].window) {
                if horizontal {
                    columns[k].tiles[r].dx.postpone(from: t, to: t1)
                    columns[k].tiles[r].dw.postpone(from: t, to: t1)
                } else {
                    columns[k].tiles[r].height.postpone(from: t, to: t1)
                    columns[k].tiles[r].dy.postpone(from: t, to: t1)
                }
            }
        }
    }

    /// Com a mesa à mostra, focar uma janela (Cmd+Tab, Dock) traz a fita de volta, mesmo sendo a focada. Solta: vai pra
    /// cima das outras soltas, e a fita não rola.
    public mutating func focus(_ window: WindowID, at t: Double) {
        if let i = floating.firstIndex(where: { $0.window == window }) {
            floating.append(floating.remove(at: i))
            floatingFocused = true
            showsDesktop = false
            return retarget(at: t)
        }
        guard let (k, r) = place(of: window), k != focusedIndex || r != columns[k].active || showsDesktop || floatingFocused else { return }
        floatingFocused = false
        focusedIndex = k
        columns[k].active = r
        showsDesktop = false
        retarget(at: t)
    }

    /// Option ↑ ↓: foco na janela de cima (-1) ou de baixo (1) da coluna. Devolve a janela, ou nil se já está na ponta.
    public mutating func focusInColumn(_ delta: Int) -> WindowID? {
        guard let f = stripFocus, columns[f].tiles.indices.contains(columns[f].active + delta) else { return nil }
        columns[f].active += delta
        return columns[f].tiles[columns[f].active].window
    }

    /// Move o foco `delta` colunas. Devolve a janela que deve receber foco, ou nil se já está na ponta. Com o foco numa
    /// solta, volta pra coluna focada da fita, sem rolar.
    public mutating func focusNeighbor(_ delta: Int, at t: Double) -> WindowID? {
        guard let f = focusedIndex else { return nil }
        if floatingFocused {
            floatingFocused = false
            return focusedWindow
        }
        let n = max(0, min(columns.count - 1, f + delta))
        guard n != f else { return nil }
        focusedIndex = n
        retarget(at: t)
        return focusedWindow
    }

    /// Troca a coluna focada de lugar com a vizinha (`delta` -1 esquerda, 1 direita), como o `move-column-left/right`
    /// do niri. As duas saem de onde estão na tela e deslizam pro lugar novo; o foco fica nela. Na ponta, nada muda.
    @discardableResult
    public mutating func moveFocusedColumn(_ delta: Int, at t: Double) -> Bool {
        guard let f = stripFocus, abs(delta) == 1, columns.indices.contains(f + delta) else { return false }
        let n = f + delta, d = Double(delta)
        // O espaço que cada uma ocupa agora (a largura como em `positions`): é o quanto a outra anda.
        let moved = columns[f].width.value(at: t).rounded() + config.gap
        let other = columns[n].width.value(at: t).rounded() + config.gap
        columns.swapAt(f, n)
        columns[n].offset.displace(by: -d * other, at: t)
        columns[f].offset.displace(by: d * moved, at: t)
        focusedIndex = n
        retarget(at: t)
        return true
    }

    public mutating func resizeFocused(by delta: Double, at t: Double) {
        guard let f = stripFocus else { return }
        var p = clamp(columns[f].proportion + delta)
        // Não encolhe além do que o app aceita: no limite, Option- não faz nada.
        if delta < 0, columns[f].minWidth > 0 {
            let limit = (columns[f].minWidth + config.gap) / (area.width + config.gap)
            p = max(p, min(1, (limit * 1000).rounded(.up) / 1000))
        }
        columns[f].savedProportion = nil
        columns[f].proportion = p
        retarget(at: t)
    }

    /// Pula pra próxima largura da lista, como o `switch-preset-column-width` do niri: passos maiores e
    /// fixos (1/3, 1/2, 2/3, 1) em vez de ±10%. `direction` +1 cresce, -1 encolhe. Na ponta, nada muda.
    public mutating func resizeFocused(toPresetIn presets: [Double], direction: Int, at t: Double) {
        guard let f = stripFocus else { return }
        let p = columns[f].proportion, eps = 0.01
        let target = direction > 0 ? presets.sorted().first { $0 > p + eps } : presets.sorted().last { $0 < p - eps }
        guard let target else { return }
        resizeFocused(by: target - p, at: t)
    }

    /// Option+Cmd +/-: altura da focada numa coluna com outras, pulando entre as frações da lista (1/3, 1/2, 2/3), como a
    /// largura. As outras dividem o resto na proporção que já tinham. Não passa do que os apps aceitam (a altura mínima
    /// aprendida). false se nada mudou (sozinha na coluna, ou na ponta da lista).
    @discardableResult
    public mutating func resizeFocusedHeight(toPresetIn presets: [Double], direction: Int, at t: Double) -> Bool {
        guard let f = stripFocus, columns[f].tiles.count > 1 else { return false }
        let c = columns[f], i = c.active, h = heights(c), avail = h.reduce(0, +), p = h[i] / avail, eps = 0.01
        let rest = c.tiles.indices.filter { $0 != i }
        guard var q = direction > 0 ? presets.sorted().first(where: { $0 > p + eps }) : presets.sorted().last(where: { $0 < p - eps })
        else { return false }
        q = min(max(q, c.tiles[i].minHeight / avail), 1 - rest.reduce(0) { $0 + c.tiles[$1].minHeight } / avail)
        guard q > 0, q < 1, (q - p) * Double(direction) > 0.001 else { return false }
        let others = rest.reduce(0) { $0 + h[$1] }
        for j in rest { columns[f].tiles[j].share = (1 - q) * h[j] / others }
        columns[f].tiles[i].share = q
        retarget(at: t)
        return true
    }

    /// O app recusou ficar mais estreito que `width`.
    /// Da largura da área útil ou mais não é crível: é leitura feita antes de um app assíncrono (Arc,
    /// Electron, WhatsApp) aplicar o tamanho. Aceitar travaria a coluna na tela toda (visto no uso: 1704 pt
    /// no Arc, no Discord e no WhatsApp).
    /// true se o limite mudou.
    @discardableResult
    public mutating func setMinWidth(_ window: WindowID, _ width: Double, at t: Double) -> Bool {
        guard let (k, r) = place(of: window), width > columns[k].tiles[r].minWidth + 1, width < area.width - 1 else { return false }
        columns[k].tiles[r].minWidth = width
        retarget(at: t)
        return true
    }

    /// O app recusou ficar mais baixo que `height` (numa coluna com outras). Da altura da área ou mais é leitura feita
    /// antes de o app aplicar o tamanho, como na largura.
    @discardableResult
    public mutating func setMinHeight(_ window: WindowID, _ height: Double, at t: Double) -> Bool {
        guard let (k, r) = place(of: window), height > columns[k].tiles[r].minHeight + 1, height < area.height - 1 else { return false }
        columns[k].tiles[r].minHeight = height
        retarget(at: t)
        return true
    }

    /// Option+F: coluna ocupa a área toda; segundo toque volta pra largura anterior.
    public mutating func toggleFullWidthFocused(at t: Double) {
        guard let f = stripFocus else { return }
        if let saved = columns[f].savedProportion {
            columns[f].proportion = saved
            columns[f].savedProportion = nil
        } else {
            columns[f].savedProportion = columns[f].proportion
            columns[f].proportion = 1
        }
        retarget(at: t)
    }

    // MARK: - Soltas

    /// Janela solta entra no workspace (diálogo, regra `floating`, estado salvo, voltando de minimizada), sem animar, onde
    /// está. Saindo da tela, ela entra pra área útil (do tamanho dela, no máximo).
    public mutating func addFloating(_ window: WindowID, frame: CGRect, focus: Bool, pinned: Bool = false) {
        guard !contains(window) else { return }
        let w = min(frame.width, area.width), h = min(frame.height, area.height)
        let r = bounds.contains(frame) ? frame : CGRect(x: min(max(frame.minX, area.minX), area.maxX - w),
                                                      y: min(max(frame.minY, area.minY), area.maxY - h), width: w, height: h)
        floating.append(Floating(window: window, frame: r.integral, pinned: pinned, dx: spring(0), dy: spring(0), dw: spring(0),
                                 dh: spring(0), out: spring(0)))
        if focus || columns.isEmpty { floatingFocused = true }  // sem coluna, a solta é a focada do workspace
        if focus { showsDesktop = false }
    }

    /// Option Shift F na fita: a janela sai da coluna (as vizinhas fecham o buraco) e fica solta por cima da fita, onde
    /// estava solta da última vez ou, na 1ª vez, no meio do lugar dela, com no máximo 2/3 da área em cada direção (do
    /// tamanho da coluna ela cobriria a fita). Anda de onde estava, e o foco vai com ela.
    @discardableResult
    public mutating func float(_ window: WindowID, at t: Double) -> Bool {
        guard let (k, r) = place(of: window), let from = placements(at: t)[window] else { return false }
        let saved = columns[k].tiles[r].floatingFrame
        remove(window, at: t)
        let w = min(from.width, (area.width * 2 / 3).rounded()), h = min(from.height, (area.height * 2 / 3).rounded())
        addFloating(window, frame: saved ?? CGRect(x: (from.midX - w / 2).rounded(), y: (from.midY - h / 2).rounded(), width: w, height: h),
                    focus: true)
        let f = floating[floating.count - 1].frame
        floating[floating.count - 1].dx.displace(by: from.minX - f.minX, at: t)
        floating[floating.count - 1].dy.displace(by: from.minY - f.minY, at: t)
        floating[floating.count - 1].dw.displace(by: from.width - f.width, at: t)
        floating[floating.count - 1].dh.displace(by: from.height - f.height, at: t)
        retarget(at: t)
        return true
    }

    /// Option Shift F na solta: volta pra fita numa coluna nova à direita da focada, como no niri, com a largura
    /// `proportion`, e anda de onde estava. O foco vai com ela. O lugar de solta fica guardado pra próxima vez.
    @discardableResult
    public mutating func embed(_ window: WindowID, proportion: Double, at t: Double) -> Bool {
        guard let i = floating.firstIndex(where: { $0.window == window }) else { return false }
        let f = floating.remove(at: i), from = f.rect(at: t)
        var c = Column(tiles: [tile(window)], proportion: clamp(proportion), savedProportion: nil, width: spring(0), offset: spring(0))
        c.tiles[0].floatingFrame = f.frame
        insert(c, focus: true, at: t)
        restore([window: from], at: t)
        return true
    }

    /// A pessoa arrastou ou redimensionou a solta (ou o app mudou ela): o lugar novo vale, sem animar.
    public mutating func setFloatingFrame(_ window: WindowID, _ frame: CGRect) {
        guard let i = floating.firstIndex(where: { $0.window == window }) else { return }
        floating[i].frame = frame
        floating[i].update { $0.snap() }
    }

    /// Option Shift P: a solta fica sempre na tela, fora da gaveta, ou volta pra ela. Devolve se ficou fixada (nil se a
    /// janela não está solta).
    public mutating func togglePinned(_ window: WindowID) -> Bool? {
        guard let i = floating.firstIndex(where: { $0.window == window }) else { return nil }
        floating[i].pinned.toggle()
        return floating[i].pinned
    }

    /// A gaveta: a solta sai da tela pela borda mais perto do meio dela (como na mesa) e estaciona com 1 pt, pra não ficar
    /// no meio das janelas da fita, por trás da focada (o macOS não deixa pôr janela de outro app embaixo das outras; ver
    /// docs/NOTES.md). Ficam na tela: a fixada e as do mesmo app da focada (`sameApp`: o seletor de cores não some ao
    /// clicar no desenho).
    public mutating func updateDrawer(at t: Double, sameApp: (WindowID, WindowID) -> Bool) {
        let f = focusedWindow
        for i in floating.indices {
            let shown = floating[i].pinned || f.map { sameApp($0, floating[i].window) } ?? true
            floating[i].out.retarget(shown ? 0 : 1000, at: t)
        }
    }

    /// Mostra a mesa ou traz a fita de volta. Sai pela esquerda quem tem o meio à esquerda do meio da tela.
    public mutating func setDesktop(_ on: Bool, at t: Double) {
        // Voltando no meio do caminho, os lados continuam os mesmos.
        if on && !showsDesktop && desktop.value(at: t) < 1 {
            desktopSplit = positions(at: t).prefix { $0.x + $0.w / 2 < bounds.midX }.count
        }
        showsDesktop = on
        retarget(at: t)
    }

    /// A viewport acompanha o deslocamento da área: nada pula, e as janelas deslizam pro lugar novo.
    public mutating func setArea(_ area: CGRect, bounds: CGRect, at t: Double) {
        view.shift(by: area.minX - self.area.minX)
        self.area = area
        self.bounds = bounds
        retarget(at: t)
    }

    /// Config nova (recarregada do arquivo). As janelas saem de onde estão e deslizam pro layout novo:
    /// as molas são refeitas com a rigidez nova a partir do valor atual, e a diferença de gap vira
    /// deslocamento animado.
    public mutating func setConfig(_ c: LayoutConfig, at t: Double) {
        func respring(_ s: Spring) -> Spring {
            var n = Spring(s.value(at: t), stiffness: c.stiffness)
            n.retarget(s.target, at: t)
            return n
        }
        if c.stiffness != config.stiffness {
            view = respring(view)
            desktop = respring(desktop)
            shift = respring(shift)
            for i in columns.indices {
                columns[i].width = respring(columns[i].width)
                columns[i].offset = respring(columns[i].offset)
                for r in columns[i].tiles.indices {
                    columns[i].tiles[r].height = respring(columns[i].tiles[r].height)
                    columns[i].tiles[r].dx = respring(columns[i].tiles[r].dx)
                    columns[i].tiles[r].dy = respring(columns[i].tiles[r].dy)
                    columns[i].tiles[r].dw = respring(columns[i].tiles[r].dw)
                }
            }
            for i in floating.indices { floating[i].update { $0 = respring($0) } }
        }
        for i in columns.indices {
            columns[i].offset.displace(by: Double(i) * (config.gap - c.gap), at: t)
            for r in columns[i].tiles.indices { columns[i].tiles[r].dy.displace(by: Double(r) * (config.gap - c.gap), at: t) }
        }
        config = c
        retarget(at: t)
    }

    // MARK: - Alvos e frames

    /// Recalcula larguras e alturas alvo e a rolagem alvo.
    /// Regra de rolagem (a padrão do niri): mexe o mínimo pra coluna focada ficar inteira na tela.
    public mutating func retarget(at t: Double) {
        desktop.retarget(showsDesktop ? 1000 : 0, at: t)
        for i in columns.indices {
            columns[i].width.retarget(slotWidth(columns[i]), at: t)
            for (r, h) in heights(columns[i]).enumerated() { columns[i].tiles[r].height.retarget(h, at: t) }
        }
        guard let f = focusedIndex else {
            view.retarget(0, at: t)
            return
        }
        var x = 0.0
        var colX = 0.0
        for (i, c) in columns.enumerated() {
            if i == f { colX = x }
            x += c.width.target.rounded() + config.gap
        }
        let total = x - config.gap
        let colW = columns[f].width.target.rounded()
        let viewW = area.width
        let centered = colW >= viewW ? colX : colX - (viewW - colW) / 2
        var v = view.target
        let fits = colX >= v && colX + colW <= v + viewW
        switch config.centerFocusedColumn {
        case .always:
            v = centered
        case .onOverflow:
            if !fits { v = centered }
        case .never:
            if colW >= viewW || colX < v {
                v = colX
            } else if colX + colW > v + viewW {
                v = colX + colW - viewW
            }
        }
        // Sem espaço vazio nas pontas da fita: centralizar a 1ª ou a última coluna deixaria papel de
        // parede do lado. Se a fita inteira cabe na tela, ela fica no centro (no `never`, à esquerda).
        if total > viewW {
            v = max(0, min(v, total - viewW))
        } else {
            v = config.centerFocusedColumn == .never ? 0 : (total - viewW) / 2
        }
        view.retarget(v.rounded(), at: t)
    }

    /// Posição na tela (antes de estacionar na borda e sem o deslocamento do workspace) e largura de cada coluna.
    func positions(at t: Double) -> [(x: Double, w: Double)] {
        let v = view.value(at: t)
        var x = 0.0
        return columns.map { c in
            // Largura inteira e posição acumulada a partir dela: o espaço entre colunas fica
            // sempre exatamente `gap`, e rolar a fita não muda a largura (não dispara resize).
            let w = c.width.value(at: t).rounded()
            defer { x += w + config.gap }
            return (area.minX + x + c.offset.value(at: t) - v, w)
        }
    }

    /// Retângulo de cada janela da coluna em `x`, com largura `w`, antes de estacionar na borda e sem arredondar. A altura
    /// acumula de cima pra baixo: arredondando só no fim, o espaço entre janelas da coluna fica sempre exatamente `gap`.
    private func rects(_ c: Column, x: Double, w: Double, at t: Double) -> [CGRect] {
        var y = area.minY
        return c.tiles.map { tile in
            let h = tile.height.value(at: t)
            defer { y += h + config.gap }
            return CGRect(x: x + tile.dx.value(at: t), y: y + tile.dy.value(at: t), width: w + tile.dw.value(at: t), height: h)
        }
    }

    /// Onde cada janela está agora, antes de estacionar na borda e sem a mesa e o workspace.
    private func placements(at t: Double) -> [WindowID: CGRect] {
        var out: [WindowID: CGRect] = [:]
        for (c, (x, w)) in zip(columns, positions(at: t)) {
            for (tile, r) in zip(c.tiles, rects(c, x: x, w: w, at: t)) { out[tile.window] = r }
        }
        return out
    }

    /// Depois de mudar a coluna das janelas de `before` (uma entrou, saiu ou mudou de altura): cada uma continua onde
    /// estava na tela e anda até o lugar novo com a mola. A altura vai antes, porque o lugar de cada uma depende da altura
    /// das de cima.
    private mutating func restore(_ before: [WindowID: CGRect], at t: Double) {
        for k in columns.indices {
            for r in columns[k].tiles.indices {
                guard let b = before[columns[k].tiles[r].window] else { continue }
                columns[k].tiles[r].height.displace(by: b.height - columns[k].tiles[r].height.value(at: t), at: t)
            }
        }
        let now = placements(at: t)
        for k in columns.indices {
            for r in columns[k].tiles.indices {
                let id = columns[k].tiles[r].window
                guard let b = before[id], let n = now[id] else { continue }
                columns[k].tiles[r].dx.displace(by: b.minX - n.minX, at: t)
                columns[k].tiles[r].dy.displace(by: b.minY - n.minY, at: t)
                columns[k].tiles[r].dw.displace(by: b.width - n.width, at: t)
            }
        }
    }

    public func frames(at t: Double) -> [WindowFrame] {
        let xs = positions(at: t)
        // Mesa: cada lado sai inteiro, junto (o gap entre vizinhas do mesmo lado continua exato), até a
        // janela dele mais perto do meio encostar na borda com `sliver` pt.
        let p = min(1, max(0, desktop.value(at: t) / 1000)), k = min(desktopSplit, xs.count)
        let left = k > 0 ? p * max(0, xs[k - 1].x + xs[k - 1].w - bounds.minX - config.sliver) : 0
        let right = k < xs.count ? p * max(0, bounds.maxX - config.sliver - xs[k].x) : 0
        let s = shift.value(at: t)
        // Fita parada fora da tela (outro workspace): tudo estacionado, mesmo que ela tenha mudado depois de sair
        // (janela nova, largura nova) e o deslocamento da troca já não baste pra tirar tudo da tela.
        let away = shift.target != 0 && shift.isSettled(at: t)
        var out: [WindowFrame] = []
        for (i, (c, (x, w))) in zip(columns, xs).enumerated() {
            for (tile, r) in zip(c.tiles, rects(c, x: x, w: w, at: t)) {
                let w = r.width.rounded()
                // Fora da viewport: encosta na borda da tela com `sliver` pt visíveis.
                // Como é um clamp, a janela sai da borda de forma contínua quando a fita rola.
                let lo = bounds.minX - w + config.sliver, hi = bounds.maxX - config.sliver
                var sx = min(max(r.minX + (i < k ? -left : right), lo), hi)
                // Workspace entrando ou saindo: desliza junto toda coluna que aparece na tela, mesmo só em parte (a
                // distância da troca tira ela inteira; ver `Workspaces.switchTo`). A que está fora da viewport fica
                // estacionada: deslocada junto, ela entraria na tela (a 2ª coluna do workspace saindo pela esquerda
                // caía em x = 0, atrás da janela focada; visto no uso em 2026-10-16).
                if away {
                    sx = shift.target < 0 ? lo : hi
                } else if s != 0 && sx > lo && sx < hi {
                    sx = min(max(sx + s, lo), hi)
                }
                let y = r.minY.rounded()
                out.append(WindowFrame(window: tile.window, rect: CGRect(x: sx.rounded(), y: y, width: w, height: r.maxY.rounded() - y)))
            }
        }
        // As soltas não rolam com a fita. Com a mesa ou na gaveta, cada uma sai inteira pela borda mais perto do meio dela;
        // na troca de workspace, andam junto e estacionam como as colunas.
        for f in floating {
            let r = f.rect(at: t), w = r.width.rounded(), q = max(p, min(1, max(0, f.out.value(at: t) / 1000)))
            let lo = bounds.minX - w + config.sliver, hi = bounds.maxX - config.sliver
            let gone = r.midX < bounds.midX ? -q * max(0, r.maxX - bounds.minX - config.sliver) : q * max(0, bounds.maxX - config.sliver - r.minX)
            var sx = min(max(r.minX + gone, lo), hi)
            if away {
                sx = shift.target < 0 ? lo : hi
            } else if s != 0 && sx > lo && sx < hi {
                sx = min(max(sx + s, lo), hi)
            }
            let y = r.minY.rounded()
            out.append(WindowFrame(window: f.window, rect: CGRect(x: sx.rounded(), y: y, width: w, height: r.maxY.rounded() - y)))
        }
        return out
    }

    /// Quanto a fita precisa andar pro lado `side` (-1 esquerda, 1 direita) pra tirar da tela tudo que aparece
    /// nela: até uma tela, ou mais se uma coluna passa da borda (o WhatsApp de largura total ao lado do Discord
    /// de 2/3). 0 se nada aparece.
    func reach(_ side: Double, at t: Double) -> Double {
        var l = self
        l.shift = spring(0)
        let shown = l.frames(at: t).map(\.rect).filter { $0.maxX > bounds.minX + config.sliver && $0.minX < bounds.maxX - config.sliver }
        guard let lo = shown.map(\.minX).min(), let hi = shown.map(\.maxX).max() else { return 0 }
        return side < 0 ? hi - bounds.minX : bounds.maxX - lo
    }

    /// Todas as molas a menos de `d` do fim (pt; a da mesa, em milésimos do caminho).
    public func isNear(at t: Double, within d: Double) -> Bool {
        view.isNear(at: t, within: d) && desktop.isNear(at: t, within: d) && shift.isNear(at: t, within: d)
            && columns.allSatisfy { $0.width.isNear(at: t, within: d) && $0.offset.isNear(at: t, within: d)
                && $0.tiles.allSatisfy { $0.isNear(at: t, within: d) } }
            && floating.allSatisfy { $0.springs.allSatisfy { $0.isNear(at: t, within: d) } }
    }

    public func isSettled(at t: Double) -> Bool {
        view.isSettled(at: t) && desktop.isSettled(at: t) && shift.isSettled(at: t)
            && columns.allSatisfy { $0.width.isSettled(at: t) && $0.offset.isSettled(at: t)
                && $0.tiles.allSatisfy { $0.isSettled(at: t) } }
            && floating.allSatisfy { $0.springs.allSatisfy { $0.isSettled(at: t) } }
    }

    public mutating func snapToTargets() {
        view.snap()
        desktop.snap()
        shift.snap()
        for i in columns.indices {
            columns[i].width.snap()
            columns[i].offset.snap()
            for r in columns[i].tiles.indices { columns[i].tiles[r].snap() }
        }
        for i in floating.indices { floating[i].update { $0.snap() } }
    }
}
