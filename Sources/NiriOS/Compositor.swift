import AppKit
import QuartzCore

/// Transição do resize: durante a animação, a área das janelas vira nossa, como num compositor.
/// Papel de parede + foto de cada janela visível, cada uma no lugar que a fita manda a cada frame.
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
    private let wallpaper = CALayer()
    /// Desfoque atrás de janela translúcida, calibrado comparando frames com o WezTerm
    /// (`macos_window_background_blur = 28`): 30 bate; 60 e 100 ficam lisos demais.
    private let blurRadius = 30.0
    private let screenHeight: Double
    private let scale: Double

    /// Uma janela desenhada por nós. A foto já vem com o canto arredondado do macOS. A sombra é uma
    /// camada à parte, cortada pra existir só do lado de fora (como no macOS): calculada pelo contorno
    /// da foto, ela escurecia o fundo de janela translúcida por dentro e o WezTerm ficava cinza.
    private final class Tile {
        let box = CALayer(), shadow = CALayer(), shadowMask = CAShapeLayer()
        let clip = CALayer(), blur = CALayer(), old = CALayer(), live = CALayer()
        var radius = 27.0
        var liveShown = false
    }
    private var tiles: [CGWindowID: Tile] = [:]

    init(screen: NSScreen) {
        screenHeight = screen.frame.height
        scale = screen.backingScaleFactor
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let view = window.contentView!
        view.wantsLayer = true
        view.layerUsesCoreImageFilters = true  // desfoque atrás de janela translúcida
        root.frame = CGRect(origin: .zero, size: screen.frame.size)
        view.layer!.addSublayer(root)
        wallpaper.contentsGravity = .resize
        wallpaper.frame = CGRect(origin: .zero, size: screen.frame.size)
        root.addSublayer(wallpaper)
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

    /// Mostra a tela como ela está: papel de parede e as janelas, na ordem dada (a última fica em cima).
    func show(wallpaper image: CGImage?, windows: [(id: CGWindowID, photo: CGImage, frame: CGRect, active: Bool)]) {
        transaction {
            wallpaper.contents = image
            for (id, photo, frame, active) in windows {
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
                if Self.isTranslucent(photo) {
                    // O desfoque do fundo é o WindowServer que faz atrás da janela real; aqui é a gente.
                    t.blur.backgroundFilters = [CIFilter(name: "CIGaussianBlur", parameters: ["inputRadius": blurRadius])!]
                    t.clip.addSublayer(t.blur)
                }
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
        t.blur.frame = b
        t.old.frame = b
        t.live.frame = b
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
    /// O fundo do recorte vira a cor da borda direita dela: é o que aparece na sobra quando a imagem
    /// nova é mais estreita que o espaço (encolhendo).
    func setLive(_ id: CGWindowID, _ photo: CGImage) {
        let edge = Self.edgeColor(photo)
        transaction {
            tiles[id]?.live.contents = photo
            if let edge { tiles[id]?.clip.backgroundColor = edge }
        }
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

    /// Some com fade de 150 ms, já parado. A imagem bate com o app real, então o fade só suaviza o que
    /// não bate (como o efeito translúcido da barra lateral). Depois solta as fotos (dezenas de MB cada).
    func hide(done: @escaping () -> Void) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        CATransaction.setCompletionBlock { [self] in
            transaction {
                root.isHidden = true
                root.opacity = 1
                wallpaper.contents = nil
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

    /// Janela com fundo translúcido (WezTerm 0,94): alfa abaixo de 250 num recorte de 8x8 do meio.
    /// Só o recorte: desenhar a foto inteira (~28 MB) numa miniatura custava ~10 ms por janela.
    private static func isTranslucent(_ img: CGImage) -> Bool {
        var px = [UInt8](repeating: 0, count: 8 * 8 * 4)
        guard let ctx = CGContext(data: &px, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let mid = img.cropping(to: CGRect(x: img.width / 2, y: img.height / 2, width: 8, height: 8)) else { return false }
        ctx.draw(mid, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        return stride(from: 3, to: px.count, by: 4).contains { px[$0] < 250 }
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

    /// Média de diferença abaixo de 1 em 255: cursor piscando passa, redesenho no meio não.
    static func same(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        a.count == b.count && zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) } < a.count
    }

    /// Foto do papel de parede (a janela "Wallpaper" do Dock), ~7 ms.
    static func captureWallpaper() -> CGImage? {
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        let wall = list.first {
            ($0[kCGWindowOwnerName as String] as? String) == "Dock"
                && (($0[kCGWindowName as String] as? String) ?? "").hasPrefix("Wallpaper")
        }
        return (wall?[kCGWindowNumber as String] as? CGWindowID).flatMap(Private.capture)
    }
}
