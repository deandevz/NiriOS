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

public struct LayoutConfig {
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
    public let config: LayoutConfig
    var view: Spring

    public init(area: CGRect, bounds: CGRect, config: LayoutConfig) {
        self.area = area
        self.bounds = bounds
        self.config = config
        self.view = Spring(0, stiffness: config.stiffness)
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
        c.minWidth = minWidth > area.width ? 0 : minWidth
        c.width = spring(slotWidth(c))
        columns.append(c)
        if focusedIndex == nil { focusedIndex = 0 }
    }

    /// Janela nova entra à direita da focada. As vizinhas da direita deslizam; ninguém encolhe.
    public mutating func insert(_ window: WindowID, proportion: Double? = nil, focus: Bool, at t: Double) {
        guard index(of: window) == nil else { return }
        let p = clamp(proportion ?? config.defaultProportion)
        let w = pixelWidth(p).rounded()
        let k = focusedIndex.map { $0 + 1 } ?? columns.count
        columns.insert(Column(window: window, proportion: p, savedProportion: nil,
                              width: spring(w), offset: spring(0)), at: k)
        for i in (k + 1)..<columns.count {
            columns[i].offset.displace(by: -(w + config.gap), at: t)
        }
        if focus || focusedIndex == nil { focusedIndex = k }
        retarget(at: t)
    }

    /// Tira a janela. Se era a focada, o foco vai pra vizinha da direita (ou da esquerda, se era a última).
    public mutating func remove(_ window: WindowID, at t: Double) {
        guard let k = index(of: window) else { return }
        let freed = columns[k].width.value(at: t) + config.gap
        columns.remove(at: k)
        guard let f = focusedIndex else { return }
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
    }

    public mutating func focus(_ window: WindowID, at t: Double) {
        guard let k = index(of: window), k != focusedIndex else { return }
        focusedIndex = k
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
    /// Mais largo que a área útil não é crível: é leitura feita antes de um app assíncrono (Arc,
    /// Electron) aplicar o tamanho. Aceitar travaria a coluna mais larga que a tela.
    public mutating func setMinWidth(_ window: WindowID, _ width: Double, at t: Double) {
        guard let k = index(of: window), width > columns[k].minWidth + 1, width <= area.width else { return }
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

    public mutating func setArea(_ area: CGRect, bounds: CGRect, at t: Double) {
        self.area = area
        self.bounds = bounds
        retarget(at: t)
    }

    // MARK: - Alvos e frames

    /// Recalcula larguras alvo e a rolagem alvo.
    /// Regra de rolagem (a padrão do niri): mexe o mínimo pra coluna focada ficar inteira na tela.
    public mutating func retarget(at t: Double) {
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

    public func frames(at t: Double) -> [WindowFrame] {
        let v = view.value(at: t)
        var x = 0.0
        var out: [WindowFrame] = []
        out.reserveCapacity(columns.count)
        for c in columns {
            // Largura inteira e posição acumulada a partir dela: o espaço entre colunas fica
            // sempre exatamente `gap`, e rolar a fita não muda a largura (não dispara resize).
            let w = c.width.value(at: t).rounded()
            var sx = area.minX + x + c.offset.value(at: t) - v
            // Fora da viewport: encosta na borda da tela com `sliver` pt visíveis.
            // Como é um clamp, a janela sai da borda de forma contínua quando a fita rola.
            sx = min(max(sx, bounds.minX - w + config.sliver), bounds.maxX - config.sliver)
            out.append(WindowFrame(window: c.window, rect: CGRect(
                x: sx.rounded(), y: area.minY.rounded(),
                width: w, height: area.height.rounded())))
            x += w + config.gap
        }
        return out
    }

    public func isSettled(at t: Double) -> Bool {
        view.isSettled(at: t) && columns.allSatisfy { $0.width.isSettled(at: t) && $0.offset.isSettled(at: t) }
    }

    public mutating func snapToTargets() {
        view.snap()
        for i in columns.indices {
            columns[i].width.snap()
            columns[i].offset.snap()
        }
    }
}
