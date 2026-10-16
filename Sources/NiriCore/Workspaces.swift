import CoreGraphics

/// Workspaces lado a lado, como os Spaces do macOS: uma fita (`Layout`) por workspace. Trocar desliza a fita
/// atual pra fora e a nova pra dentro; as outras ficam fora da tela, estacionadas (1 pt na borda, a regra de
/// sempre). Na horizontal porque é o único eixo em que o macOS deixa a janela sair da tela: em cima ela para
/// na barra de menu, embaixo sobram 24 pt à mostra (medido em 2026-10-16).
public struct Workspaces {
    public private(set) var names: [String]
    private var strips: [Layout]
    public private(set) var active = 0

    public init(names: [String], area: CGRect, bounds: CGRect, config: LayoutConfig) {
        self.names = names.isEmpty ? ["1"] : names
        strips = self.names.map { _ in Layout(area: area, bounds: bounds, config: config) }
        for i in strips.indices.dropFirst() { strips[i].park(1) }
    }

    public subscript(k: Int) -> Layout {
        get { strips[k] }
        _modify { yield &strips[k] }
    }

    /// A fita do workspace na tela.
    public var current: Layout {
        get { strips[active] }
        _modify { yield &strips[active] }
    }

    public var count: Int { strips.count }
    public var windows: [WindowID] { strips.flatMap(\.windows) }
    public func index(of window: WindowID) -> Int? { strips.firstIndex { $0.index(of: window) != nil } }
    public func index(named name: String) -> Int? { names.firstIndex(of: name) }

    /// Vai pro workspace `k`: a fita atual sai pelo lado oposto ao de `k`, e a de `k` entra. Trocar no meio
    /// da animação preserva a velocidade, como o resto.
    public mutating func switchTo(_ k: Int, at t: Double) {
        guard k != active, strips.indices.contains(k) else { return }
        let dir: Double = k > active ? 1 : -1
        if strips[active].showsDesktop {
            // Com a mesa à mostra as janelas já estão nas bordas: a fita vai direto pro lado dela, sem animar.
            strips[active].setDesktop(false, at: t)
            strips[active].park(-dir)
            strips[active].snapToTargets()
        } else {
            strips[active].slide(to: -dir, at: t)
        }
        // Parada fora da tela do lado errado (sobrou de uma troca anterior): pula pro lado certo antes de entrar.
        let s = strips[k].shift
        if s.isSettled(at: t) && s.target * dir < 0 { strips[k].park(dir) }
        strips[k].slide(to: 0, at: t)
        active = k
    }

    /// Manda a janela pro workspace `k`: entra lá à direita da focada e vira a focada de lá. Aqui ela sai na
    /// hora e as vizinhas fecham o buraco, como ao fechar uma janela. Deslizando até a borda, ela passava por
    /// cima da vizinha (5 a 6 frames com sobreposição nos painéis de teste).
    public mutating func move(_ window: WindowID, to k: Int, at t: Double) {
        guard let a = index(of: window), a != k, strips.indices.contains(k),
              let c = strips[a].remove(window, at: t) else { return }
        strips[k].insert(c, focus: true, at: t)
    }

    /// Devolve a coluna, pra janela voltar com a mesma largura (ver `Layout.insert(_:position:focus:at:)`).
    @discardableResult
    public mutating func remove(_ window: WindowID, at t: Double) -> Column? {
        guard let k = index(of: window) else { return nil }
        return strips[k].remove(window, at: t)
    }

    /// Lista nova do config. Os workspaces são casados pelo nome; as janelas de um que saiu da lista vão pro
    /// atual (nenhuma janela fica perdida fora da tela). Se o atual saiu, o 1º da lista entra.
    public mutating func setNames(_ list: [String], at t: Double) {
        let list = list.isEmpty ? ["1"] : list
        guard list != names else { return }
        let orphans = names.indices.filter { !list.contains(names[$0]) }.flatMap { strips[$0].columns }
        let template = strips[0]
        let now = list.firstIndex(of: names[active]) ?? 0
        strips = list.map { n in
            names.firstIndex(of: n).map { strips[$0] } ?? Layout(area: template.area, bounds: template.bounds, config: template.config)
        }
        names = list
        active = now
        for i in strips.indices where i != now && strips[i].shift.target == 0 { strips[i].park(i < now ? -1 : 1) }
        strips[now].slide(to: 0, at: t)
        for c in orphans { strips[now].insert(c, focus: false, at: t) }
    }

    public func frames(at t: Double) -> [WindowFrame] { strips.flatMap { $0.frames(at: t) } }
    public func isSettled(at t: Double) -> Bool { strips.allSatisfy { $0.isSettled(at: t) } }
    public func isNear(at t: Double, within d: Double) -> Bool { strips.allSatisfy { $0.isNear(at: t, within: d) } }

    public mutating func snapToTargets() {
        for i in strips.indices { strips[i].snapToTargets() }
    }

    public mutating func setArea(_ area: CGRect, bounds: CGRect, at t: Double) {
        for i in strips.indices {
            strips[i].setArea(area, bounds: bounds, at: t)
            // As de fora acompanham a largura nova da tela; já estão fora, então sem animar.
            if i != active { strips[i].park(strips[i].shift.target < 0 ? -1 : 1) }
        }
    }

    public mutating func setConfig(_ c: LayoutConfig, at t: Double) {
        for i in strips.indices { strips[i].setConfig(c, at: t) }
    }
}

extension Layout {
    /// Fita inteira fora da tela do lado `side` (-1 esquerda, 1 direita), sem animar.
    mutating func park(_ side: Double) { shift = Spring(side * bounds.width, stiffness: config.stiffness) }

    /// Desliza a fita inteira: 0 = na tela, ±1 = fora dela, daquele lado.
    mutating func slide(to side: Double, at t: Double) { shift.retarget(side * bounds.width, at: t) }
}
