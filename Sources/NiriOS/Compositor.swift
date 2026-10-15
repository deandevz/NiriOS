import AppKit
import NiriCore
import QuartzCore

/// Janela nossa por cima das outras, na tela toda, transparente, sem clique e sem foco.
private func overlayPanel(_ screen: NSScreen) -> NSPanel {
    // Painel que não ativa o app: com NSWindow comum o macOS ativava o niri-os ao abrir (roubava o
    // foco do teclado e o foco inicial da fita caía na 1ª coluna).
    let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.becomesKeyOnlyIfNeeded = true
    panel.hidesOnDeactivate = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    // 99% opaca: janela totalmente opaca conta como "cobrindo" pro macOS, e app coberto para de
    // desenhar (WezTerm, Chromium). Aí a janela real redimensionava por baixo sem redesenhar, as
    // fotos ao vivo pegavam a imagem velha esticada e o fade de saída mostrava ela borrada.
    panel.alphaValue = 0.99
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    panel.contentView!.wantsLayer = true
    return panel
}

/// Resize fantasma (experimento, `"resizeStyle": "ghost"`), como a prévia do Loop: no lugar da janela
/// que muda de tamanho anda um vidro fosco nosso, e a janela real espera fora da tela. Quando a fita
/// para, ela volta já no tamanho final, por baixo do vidro, e o vidro some devagar por cima dela quando o
/// app termina de redesenhar. Nenhuma foto aparece na tela (as capturas só dizem quando o app terminou),
/// e o app redesenha escondido (piscada, sombra e imagem velha do WezTerm ficam atrás do vidro).
/// A própria janela não dá pra deixar transparente:
/// `SLSSetWindowAlpha` em janela de outro app não tem efeito (README, SkyLight).
final class GhostOverlay {
    /// Depois que a janela volta: espera máxima pelo app terminar de desenhar (vídeo tocando nunca
    /// termina) e duração do fade (s). Com 0,2 s e começo rápido, o fade parecia um corte.
    static let maxWait = 0.6, fade = 0.35
    private let window: NSPanel
    private let screenHeight: Double
    private var glass: [CGWindowID: NSVisualEffectView] = [:]

    init(screen: NSScreen) {
        screenHeight = screen.frame.height
        window = overlayPanel(screen)
        // Fica sempre na tela, vazia, como a TransitionOverlay: mostrar na hora da tecla atrasava.
        window.orderFrontRegardless()
    }

    private func flip(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: screenHeight - r.maxY, width: r.width, height: r.height)
    }

    /// Vidro no lugar da janela. Se ele estava sumindo (outra tecla logo depois), volta inteiro.
    func show(_ id: CGWindowID, at r: CGRect) {
        let v = glass[id] ?? makeGlass()
        glass[id] = v
        v.layer?.removeAllAnimations()
        v.alphaValue = 1
        v.frame = flip(r)
    }

    private func makeGlass() -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow  // o mesmo desfoque da prévia do Loop
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = 16  // canto das janelas no macOS 26 (o Loop usa o mesmo)
        v.layer?.masksToBounds = true
        v.layer?.borderWidth = 3
        v.layer?.borderColor = NSColor.controlAccentColor.cgColor
        window.contentView!.addSubview(v)
        return v
    }

    /// A cada frame: o vidro segue a janela dele na fita.
    func update(_ frames: [WindowFrame]) {
        guard !glass.isEmpty else { return }
        for f in frames { glass[f.window]?.frame = flip(f.rect) }
    }

    func fadeOut(_ id: CGWindowID) {
        guard let v = glass[id] else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.fade
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            v.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, v.alphaValue == 0, glass[id] === v else { return }  // voltou no meio do fade
            v.removeFromSuperview()
            glass[id] = nil
        })
    }
}

/// Transição do resize: durante a animação, a área das janelas vira nossa, como num compositor.
/// Fundo (a tela sem as janelas que animam) + foto de cada janela visível, cada uma no lugar que a
/// fita manda a cada frame.
/// Por baixo, as janelas reais já foram pro lugar final, na tela, uma vez só: nenhum app precisa
/// acompanhar a animação (o WhatsApp leva ~150 ms por resize; Chromium desenha depois), então
/// serve pra qualquer app.
///
/// A janela que muda de tamanho aparece já no layout novo (o app redimensionado, fotografado ao vivo
/// por baixo), sempre em tamanho real, presa à esquerda: crescendo, a borda direita revela; encolhendo,
/// a sobra à direita tem a cor da borda do app e fecha. Nada estica e nada se mistura. Testado e
/// descartado (ver README): esticar (texto deforma), fundir velha e nova (fantasma), trocar no meio
/// esticando (com passos de 1/3 a imagem do meio fica muito esticada), dissolver no fim (fantasma
/// parado).
final class TransitionOverlay {
    private let window: NSWindow
    /// Tudo fica nessa camada, não na raiz da view: a raiz de view do AppKit ignora animação implícita
    /// (o fade de saída acontecia num frame só).
    private let root = CALayer()
    private let background = CALayer()
    private let screenHeight: Double
    private let scale: Double

    /// Uma janela desenhada por nós. A foto já vem com o canto arredondado do macOS. A sombra é uma
    /// camada à parte, cortada pra existir só do lado de fora (como no macOS): calculada pelo contorno
    /// da foto, ela escurecia o fundo de janela translúcida por dentro e o WezTerm ficava cinza.
    /// Dentro de `old`, por cima da foto inteira, duas partes tiradas da tela (`Private.captureShown`,
    /// a única captura com o fundo translúcido certo): `ahead`, a que vai estar na tela no fim, e por
    /// cima dela `shown`, a que estava na tela no começo.
    private final class Tile {
        let box = CALayer(), shadow = CALayer(), shadowMask = CAShapeLayer()
        let clip = CALayer(), gap = CALayer(), old = CALayer(), ahead = CALayer(), shown = CALayer(), live = CALayer()
        var radius = 27.0
        var liveShown = false
        /// Largura (pt) da imagem que está aparecendo: à direita dela, até a borda, vai a sobra (`gap`).
        var shownWidth = 0.0
    }
    private var tiles: [CGWindowID: Tile] = [:]

    /// A nossa janela no WindowServer.
    var windowID: CGWindowID { CGWindowID(window.windowNumber) }

    init(screen: NSScreen) {
        screenHeight = screen.frame.height
        scale = screen.backingScaleFactor
        window = overlayPanel(screen)
        root.frame = CGRect(origin: .zero, size: screen.frame.size)
        window.contentView!.layer!.addSublayer(root)
        background.contentsGravity = .resize
        background.frame = CGRect(origin: .zero, size: screen.frame.size)
        root.addSublayer(background)
        root.isHidden = true
        // Fica sempre na tela, vazia: esconder (orderOut) e mostrar de novo logo depois fazia a foto
        // aparecer ~170 ms atrasada.
        window.orderFrontRegardless()
    }

    private func flip(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: screenHeight - r.maxY, width: r.width, height: r.height)
    }

    private func transaction(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    /// Foto de uma janela: ela inteira (vale pra parte que entra na tela durante a animação) e a parte
    /// que está na tela (`area`), como o WindowServer mostra.
    typealias Photo = (full: CGImage, shown: CGImage?, area: CGRect)

    /// ~10 a 15 ms da foto inteira + 10 a 20 ms da parte na tela. `frame` é onde a janela está agora.
    static func photo(_ id: CGWindowID, at frame: CGRect, screen: CGRect) -> Photo? {
        guard let full = Private.capture(id) else { return nil }
        let area = frame.intersection(screen)
        return (full, area.width >= 1 ? Private.captureShown(id, in: area) : nil, area)
    }

    /// Mostra a tela como ela está: o fundo e as janelas, na ordem dada (a última fica em cima).
    func show(background image: CGImage?, windows: [(id: CGWindowID, photo: Photo, frame: CGRect, active: Bool)]) {
        transaction {
            background.contents = image
            for (id, p, frame, active) in windows {
                let photo = p.full
                let t = Tile()
                t.shadow.shadowOpacity = active ? 0.5 : 0.32
                t.shadow.shadowRadius = active ? 30 : 16
                t.shadow.shadowOffset = CGSize(width: 0, height: active ? -16 : -6)
                t.shadowMask.fillRule = .evenOdd
                t.shadow.mask = t.shadowMask
                t.box.addSublayer(t.shadow)
                t.radius = Self.cornerRadius(photo, pointWidth: frame.width)
                for l in [t.old, t.live] { l.contentsGravity = .topLeft; l.contentsScale = scale }
                t.clip.masksToBounds = true
                t.old.contents = photo
                t.live.opacity = 0
                t.shownWidth = Double(photo.width) / scale
                t.old.addSublayer(t.ahead)
                t.old.addSublayer(t.shown)
                if let shown = p.shown { put(t.shown, shown, area: p.area, frame: frame) }
                t.clip.addSublayer(t.gap)
                t.clip.addSublayer(t.old)
                t.clip.addSublayer(t.live)
                t.box.addSublayer(t.clip)
                root.addSublayer(t.box)
                tiles[id] = t
                place(t, frame)
            }
            root.isHidden = false
        }
    }

    private func place(_ t: Tile, _ r: CGRect) {
        t.box.frame = flip(r)
        let b = CGRect(origin: .zero, size: r.size)
        t.shadow.frame = b
        t.shadow.shadowPath = CGPath(roundedRect: b, cornerWidth: t.radius, cornerHeight: t.radius, transform: nil)
        let m: Double = 120  // a sombra vai até ~60 pt pra fora
        t.shadowMask.frame = b.insetBy(dx: -m, dy: -m)
        let hole = CGMutablePath()
        hole.addRect(t.shadowMask.bounds)
        hole.addRoundedRect(in: CGRect(x: m, y: m, width: b.width, height: b.height), cornerWidth: t.radius, cornerHeight: t.radius)
        t.shadowMask.path = hole
        t.clip.frame = b
        t.clip.cornerRadius = t.radius  // o recorte precisa do canto da janela no tamanho atual
        t.gap.frame = CGRect(x: t.shownWidth, y: 0, width: max(0, b.width - t.shownWidth), height: b.height)
        t.old.frame = b
        t.live.frame = b
    }

    /// A parte `area` da janela em `frame`, presa à esquerda como a foto (origem da camada embaixo).
    private func put(_ l: CALayer, _ img: CGImage, area: CGRect, frame: CGRect) {
        l.contents = img
        l.frame = CGRect(x: area.minX - frame.minX, y: frame.maxY - area.maxY, width: area.width, height: area.height)
    }

    /// Vizinha já no lugar final, por baixo de nós: a parte dela que vai estar na tela no fim. O que
    /// entra na tela durante a animação vinha da foto inteira, com o fundo cinza, e piscava no fim.
    func setAhead(_ id: CGWindowID, _ img: CGImage, area: CGRect, frame: CGRect) {
        guard let t = tiles[id] else { return }
        transaction { put(t.ahead, img, area: area, frame: frame) }
    }

    /// Fim da transição, antes do fade: a parte na tela de cada janela parada, tirada de novo no lugar
    /// final. A vizinha que deslizou pra dentro trazia da foto inteira o fundo cinza da parte que
    /// estava fora da tela.
    func setShown(_ photos: [CGWindowID: (img: CGImage, area: CGRect, frame: CGRect)]) {
        transaction {
            for (id, p) in photos {
                guard let t = tiles[id] else { continue }
                // A que mudou de tamanho já está mostrando a imagem ao vivo, não a foto velha.
                if t.liveShown, p.area == p.frame { t.live.contents = p.img } else { put(t.shown, p.img, area: p.area, frame: p.frame) }
            }
        }
    }

    /// A cada frame: onde cada janela está. A janela que muda de tamanho troca pro layout novo uma
    /// vez, no começo, com fusão de 50 ms: a nova entra por cima da velha, que só some depois (as duas
    /// meio transparentes ao mesmo tempo deixavam o fundo aparecer, e duas translúcidas empilhadas
    /// escondiam o desfoque do WezTerm).
    func update(_ frames: [CGWindowID: CGRect], morph: CGWindowID) {
        transaction {
            for (id, r) in frames { if let t = tiles[id] { place(t, r) } }
        }
        guard let t = tiles[morph], t.live.contents != nil, !t.liveShown else { return }
        t.liveShown = true
        if let img = t.live.contents { t.shownWidth = Double((img as! CGImage).width) / scale }
        Self.fade(t.live, to: 1, 0.05) { Self.fade(t.old, to: 0, 0) }
    }

    private static func fade(_ l: CALayer, to value: Float, _ duration: Double, done: (() -> Void)? = nil) {
        let from = l.presentation()?.opacity ?? l.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        l.opacity = value
        CATransaction.commit()
        guard duration > 0 else { done?(); return }
        CATransaction.begin()
        CATransaction.setCompletionBlock(done)
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue = value
        a.duration = duration
        l.add(a, forKey: "fade")
        CATransaction.commit()
    }

    /// Foto mais recente da janela que muda de tamanho (ela está no lugar final, por baixo de nós).
    /// A sobra (quando a imagem nova é mais estreita que o espaço, encolhendo) ganha a cor da borda
    /// direita dela.
    func setLive(_ id: CGWindowID, _ photo: CGImage) {
        guard let t = tiles[id] else { return }
        let edge = Self.edgeColor(photo)
        transaction {
            t.live.contents = photo
            t.gap.backgroundColor = edge
        }
    }

    /// A imagem ao vivo que está aparecendo, se já entrou (pro log).
    func liveImage(_ id: CGWindowID) -> CGImage? {
        guard let t = tiles[id], t.liveShown, let c = t.live.contents else { return nil }
        return (c as! CGImage)
    }

    /// Cor média de uma faixa de 4 px na borda direita, no meio da altura.
    private static func edgeColor(_ img: CGImage) -> CGColor? {
        guard let strip = img.cropping(to: CGRect(x: img.width - 8, y: img.height / 4, width: 4, height: img.height / 2)) else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(strip, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let a = Double(px[3]) / 255
        guard a > 0 else { return nil }
        return CGColor(srgbRed: Double(px[0]) / 255 / a, green: Double(px[1]) / 255 / a, blue: Double(px[2]) / 255 / a, alpha: a)
    }

    /// Some com fade de 150 ms, já parado. A parte visível acabou de ser tirada da tela (`setShown`),
    /// então o fade só suaviza o que mudou no último instante. Depois solta as fotos (dezenas de MB cada).
    func hide(done: @escaping () -> Void) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        CATransaction.setCompletionBlock { [self] in
            transaction {
                root.isHidden = true
                root.opacity = 1
                background.contents = nil
                for t in tiles.values { t.box.removeFromSuperlayer() }
            }
            tiles = [:]
            done()
        }
        root.opacity = 0
        CATransaction.commit()
    }

    /// Raio do canto, medido na própria foto: na diagonal do canto, o primeiro pixel opaco fica a
    /// r·(1 − 1/√2) do vértice. WhatsApp: ~27 pt.
    private static func cornerRadius(_ img: CGImage, pointWidth: Double) -> Double {
        let n = 64
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard pointWidth > 0, let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                                  space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 27 }
        // Canto superior esquerdo da foto, em tamanho real (n x n pixels).
        guard let corner = img.cropping(to: CGRect(x: 0, y: 0, width: n, height: n)) else { return 27 }
        ctx.draw(corner, in: CGRect(x: 0, y: 0, width: n, height: n))
        let pxPerPt = Double(img.width) / pointWidth
        // No contexto a linha 0 é a de baixo: o canto de cima da foto está nas linhas do fim.
        for d in 0..<n where px[((n - 1 - d) * n + d) * 4 + 3] > 128 {
            return Double(d) / (1 - 1 / 2.0.squareRoot()) / pxPerPt
        }
        return 27
    }

    /// Miniatura 48x30 em cinza, pra saber se duas capturas são iguais (o app parou de desenhar).
    static func signature(_ img: CGImage) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: 48 * 30)
        guard let ctx = CGContext(data: &px, width: 48, height: 30, bitsPerComponent: 8, bytesPerRow: 48,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return px }
        ctx.interpolationQuality = .low
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: 48, height: 30))
        return px
    }

    /// Diferença média entre duas miniaturas, em 255.
    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        a.count == b.count ? Double(zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(a.count) : 255
    }

    /// Média de diferença abaixo de 1 em 255: cursor piscando passa, redesenho no meio não.
    static func same(_ a: [UInt8], _ b: [UInt8]) -> Bool { difference(a, b) < 1 }

    /// O fundo como está na tela, sem as janelas que nós desenhamos (`drawn`): papel de parede, mesa e
    /// as janelas estacionadas na borda, com a sombra delas. Só com o papel de parede, as bordas da
    /// tela clareavam de 28 pra 70 (em 255) quando a camada entrava. ~15 a 25 ms.
    static func captureBackground(below overlay: CGWindowID, drawn: Set<CGWindowID>, in rect: CGRect) -> CGImage? {
        let list = (CGWindowListCopyWindowInfo(.optionOnScreenBelowWindow, overlay) as? [[String: Any]]) ?? []
        return Private.captureShown(list.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }.filter { !drawn.contains($0) }, in: rect)
    }
}
