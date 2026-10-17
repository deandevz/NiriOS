import AppKit
import QuartzCore

/// Borda da janela focada, como a do JankyBorders: uma camada só de contorno (o próprio CA desenha, sem bitmap: mudar de
/// tamanho não redesenha nada) numa janela nossa da tela toda, logo acima das janelas normais. O canto acompanha o da
/// janela, que o WindowServer informa (`Private.cornerRadius`) ou, se ele diz 0, medido na tela (`measureCorner`), na
/// mesma curva contínua do macOS 26 (conferido pixel a pixel no canto do Arc).
///
/// Segue o WindowServer, não o layout. A janela do app só muda de lugar 3 a 9 ms depois de o AX voltar (medido), então
/// uma borda que seguisse o frame calculado (como a do OmniWM) ou a volta do AX andaria na frente da janela. O aviso do
/// WindowServer chega quando a mudança já vale, e a borda vai junto. Gravando a tela a 120 fps com a janela andando 5 pt
/// por frame: 98 a 100% dos frames com a borda no lugar (o resto, 1 frame atrás). Mover uma janela nossa com
/// `SLSMoveWindow` deu o mesmo; com o AppKit (`setFrameOrigin`), metade dos frames 1 frame atrás. A camada também
/// muda de tamanho e aparece na mesma transação, então trocar de janela não mostra 1 frame com o tamanho velho. Nada
/// roda por frame do nosso lado e nada é lido do app. Prender uma janela nossa à do app pelo grupo de movimento do
/// WindowServer não funciona (docs/NOTES.md, "Borda").
final class FocusBorder {
    private let panel: NSPanel
    private let ring = CALayer()
    private var target: CGWindowID?
    /// Frame da janela (coordenadas AX) onde a borda está agora; nil = escondida.
    private var shownAt: CGRect?
    private var radius = 0.0
    /// Cor (nil = destaque do sistema) e espessura. 0 tira a borda.
    var style: (color: NSColor?, width: Double) = (nil, 3) {
        didSet { restyle() }
    }
    /// Com -v: quantas vezes a borda mudou desde a última leitura e o maior custo de uma mudança (s).
    private var stats = (moves: 0, maxCost: 0.0)
    /// A janela em volta da qual a borda está visível.
    private var shownFor: CGWindowID?
    /// Chamado quando a borda aparece numa janela (ou some: nil), dentro da mesma transação do CA. O vidro do resize
    /// tira a borda dele no mesmo commit (ver `GhostOverlay.ring`).
    var onShow: ((CGWindowID?) -> Void)?
    /// A janela saiu da tela sem fechar: fechada no X por app que só esconde (WhatsApp, Discord). Ela continua
    /// existindo, com o mesmo frame no WindowServer, e a borda ficava sozinha no lugar dela.
    private var hidden = false
    /// A janela está indo pro Dock ou voltando dele: o frame no WindowServer não muda durante a animação, e a borda
    /// ficava ~550 ms no lugar antigo (ver `Private.isMinimizing`).
    private var minimizing = false
    /// Raio medido na tela, por janela, pra janela que o WindowServer dá como quadrada (ver `measureCorner`).
    private var measured: [CGWindowID: Double] = [:]
    private var measuring = false
    private lazy var canCapture = CGPreflightScreenCaptureAccess()

    /// A nossa janela no WindowServer (fica fora das fotos do resize por fotos).
    var windowID: CGWindowID { CGWindowID(panel.windowNumber) }

    init() {
        panel = overlayPanel(NSScreen.screens[0])
        // Logo acima das janelas normais: fica por cima da sombra da janela focada sem precisar reordenar a cada vez
        // que o app traz a janela pra frente, e abaixo de painel flutuante, menu, Dock e do vidro do resize. Fora do
        // Mission Control (`.transient`); com a focada em outro Space ela some (ver `WindowManager.updateBorder`).
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)
        panel.collectionBehavior = [.transient, .ignoresCycle]
        ring.cornerCurve = .continuous
        ring.isHidden = true
        panel.contentView!.layer!.addSublayer(ring)
        // Fica sempre na tela, vazia quando não tem borda.
        panel.orderFrontRegardless()
    }

    /// Borda desligada no painel.
    deinit { panel.orderOut(nil) }

    /// A janela que leva a borda (nil esconde). Na main.
    func follow(_ id: CGWindowID?) {
        guard id != target else { return }
        target = id
        hidden = id.map { !Private.isOrderedIn($0) } ?? false
        minimizing = id.map(Private.isMinimizing) ?? false
        radius = id.map(cornerRadius) ?? 0
        restyle()
    }

    /// Aviso do WindowServer (ver `Private.watch`), de qualquer janela da fita; só o da janela da borda conta.
    func windowChanged(_ event: Private.WindowEvent, _ id: CGWindowID) {
        if event == .animationStarted || event == .animationEnded {
            // O aviso não diz a janela: confere a da borda (~0,05 ms, só quando alguma janela anima).
            guard let target, Private.isMinimizing(target) != minimizing else { return }
            minimizing.toggle()
            return place()
        }
        guard id == target else { return }
        if event == .hidden {
            hidden = true
        } else if hidden {
            hidden = !Private.isOrderedIn(id)
        }
        place()
    }

    /// Quanto da espessura fica fora da janela. 1 pt entra nela, como no JankyBorders: cobre o antialiasing do canto e o
    /// contorno fino do macOS. Encostando por fora, sobrava um fio claro de 1 a 2 px na curva do WezTerm (visto pelo
    /// usuário; o contorno de dentro de uma borda CA arredondada fica ~1 px mais pra fora que a curva da janela).
    static func outside(_ width: Double) -> Double { width - min(1, width / 2) }

    /// O do WindowServer ou, se ele diz 0, o medido na tela. Antes de medir (e sem Gravação de Tela), 9 pt, o mesmo
    /// palpite do JankyBorders pra janela sem barra de título: é o canto da maioria delas no macOS 26.
    func cornerRadius(of id: CGWindowID) -> Double { Self.cornerRadius(of: id, measured: measured[id]) }

    /// Sem a borda (desligada), o vidro do resize fica com o do WindowServer, ou 9 pt.
    static func cornerRadius(of id: CGWindowID, measured: Double? = nil) -> Double {
        let r = Private.cornerRadius(id) ?? 0
        return r > 0 ? r : measured ?? 9
    }

    /// Depois da animação: confere com o WindowServer, caso algum aviso tenha se perdido, e mede o canto se precisa.
    /// true = estava fora do lugar.
    func refresh() -> Bool {
        let before = shownAt
        place()
        measureCorner()
        return shownAt != before
    }

    /// O WindowServer dá raio 0 pra janela sem barra de título, mas o app pode desenhar o próprio canto: o WezTerm
    /// (`window_decorations = "RESIZE"`) desenha ~10 pt de canto dentro de um fundo translúcido quadrado, e a borda no
    /// quadrado deixava a quina translúcida entre ela e o canto que aparece (o JankyBorders faz igual: raio 0, borda
    /// quadrada por dentro). Então, com a janela parada na tela, uma foto de 48 pt do canto de cima, só da janela: a
    /// área de fora do canto (alpha abaixo de 85% do de dentro) dá o raio. Calibrado com o canto contínuo do CA (área
    /// ≈ 0,25 R²); no Arc dá 17 pt, e o WindowServer diz 16. Uma vez por janela, 10 a 35 ms, fora da main. Estacionada
    /// a foto vem vazia, então só depois que a animação assenta. Sem Gravação de Tela, fica o 0.
    private func measureCorner() {
        let box = 48.0
        guard let id = target, let r = shownAt, canCapture, !measuring, measured[id] == nil, Private.cornerRadius(id) == 0,
              r.width > 2 * box, r.height > 2 * box else { return }
        measuring = true
        DispatchQueue.global(qos: .utility).async {
            let found = Private.captureAlone(id, in: CGRect(origin: r.origin, size: CGSize(width: box, height: box)))
                .flatMap { Self.radius(ofCorner: $0, box: box) }
            DispatchQueue.main.async {
                self.measuring = false
                guard let found else { return }
                self.measured = self.measured.filter { Private.bounds($0.key) != nil }  // as que fecharam saem
                self.measured[id] = found
                log(String(format: "borda: canto da janela %u medido na tela: %.1f pt (o WindowServer diz 0)", id, found))
                if id == self.target, found != self.radius {
                    self.radius = found
                    self.restyle()
                }
            }
        }
    }

    /// A borda apareceu numa janela sem animação nenhuma depois (foco por clique, o niri-os recém-aberto): mede se ela
    /// ficar parada por 0,3 s. Andando, a conferência pós-animação mede.
    private func measureSoon() {
        let id = target, at = shownAt
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, target == id, shownAt == at else { return }
            measureCorner()
        }
    }

    private static func radius(ofCorner image: CGImage, box: Double) -> Double? {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let inner = Double(px[(w * h - 1) * 4 + 3])  // o canto oposto da foto, dentro da janela
        guard inner > 128 else { return nil }  // a janela não estava lá
        var outside = 0.0
        for i in 0..<(w * h) where Double(px[i * 4 + 3]) < inner * 0.85 { outside += 1 }
        return min(box / 2, 2 * outside.squareRoot() / (Double(w) / box))
    }

    private func restyle() {
        transaction {
            ring.borderWidth = style.width
            ring.borderColor = (style.color ?? .controlAccentColor).cgColor
            // Concêntrico com o canto da janela, 1 pt pra dentro dela (ver `outside`).
            ring.cornerRadius = radius + Self.outside(style.width)
        }
        shownAt = nil
        place()
    }

    /// Com o flush, a mudança sai na hora, e não no fim do ciclo do run loop (~0,014 ms).
    private func transaction(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
        CATransaction.flush()
    }

    /// Em volta da janela, onde o WindowServer diz que ela está. Estacionada (1 pt na borda da tela), escondida.
    private func place() {
        let t0 = CACurrentMediaTime()
        let screen = NSScreen.screens[0].frame
        let bounds = CGRect(origin: .zero, size: screen.size)
        guard let target, style.width > 0, !hidden, !minimizing, let r = Private.bounds(target), !AppWorker.isParked(r, screen: bounds) else {
            if !ring.isHidden || shownFor != nil {
                transaction {
                    ring.isHidden = true
                    shownFor = nil
                    onShow?(nil)
                }
            }
            shownAt = nil
            return
        }
        guard r != shownAt else { return }
        if panel.frame != screen { panel.setFrame(screen, display: false) }  // resolução mudou
        let out = Self.outside(style.width), f = r.insetBy(dx: -out, dy: -out), first = shownFor != target
        transaction {
            ring.frame = CGRect(x: f.minX, y: screen.height - f.maxY, width: f.width, height: f.height)
            ring.isHidden = false
            if first {
                shownFor = target
                onShow?(target)
            }
        }
        shownAt = r
        if first { measureSoon() }
        stats.moves += 1
        stats.maxCost = max(stats.maxCost, CACurrentMediaTime() - t0)
    }

    func takeStats() -> (moves: Int, maxCost: Double) {
        defer { stats = (0, 0) }
        return stats
    }
}
