import AppKit
import AVFoundation
import NiriCore
import UniformTypeIdentifiers

/// Papel de parede pelo config (`wallpaper`, `wallpaperEffect`).
///
/// Imagem: vira o papel de parede do próprio macOS (`setDesktopImageURL`), com o efeito já aplicado num PNG
/// em ~/Library/Application Support/niri-os/wallpaper. Depois disso custa zero: nenhuma janela nossa e
/// nenhum pixel na memória do niri-os, e vale também no Mission Control e na troca de Space.
/// Vídeo: uma janela nossa no nível do papel de parede (acima do do Dock, abaixo dos ícones da mesa), em
/// loop, tocando só com a mesa à mostra (Option+D ou fita vazia) e a janela visível. No resto do tempo fica
/// parado no quadro onde estava, que é o que aparece nos gaps entre as janelas.
///
/// Tudo isso roda em outro processo (`niri-os --wallpaper`), como o painel: ler a imagem e aplicar o efeito
/// aloca dezenas de MB, e o AVFoundation carregado não sai mais da memória. O niri-os só abre o processo
/// quando o config muda e manda "play"/"pause" pelo stdin.
enum WallpaperArt {
    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/niri-os/wallpaper")
    /// O papel de parede de antes do primeiro nosso, pra devolver quando `wallpaper` sair do config.
    static let original = dir.appendingPathComponent("original.txt")

    static func isVideo(_ url: URL) -> Bool { UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true }

    /// Gera o PNG (se ainda não existe) e põe como papel de parede do macOS. Sem efeito, a imagem vai
    /// direto. Vídeo: o 1º quadro, que fica atrás da janela do vídeo e aparece se o niri-os sair.
    static func apply(_ url: URL, effect: WallpaperEffect) {
        var target = url
        if effect != .none || isVideo(url) {
            let screen = NSScreen.screens[0]
            let a = try? FileManager.default.attributesOfItem(atPath: url.path)
            let key = [url.path, "\(a?[.size] ?? 0)", "\((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)",
                       effect.rawValue, "\(screen.frame.size)@\(screen.backingScaleFactor)"].joined(separator: "|")
            // Nome novo a cada mudança: com o mesmo nome o macOS mostra o arquivo velho do cache dele.
            target = dir.appendingPathComponent(fnv(key) + ".png")
            if !FileManager.default.fileExists(atPath: target.path) {
                let t0 = CACurrentMediaTime()
                guard let src = source(url, cover: screen.frame.size),
                      let img = render(src, effect: isVideo(url) ? .none : effect, size: screen.frame.size, scale: screen.backingScaleFactor),
                      write(img, to: target) else {
                    log("papel de parede: não consegui ler \(url.path)")
                    return
                }
                log(String(format: "papel de parede: %@ com %@ pronto em %.0f ms", url.lastPathComponent, effect.rawValue, (CACurrentMediaTime() - t0) * 1000))
            }
        }
        if !FileManager.default.fileExists(atPath: original.path), let cur = NSWorkspace.shared.desktopImageURL(for: NSScreen.screens[0]),
           cur != target, cur.deletingLastPathComponent().standardizedFileURL != dir.standardizedFileURL {
            try? cur.absoluteString.write(to: original, atomically: true, encoding: .utf8)
        }
        set(target)
        clean(keeping: target)
    }

    /// `wallpaper` saiu do config: volta o papel de parede de antes do primeiro nosso.
    static func restore() {
        guard let s = try? String(contentsOf: original, encoding: .utf8), let url = URL(string: s) else { return }
        set(url)
        try? FileManager.default.removeItem(at: original)
        clean(keeping: nil)
        log("papel de parede: voltou o de antes (\(url.lastPathComponent))")
    }

    private static func set(_ url: URL) {
        for s in NSScreen.screens where NSWorkspace.shared.desktopImageURL(for: s) != url {
            do {
                // Preencher a tela, como o padrão do Ajustes do Sistema.
                try NSWorkspace.shared.setDesktopImageURL(url, for: s, options: [
                    .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: true])
            } catch {
                log("papel de parede: o macOS recusou \(url.path): \(error.localizedDescription)")
            }
        }
    }

    /// Os PNGs de configurações anteriores.
    private static func clean(keeping keep: URL?) {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "png" && f.lastPathComponent != keep?.lastPathComponent {
            try? FileManager.default.removeItem(at: f)
        }
    }

    /// Hash estável entre execuções (o `Hasher` do Swift muda a cada processo).
    private static func fnv(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return String(h, radix: 16)
    }

    private static func write(_ img: CGImage, to url: URL) -> Bool {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(d, img, nil)
        return CGImageDestinationFinalize(d)
    }

    // MARK: - Imagem

    /// A imagem de origem, decodificada só no tamanho que precisa pra cobrir `size` (com folga de 2x pro
    /// filtro de redução). Uma foto de 8K inteira na memória teria ~130 MB.
    static func source(_ url: URL, cover size: CGSize) -> CGImage? {
        if isVideo(url) { return firstFrame(url) }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (p[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (p[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, w > 0, h > 0 else { return nil }
        // Cobrir a tela pede no máximo isso no lado maior (vale também com a foto girada pelo EXIF).
        let need = (max(w, h) * max(size.width, size.height) / min(w, h) * 2).rounded(.up)
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(w, h), need)] as CFDictionary)
    }

    private final class Box: @unchecked Sendable { var image: CGImage? }

    private static func firstFrame(_ url: URL) -> CGImage? {
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        g.appliesPreferredTrackTransform = true
        let box = Box(), done = DispatchSemaphore(value: 0)
        g.generateCGImageAsynchronously(for: .zero) { img, _, _ in box.image = img; done.signal() }
        done.wait()
        return box.image
    }

    /// O papel de parede em pixels da tela (`size` em pt, `scale` px por pt), cobrindo e centralizado. Como
    /// no Kinggie: uma amostra por célula do efeito (a imagem reduzida com filtro bom), o efeito nessas
    /// amostras, e cada uma ampliada sem filtro pro tamanho da célula, em blocos nítidos.
    static func render(_ img: CGImage, effect: WallpaperEffect, size: CGSize, scale: Double) -> CGImage? {
        let (cw, ch) = effect.cell
        let cols = Int((size.width / Double(cw)).rounded(.up)), rows = Int((size.height / Double(ch)).rounded(.up))
        guard var px = pixels(img, cols, rows) else { return nil }
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let ctx = context(w, h, nil) else { return nil }
        ctx.setFillColor(.black)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let cell = (w: Double(cw) * scale, h: Double(ch) * scale)
        // A grade começa no canto de cima; a sobra do arredondamento sai pela direita e por baixo.
        let top = Double(h)
        if effect == .ascii {
            drawASCII(px, cols, rows, cell: cell, top: top, scale: scale, in: ctx)
        } else {
            effect.apply(&px, width: cols, height: rows)
            guard let small = image(px, cols, rows) else { return nil }
            ctx.interpolationQuality = .none
            ctx.draw(small, in: CGRect(x: 0, y: top - Double(rows) * cell.h, width: Double(cols) * cell.w, height: Double(rows) * cell.h))
        }
        return ctx.makeImage()
    }

    /// Prévia do painel, `box` em pt. Com efeito: o centro da tela em tamanho real (reduzir um dither
    /// embaralha os pontos, o moiré da prévia do Kinggie). Sem efeito ou vídeo: a tela inteira reduzida.
    static func preview(_ url: URL, effect: WallpaperEffect, screen: CGSize, scale: Double, box: CGSize) -> CGImage? {
        guard let src = source(url, cover: screen) else { return nil }
        let w = Int(box.width * scale), h = Int(box.height * scale)
        if effect == .none || isVideo(url) { return pixels(src, w, h).flatMap { image($0, w, h) } }
        guard let full = render(src, effect: effect, size: screen, scale: scale) else { return nil }
        return full.cropping(to: CGRect(x: (full.width - w) / 2, y: (full.height - h) / 2, width: w, height: h))
    }

    private static func context(_ w: Int, _ h: Int, _ data: UnsafeMutableRawPointer?) -> CGContext? {
        CGContext(data: data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// `img` cobrindo `w`x`h`, centralizada, reduzida com o filtro bom. RGBA em sRGB, a 1ª linha é a de cima.
    private static func pixels(_ img: CGImage, _ w: Int, _ h: Int) -> [UInt8]? {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = context(w, h, buf.baseAddress) else { return false }
            ctx.interpolationQuality = .high
            let s = max(Double(w) / Double(img.width), Double(h) / Double(img.height))
            let dw = Double(img.width) * s, dh = Double(img.height) * s
            ctx.draw(img, in: CGRect(x: (Double(w) - dw) / 2, y: (Double(h) - dh) / 2, width: dw, height: dh))
            return true
        }
        return ok ? px : nil
    }

    private static func image(_ px: [UInt8], _ w: Int, _ h: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Um glifo por célula, centralizado, na cor da célula clareada, sobre preto. Fonte do Kinggie: mono
    /// de 11 pt, peso 500.
    private static func drawASCII(_ px: [UInt8], _ cols: Int, _ rows: Int, cell: (w: Double, h: Double),
                                  top: Double, scale: Double, in ctx: CGContext) {
        let font = NSFont.monospacedSystemFont(ofSize: 11 * scale, weight: .medium) as CTFont
        var chars = WallpaperEffect.glyphs.map { UniChar($0.utf16.first!) }
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs[1], &advance, 1)
        // `textBaseline: middle` do canvas: o meio da caixa da fonte no meio da célula.
        let lift = (CTFontGetAscent(font) - CTFontGetDescent(font)) / 2
        for r in 0..<rows {
            for c in 0..<cols {
                let i = (r * cols + c) * 4
                let g = WallpaperEffect.glyph(px[i], px[i + 1], px[i + 2])
                guard g.index > 0 else { continue }
                ctx.setFillColor(CGColor(srgbRed: Double(g.rgb[0]) / 255, green: Double(g.rgb[1]) / 255, blue: Double(g.rgb[2]) / 255, alpha: 1))
                var pos = CGPoint(x: (Double(c) + 0.5) * cell.w - advance.width / 2, y: top - (Double(r) + 0.5) * cell.h - lift)
                CTFontDrawGlyphs(font, &glyphs[g.index], &pos, 1, ctx)
            }
        }
    }
}

// MARK: - O processo (`niri-os --wallpaper <arquivo> [efeito]`, ou `--wallpaper none`)

enum WallpaperProcess {
    static func run(_ path: String, effect: WallpaperEffect) -> Never {
        guard path != "none" else {
            WallpaperArt.restore()
            exit(0)
        }
        let url = URL(fileURLWithPath: path)
        WallpaperArt.apply(url, effect: effect)
        guard WallpaperArt.isVideo(url) else { exit(0) }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)  // sem Dock, e o niri-os não põe na fita (só apps normais)
        let video = VideoWallpaper(url)
        withExtendedLifetime(video) { app.run() }
        exit(0)
    }
}

private final class VideoWallpaper: NSObject {
    private let window: NSWindow
    private let player = AVQueuePlayer()
    private let looper: AVPlayerLooper
    private var ready: NSKeyValueObservation?
    /// O niri-os disse que a mesa está à mostra.
    private var wanted = false

    init(_ url: URL) {
        let screen = NSScreen.screens[0]
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        // Acima do papel de parede do Dock (nível -2147483624) e abaixo da janela da mesa do Finder (ícones)
        // e da do WindowManager (clique pra mostrar a mesa), as duas no nível dos ícones.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.backgroundColor = .black
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false  // a tela apaga normalmente com a mesa à mostra
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        super.init()
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        layer.frame = CGRect(origin: .zero, size: screen.frame.size)
        window.contentView!.layer = layer
        window.contentView!.wantsLayer = true
        // Só entra na tela com o 1º quadro pronto: antes seria um retângulo preto.
        ready = layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] l, _ in
            guard l.isReadyForDisplay else { return }
            DispatchQueue.main.async { self?.window.orderFrontRegardless() }
        }
        // Outro Space, app em tela cheia, tela bloqueada ou apagada: o macOS avisa que ninguém vê a janela.
        NotificationCenter.default.addObserver(self, selector: #selector(update), name: NSWindow.didChangeOcclusionStateNotification, object: window)
        FileHandle.standardInput.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { exit(0) }  // o niri-os saiu
            let last = String(decoding: data, as: UTF8.self).split(separator: "\n").last
            DispatchQueue.main.async {
                self?.wanted = last == "play"
                self?.update()
            }
        }
    }

    @objc private func update() {
        if wanted && window.occlusionState.contains(.visible) { player.play() } else { player.pause() }
    }
}

// MARK: - O lado do niri-os

/// Abre o processo do papel de parede quando o config muda e diz a ele quando a mesa está à mostra.
/// Parado não roda nada: o processo de imagem sai sozinho, e o de vídeo só ouve o stdin.
final class WallpaperHost {
    private var process: Process?
    private var input: Pipe?
    /// O que o processo atual aplicou (arquivo e efeito).
    private var applied: String?
    private var video = false
    private var desktop = false
    private var sent: Bool?

    func apply(_ c: Config) {
        let key = "\(c.wallpaper?.path ?? "none")|\(c.wallpaperEffect.rawValue)"
        guard key != applied else { return }
        applied = key
        if process?.isRunning == true { process?.terminate() }
        process = nil
        // Sem papel de parede nosso e nada pra devolver: nem abre o processo.
        guard c.wallpaper != nil || FileManager.default.fileExists(atPath: WallpaperArt.original.path),
              let exe = Bundle.main.executableURL else { return }
        let p = Process(), pipe = Pipe()
        p.executableURL = exe
        p.arguments = ["--wallpaper", c.wallpaper?.path ?? "none", c.wallpaperEffect.rawValue]
        p.standardInput = pipe  // o log dele sai junto com o do niri-os (stderr herdado)
        p.terminationHandler = { p in
            let crashed = p.terminationReason == .uncaughtSignal ? p.terminationStatus != SIGTERM : p.terminationStatus != 0
            if crashed { log("papel de parede: o processo caiu (\(p.terminationReason == .uncaughtSignal ? "sinal" : "código") \(p.terminationStatus))") }
        }
        do {
            try p.run()
        } catch {
            return log("papel de parede: não consegui abrir o processo: \(error)")
        }
        process = p
        input = pipe
        video = c.wallpaper.map(WallpaperArt.isVideo) ?? false
        sent = nil
        send()
    }

    /// Mesa à mostra (Option+D ou fita vazia): o vídeo toca. Senão, para no quadro em que está.
    func desktopShown(_ on: Bool) {
        desktop = on
        send()
    }

    private func send() {
        guard video, desktop != sent, process?.isRunning == true else { return }
        sent = desktop
        // SIGPIPE ignorado (main): se o processo caiu, a escrita só falha.
        try? input?.fileHandleForWriting.write(contentsOf: Data((desktop ? "play\n" : "pause\n").utf8))
    }
}
