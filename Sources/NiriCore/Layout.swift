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

public struct Column {
    public let window: WindowID
    /// Largura alvo como fração da área útil (0.1 a 1.0).
    public internal(set) var proportion: Double
    /// Largura antes do Option+F, pra voltar no segundo toque.
    public internal(set) var savedProportion: Double?
    /// Menor largura que o app aceita (pt), descoberta quando ele recusa encolher. 0 = sem limite conhecido.
    public internal(set) var minWidth: Double = 0
    var width: Spring
    /// Deslocamento extra animado. Abrir ou fechar janela muda a posição das vizinhas no modelo
    /// na hora; esse deslocamento faz elas deslizarem até lá em vez de pular.
    var offset: Spring
}

public struct WindowFrame: Equatable {
    public let window: WindowID
    public let rect: CGRect
}

/// Fita horizontal de colunas (uma janela por coluna, por enquanto) e a viewport que rola sobre ela.
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

    public init(area: CGRect, bounds: CGRect, config: LayoutConfig) {
        self.area = area
        self.bounds = bounds
        self.config = config
        self.view = Spring(0, stiffness: config.stiffness)
        self.desktop = Spring(0, stiffness: config.stiffness)
        self.shift = Spring(0, stiffness: config.stiffness)
    }

    public var focusedWindow: WindowID? { focusedIndex.map { columns[$0].window } }
    public var windows: [WindowID] { columns.map(\.window) }
    public func index(of window: WindowID) -> Int? { columns.firstIndex { $0.window == window } }

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

    /// Largura que a coluna ocupa: a pedida, ou o limite do app se ele não encolhe tanto.
    func slotWidth(_ c: Column) -> Double { max(pixelWidth(c.proportion), c.minWidth).rounded() }

    // MARK: - Mudanças na fita

    /// Coloca uma janela no fim, sem animar. Só pra montar o estado inicial.
    public mutating func append(_ window: WindowID, proportion: Double? = nil,
                                savedProportion: Double? = nil, minWidth: Double = 0) {
        let p = clamp(proportion ?? config.defaultProportion)
        var c = Column(window: window, proportion: p, savedProportion: savedProportion,
                       width: spring(0), offset: spring(0))
        c.minWidth = minWidth >= area.width - 1 ? 0 : minWidth
        c.width = spring(slotWidth(c))
        columns.append(c)
        if focusedIndex == nil { focusedIndex = 0 }
    }

    /// Janela nova entra à direita da focada, ou na coluna `position` (a que volta pro lugar de onde saiu).
    /// As vizinhas da direita deslizam; ninguém encolhe.
    public mutating func insert(_ window: WindowID, proportion: Double? = nil, position: Int? = nil, focus: Bool, at t: Double) {
        insert(Column(window: window, proportion: clamp(proportion ?? config.defaultProportion), savedProportion: nil,
                      width: spring(0), offset: spring(0)), position: position, focus: focus, at: t)
    }

    /// Coluna entra à direita da focada (ou em `position`), com a largura dela (vinda de outro workspace ou
    /// voltando de tela cheia: mantém a largura, a mínima e a de antes do Option+F).
    public mutating func insert(_ column: Column, position: Int? = nil, focus: Bool, at t: Double) {
        guard index(of: column.window) == nil else { return }
        var c = column
        c.width = spring(slotWidth(c))
        c.offset = spring(0)
        let k = min(position ?? focusedIndex.map { $0 + 1 } ?? columns.count, columns.count)
        showsDesktop = false  // janela nova aparece
        columns.insert(c, at: k)
        for i in (k + 1)..<columns.count {
            columns[i].offset.displace(by: -(c.width.target + config.gap), at: t)
        }
        if focus || focusedIndex == nil { focusedIndex = k } else if let f = focusedIndex, k <= f { focusedIndex = f + 1 }
        retarget(at: t)
    }

    /// Tira a janela. Se era a focada, o foco vai pra vizinha da direita (ou da esquerda, se era a última).
    @discardableResult
    public mutating func remove(_ window: WindowID, at t: Double) -> Column? {
        guard let k = index(of: window) else { return nil }
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

    /// Com a mesa à mostra, focar uma janela (Cmd+Tab, Dock) traz a fita de volta, mesmo sendo a focada.
    public mutating func focus(_ window: WindowID, at t: Double) {
        guard let k = index(of: window), k != focusedIndex || showsDesktop else { return }
        focusedIndex = k
        showsDesktop = false
        retarget(at: t)
    }

    /// Move o foco `delta` colunas. Devolve a janela que deve receber foco, ou nil se já está na ponta.
    public mutating func focusNeighbor(_ delta: Int, at t: Double) -> WindowID? {
        guard let f = focusedIndex else { return nil }
        let n = max(0, min(columns.count - 1, f + delta))
        guard n != f else { return nil }
        focusedIndex = n
        retarget(at: t)
        return columns[n].window
    }

    public mutating func resizeFocused(by delta: Double, at t: Double) {
        guard let f = focusedIndex else { return }
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
        guard let f = focusedIndex else { return }
        let p = columns[f].proportion, eps = 0.01
        let target = direction > 0 ? presets.sorted().first { $0 > p + eps } : presets.sorted().last { $0 < p - eps }
        guard let target else { return }
        resizeFocused(by: target - p, at: t)
    }

    /// O app recusou ficar mais estreito que `width`.
    /// Da largura da área útil ou mais não é crível: é leitura feita antes de um app assíncrono (Arc,
    /// Electron, WhatsApp) aplicar o tamanho. Aceitar travaria a coluna na tela toda (visto no uso: 1704 pt
    /// no Arc, no Discord e no WhatsApp).
    public mutating func setMinWidth(_ window: WindowID, _ width: Double, at t: Double) {
        guard let k = index(of: window), width > columns[k].minWidth + 1, width < area.width - 1 else { return }
        columns[k].minWidth = width
        retarget(at: t)
    }

    /// Option+F: coluna ocupa a área toda; segundo toque volta pra largura anterior.
    public mutating func toggleFullWidthFocused(at t: Double) {
        guard let f = focusedIndex else { return }
        if let saved = columns[f].savedProportion {
            columns[f].proportion = saved
            columns[f].savedProportion = nil
        } else {
            columns[f].savedProportion = columns[f].proportion
            columns[f].proportion = 1
        }
        retarget(at: t)
    }

    /// Mostra a mesa ou traz a fita de volta. Sai pela esquerda quem tem o meio à esquerda do meio da tela.
    public mutating func setDesktop(_ on: Bool, at t: Double) {
        // Voltando no meio do caminho, os lados continuam os mesmos.
        if on && !showsDesktop && desktop.value(at: t) < 1 {
            desktopSplit = frames(at: t).prefix { $0.rect.midX < bounds.midX }.count
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
            }
        }
        for i in columns.indices { columns[i].offset.displace(by: Double(i) * (config.gap - c.gap), at: t) }
        config = c
        retarget(at: t)
    }

    // MARK: - Alvos e frames

    /// Recalcula larguras alvo e a rolagem alvo.
    /// Regra de rolagem (a padrão do niri): mexe o mínimo pra coluna focada ficar inteira na tela.
    public mutating func retarget(at t: Double) {
        desktop.retarget(showsDesktop ? 1000 : 0, at: t)
        for i in columns.indices {
            columns[i].width.retarget(slotWidth(columns[i]), at: t)
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
        return zip(columns, xs).enumerated().map { i, cx in
            let (c, (x, w)) = cx
            // Fora da viewport: encosta na borda da tela com `sliver` pt visíveis.
            // Como é um clamp, a janela sai da borda de forma contínua quando a fita rola.
            let lo = bounds.minX - w + config.sliver, hi = bounds.maxX - config.sliver
            var sx = min(max(x + (i < k ? -left : right), lo), hi)
            // Workspace entrando ou saindo: desliza junto toda coluna que aparece na tela, mesmo só em parte (a
            // distância da troca tira ela inteira; ver `Workspaces.switchTo`). A que está fora da viewport fica
            // estacionada: deslocada junto, ela entraria na tela (a 2ª coluna do workspace saindo pela esquerda
            // caía em x = 0, atrás da janela focada; visto no uso em 2026-10-16).
            if away {
                sx = shift.target < 0 ? lo : hi
            } else if s != 0 && sx > lo && sx < hi {
                sx = min(max(sx + s, lo), hi)
            }
            return WindowFrame(window: c.window, rect: CGRect(
                x: sx.rounded(), y: area.minY.rounded(),
                width: w, height: area.height.rounded()))
        }
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
            && columns.allSatisfy { $0.width.isNear(at: t, within: d) && $0.offset.isNear(at: t, within: d) }
    }

    public func isSettled(at t: Double) -> Bool {
        view.isSettled(at: t) && desktop.isSettled(at: t) && shift.isSettled(at: t) && columns.allSatisfy { $0.width.isSettled(at: t) && $0.offset.isSettled(at: t) }
    }

    public mutating func snapToTargets() {
        view.snap()
        desktop.snap()
        shift.snap()
        for i in columns.indices {
            columns[i].width.snap()
            columns[i].offset.snap()
        }
    }
}
