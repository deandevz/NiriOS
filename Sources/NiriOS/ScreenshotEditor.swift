import AppKit
import Carbon.HIToolbox
import NiriCore
import UniformTypeIdentifiers

/// O editor do print (Option+S), num processo só dele: `niri-os --screenshot <tela> <pasta>`, aberto por `Screenshot`.
/// Recebe a foto da tela pelo stdin e mostra ela escurecida por cima de tudo, então o frame da tecla fica parado.
/// Arrastar escolhe a área, as alças mudam o tamanho, e a barra embaixo dela tem as ferramentas. ⌘C (ou ↩) copia, ⌘S
/// salva na pasta, Esc cancela. O processo sai em seguida: a foto (31 MB numa tela Retina) não fica em lugar nenhum.
///
/// Não ativa o processo (`nonactivatingPanel`, como o painel do Option+V): o app da frente continua o mesmo, e o
/// niri-os não vê troca de foco.
final class ScreenshotEditor: NSView, NSWindowDelegate, NSTextViewDelegate {
    enum Tool: CaseIterable {
        case pen, line, arrow, rect, marker, text, pixelate

        var title: String {
            switch self {
            case .pen: "Caneta"
            case .line: "Linha"
            case .arrow: "Seta"
            case .rect: "Retângulo"
            case .marker: "Marca-texto"
            case .text: "Texto"
            case .pixelate: "Pixelar"
            }
        }

        /// Sem nenhuma ferramenta escolhida, ou fora do texto, a letra escolhe.
        var key: String {
            switch self {
            case .pen: "p"
            case .line: "l"
            case .arrow: "a"
            case .rect: "r"
            case .marker: "m"
            case .text: "t"
            case .pixelate: "x"
            }
        }

        var symbol: String {
            switch self {
            case .pen: "scribble.variable"
            case .line: "line.diagonal"
            case .arrow: "arrow.up.right"
            case .rect: "rectangle"
            case .marker: "highlighter"
            case .text: "textformat"
            case .pixelate: "checkerboard.rectangle"
            }
        }
    }

    /// Um desenho, em pontos da tela. `size` é a espessura escolhida (a rolagem do mouse muda); cada ferramenta faz a
    /// conta dela (ver `width`).
    struct Mark {
        enum Shape {
            case pen([CGPoint]), marker([CGPoint]), line(CGPoint, CGPoint), arrow(CGPoint, CGPoint), rect(CGRect)
            case text(NSAttributedString, CGPoint), pixelate(CGRect)
        }
        var shape: Shape
        var color: NSColor
        var size: CGFloat
    }

    private static let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .black, .white]

    private let photo: CGImage
    private let folder: URL
    /// A parte livre da tela da foto, pro aviso de salvo (a janela já saiu da tela e não diz mais em qual estava).
    private let visible: CGRect
    private var area: CaptureArea
    private var tool: Tool?
    private var color = NSColor.systemRed
    private var size: CGFloat = 4
    /// Cada desenho com a camada dele na tela.
    private var marks: [(mark: Mark, layer: CALayer)] = []
    private var undone: [(mark: Mark, layer: CALayer)] = []
    /// O desenho em andamento, ainda fora de `marks`.
    private var current: Mark?
    private var currentLayer: CALayer?
    private var gesture: Gesture?
    private var text: NSTextView?
    private var scrolled: CGFloat = 0

    private enum Gesture {
        case selecting(CGPoint)
        case adjusting(CaptureArea.Grab, CGRect, CGPoint)
        case drawing(CGPoint)
    }

    private let panel: NSPanel
    /// Copiando ou salvando: a janela sai da tela sem ser cancelamento.
    private var finished = false
    /// Os desenhos, recortados na área: o frame dela é o da área.
    private let ink = Shade()
    private let shade = Shade()
    private let dim = CAShapeLayer(), outline = CAShapeLayer(), hint = CAShapeLayer()
    private let handles = CaptureArea.Handle.allCases.map { _ in CALayer() }
    private let label = CATextLayer(), labelBack = CALayer()
    private let toolbar = Bar()
    private var toolButtons: [Tool: NSButton] = [:]
    private var swatches: [NSButton] = []
    private var hideHint: DispatchWorkItem?

    /// A borderless não vira janela do teclado sem isso.
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    /// Uma view só de camadas (o escuro, o contorno, as alças, os desenhos). Virada como o editor: o AppKit acerta a
    /// camada pelo `isFlipped` da view, e numa view sem ele as contas com y pra baixo saíam de cabeça pra baixo.
    private final class Shade: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// A barra engole o clique no vidro em volta dos botões: senão ele chegaria no editor como começo de área nova.
    private final class Bar: NSView {
        override var isFlipped: Bool { true }
        override func mouseDown(with event: NSEvent) {}
        override func mouseDragged(with event: NSEvent) {}
    }

    // MARK: - Processo

    private static var editor: ScreenshotEditor?

    /// O processo do editor: lê a foto numa thread enquanto o AppKit se conecta ao WindowServer, e abre a janela.
    static func run(display: CGDirectDisplayID, folder: URL, since t0: Double?) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // Sem menu, os atalhos de texto não chegam na caixa de texto. ⌘C e ⌘Z são do editor (ver `key`).
        let edit = NSMenu()
        edit.addItem(withTitle: "Recortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Colar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Selecionar tudo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        app.mainMenu = NSMenu()
        app.mainMenu!.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = edit
        Thread {
            let photo = readPhoto(display)
            DispatchQueue.main.async {
                let screen = NSScreen.screens.first { $0.deviceDescription[.init("NSScreenNumber")] as? CGDirectDisplayID == display }
                guard let photo, let screen else { exit(1) }  // o niri-os não mandou a foto (permissão, falha)
                editor = ScreenshotEditor(photo, screen: screen, folder: folder)
                if let t0 {
                    CATransaction.setCompletionBlock { log(String(format: "print: editor na tela aos %.0f ms da tecla", (CACurrentMediaTime() - t0) * 1000)) }
                }
            }
        }.start()
        app.run()
        exit(0)
    }

    /// Uma linha com largura, altura, bits por cor, bits por pixel, bytes por linha e formato; depois os pixels.
    private static func readPhoto(_ display: CGDirectDisplayID) -> CGImage? {
        var header: [UInt8] = [], byte: UInt8 = 0
        while read(0, &byte, 1) == 1, byte != UInt8(ascii: "\n") { header.append(byte) }
        let f = String(decoding: header, as: UTF8.self).split(separator: " ").compactMap { Int($0) }
        guard f.count == 6, f[4] > 0, f[1] > 0 else { return nil }
        let n = f[4] * f[1]
        let pixels = UnsafeMutableRawPointer.allocate(byteCount: n, alignment: 16)
        var done = 0
        while done < n {
            let r = read(0, pixels + done, n - done)
            if r < 0 && errno == EINTR { continue }
            guard r > 0 else { pixels.deallocate(); return nil }
            done += r
        }
        guard let provider = CGDataProvider(dataInfo: nil, data: pixels, size: n, releaseData: { _, p, _ in p.deallocate() })
        else { return nil }
        // No espaço de cor da tela, como veio da foto: na janela, sem conversão, sai igual ao que estava na tela.
        return CGImage(width: f[0], height: f[1], bitsPerComponent: f[2], bitsPerPixel: f[3], bytesPerRow: f[4],
                       space: CGDisplayCopyColorSpace(display), bitmapInfo: CGBitmapInfo(rawValue: UInt32(f[5])),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: - Janela

    private init(_ photo: CGImage, screen: NSScreen, folder: URL) {
        self.photo = photo
        self.folder = folder
        visible = screen.visibleFrame
        let frame = CGRect(origin: .zero, size: screen.frame.size)
        area = CaptureArea(bounds: frame, scale: CGFloat(photo.width) / frame.width)
        panel = Panel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init(frame: frame)

        let photoView = NSView(frame: frame)
        photoView.layer = CALayer()
        photoView.wantsLayer = true
        photoView.layer?.contents = photo
        addSubview(photoView)
        ink.layer = CALayer()
        ink.layer?.masksToBounds = true
        ink.wantsLayer = true
        addSubview(ink)
        shade.frame = frame
        shade.layer = CALayer()
        shade.wantsLayer = true
        dim.fillColor = NSColor.black.withAlphaComponent(0.45).cgColor
        dim.fillRule = .evenOdd
        outline.fillColor = nil
        outline.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        outline.lineWidth = 1
        labelBack.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        labelBack.cornerRadius = 5
        label.contentsScale = area.scale
        label.alignmentMode = .center
        labelBack.addSublayer(label)
        for l in [dim, outline, labelBack, hint] { shade.layer?.addSublayer(l) }
        for h in handles {
            h.bounds = CGRect(x: 0, y: 0, width: 9, height: 9)
            h.cornerRadius = 4.5
            h.backgroundColor = NSColor.white.cgColor
            h.borderColor = NSColor.black.withAlphaComponent(0.25).cgColor
            h.borderWidth = 0.5
            h.shadowOpacity = 0.3
            h.shadowRadius = 1.5
            h.shadowOffset = .zero
            shade.layer?.addSublayer(h)
        }
        hint.opacity = 0
        hint.lineWidth = 1.5
        hint.strokeColor = NSColor.white.cgColor
        addSubview(shade)
        buildToolbar()
        addSubview(toolbar)
        update()

        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.hasShadow = false
        panel.backgroundColor = .black
        panel.becomesKeyOnlyIfNeeded = false
        panel.delegate = self
        panel.contentView = self
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        _ = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [unowned self] e in key(e) ? nil : e }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(self)
        NSCursor.crosshair.set()
        // A foto entra igual à tela; só o escuro aparece, rápido.
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.duration = 0.15
        shade.layer?.add(fade, forKey: "fade")
        if let script = ProcessInfo.processInfo.environment["NIRI_SCREENSHOT_SCRIPT"] {
            play(script.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) })
        }
    }

    /// Teste sem mexer no mouse nem no teclado de verdade (`NIRI_SCREENSHOT_SCRIPT`): passos separados por `;`, um a
    /// cada 0,1 s, na fila de eventos da janela, como um clique de verdade. Pontos da tela, com y pra baixo.
    /// `drag x1 y1 x2 y2 ... [shift]` (passa por todos os pontos), `click x y`, `key [cmd+]<letra>` (`esc`, `return`),
    /// `type <texto>` (na caixa de texto aberta), `wait <s>`.
    private func play(_ steps: [String]) {
        guard let step = steps.first else { return }
        let word = step.split(separator: " ").map(String.init), n = word.dropFirst().compactMap(Double.init)
        let flags: NSEvent.ModifierFlags = word.last == "shift" ? .shift : []
        func post(_ e: NSEvent?) { if let e { NSApp.postEvent(e, atStart: false) } }
        func mouse(_ type: NSEvent.EventType, _ x: Double, _ y: Double) {
            post(.mouseEvent(with: type, location: CGPoint(x: x, y: bounds.height - y), modifierFlags: flags, timestamp: 0,
                             windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        func key(_ chars: String, _ code: Int, _ mods: NSEvent.ModifierFlags = []) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                post(.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: panel.windowNumber,
                               context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code)))
            }
        }
        var delay = 0.1
        switch word.first {
        case "drag" where n.count >= 4:
            let pts = stride(from: 0, to: n.count - 1, by: 2).map { CGPoint(x: n[$0], y: n[$0 + 1]) }
            mouse(.leftMouseDown, pts[0].x, pts[0].y)
            for (a, b) in zip(pts, pts.dropFirst()) {
                for i in 1...6 { mouse(.leftMouseDragged, a.x + (b.x - a.x) * Double(i) / 6, a.y + (b.y - a.y) * Double(i) / 6) }
            }
            mouse(.leftMouseUp, pts.last!.x, pts.last!.y)
        case "click" where n.count == 2:
            mouse(.leftMouseDown, n[0], n[1])
            mouse(.leftMouseUp, n[0], n[1])
        case "key" where word.count == 2:
            let k = word[1], cmd = k.hasPrefix("cmd+"), c = cmd ? String(k.dropFirst(4)) : k
            switch c {
            case "esc": key("\u{1b}", kVK_Escape)
            case "return": key("\r", kVK_Return)
            default: key(c, 0, cmd ? .command : [])
            }
        case "type":
            // Direto na caixa: tecla sintética passa pelo leiaute do teclado, que troca "á" pela letra da tecla 0.
            text?.insertText(String(step.dropFirst(5)), replacementRange: NSRange(location: NSNotFound, length: 0))
        case "wait": delay = n.first ?? delay
        default: log("print: passo de teste desconhecido '\(step)'")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.play(Array(steps.dropFirst())) }
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// ⌘ + tecla sem uso (⌘V fora da caixa de texto) chega aqui: sem o bip.
    override func keyDown(with event: NSEvent) {}

    /// Outro app pegou o teclado (⌘Tab, Spotlight): cancela, senão a foto ficaria por cima de tudo.
    func windowDidResignKey(_ notification: Notification) {
        if !finished { exit(0) }
    }

    // MARK: - Barra

    private func buildToolbar() {
        let content = Bar()
        var x: CGFloat = 7
        let h: CGFloat = 40
        func button(_ symbol: String, _ tip: String, _ action: Selector, width: CGFloat = 30) -> NSButton {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .medium)) ?? NSImage()
            let b = NSButton(image: image, target: self, action: action)
            b.isBordered = false
            b.toolTip = tip
            b.frame = CGRect(x: x, y: (h - 30) / 2, width: width, height: 30)
            b.wantsLayer = true
            b.layer?.cornerRadius = 8
            b.layer?.cornerCurve = .continuous
            b.contentTintColor = .labelColor
            content.addSubview(b)
            x += width + 2
            return b
        }
        func separator() {
            let s = NSView(frame: CGRect(x: x + 3, y: (h - 18) / 2, width: 1, height: 18))
            s.wantsLayer = true
            s.layer?.backgroundColor = NSColor.separatorColor.cgColor
            content.addSubview(s)
            x += 9
        }
        for t in Tool.allCases {
            let b = button(t.symbol, "\(t.title) (\(t.key.uppercased()))", #selector(pickTool(_:)))
            b.tag = Tool.allCases.firstIndex(of: t)!
            toolButtons[t] = b
        }
        separator()
        for (i, c) in Self.colors.enumerated() {
            let b = button("circle.fill", "Cor", #selector(pickColor(_:)), width: 22)
            b.tag = i
            b.image = Self.swatch(c, selected: false)
            swatches.append(b)
        }
        separator()
        _ = button("arrow.uturn.backward", "Desfazer (⌘Z)", #selector(undoButton))
        separator()
        _ = button("square.and.arrow.down", "Salvar em \(folder.lastPathComponent) (⌘S)", #selector(saveButton))
        _ = button("doc.on.doc", "Copiar (⌘C ou ↩)", #selector(copyButton))
        _ = button("xmark", "Cancelar (Esc)", #selector(cancelButton))
        content.frame = CGRect(x: 0, y: 0, width: x + 5, height: h)
        let glass = ClipboardPanel.glass(around: content, radius: h / 2, blending: .withinWindow)
        toolbar.frame = content.frame
        toolbar.addSubview(glass)
        // Escura como a barra do print do macOS: fica por cima da foto escurecida.
        toolbar.appearance = NSAppearance(named: .darkAqua)
        refreshToolbar()
    }

    private static func swatch(_ c: NSColor, selected: Bool) -> NSImage {
        NSImage(size: CGSize(width: 18, height: 18), flipped: false) { r in
            if selected {
                NSColor.white.setStroke()
                let ring = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
                ring.lineWidth = 1.5
                ring.stroke()
            }
            c.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: selected ? 4 : 3, dy: selected ? 4 : 3)).fill()
            NSColor.white.withAlphaComponent(0.35).setStroke()
            NSBezierPath(ovalIn: r.insetBy(dx: selected ? 4 : 3, dy: selected ? 4 : 3)).stroke()
            return true
        }
    }

    private func refreshToolbar() {
        for (t, b) in toolButtons {
            b.layer?.backgroundColor = t == tool ? NSColor.controlAccentColor.cgColor : nil
            b.contentTintColor = t == tool ? .white : .labelColor
        }
        for (i, b) in swatches.enumerated() { b.image = Self.swatch(Self.colors[i], selected: Self.colors[i] == color) }
    }

    @objc private func pickTool(_ b: NSButton) { choose(Tool.allCases[b.tag]) }
    @objc private func pickColor(_ b: NSButton) {
        color = Self.colors[b.tag]
        text?.textColor = color
        text?.insertionPointColor = color
        refreshToolbar()
    }
    @objc private func undoButton() { commitText(); undo() }
    @objc private func saveButton() { finish(save: true) }
    @objc private func copyButton() { finish(save: false) }
    @objc private func cancelButton() { exit(0) }

    /// A mesma de novo solta: arrastar volta a mexer na área.
    private func choose(_ t: Tool) {
        commitText()
        tool = tool == t ? nil : t
        refreshToolbar()
    }

    // MARK: - Teclado

    /// Esc fecha a caixa de texto e, sem ela, cancela. As letras escolhem a ferramenta, fora da caixa de texto.
    private func key(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        let chars = e.charactersIgnoringModifiers?.lowercased() ?? ""
        let code = Int(e.keyCode)
        if code == kVK_Escape {
            if text != nil { commitText() } else { exit(0) }
            return true
        }
        if mods.contains(.command) {
            switch chars {
            case "c": finish(save: false)
            case "s": finish(save: true)
            case "z":
                commitText()
                if mods.contains(.shift) { redo() } else { undo() }
            case "a" where text == nil:
                area.selectAll()
                update()
            default: return false
            }
            return true
        }
        guard text == nil else { return false }  // digitando
        if code == kVK_Return || code == kVK_ANSI_KeypadEnter {
            finish(save: false)
        } else if let t = Tool.allCases.first(where: { $0.key == chars }), mods.subtracting(.shift).isEmpty {
            choose(t)
        } else if let d = [kVK_LeftArrow: CGVector(dx: -1, dy: 0), kVK_RightArrow: CGVector(dx: 1, dy: 0),
                           kVK_UpArrow: CGVector(dx: 0, dy: -1), kVK_DownArrow: CGVector(dx: 0, dy: 1)][code], !area.isEmpty {
            // Seta move a área 1 pt; com Shift, 10.
            let k: CGFloat = mods.contains(.shift) ? 10 : 1
            area.drag(.inside, from: area.rect, by: CGVector(dx: d.dx * k, dy: d.dy * k))
            update()
        }
        return true  // sem o bip de tecla que ninguém usou
    }

    // MARK: - Mouse

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        commitText()
        // As alças valem com qualquer ferramenta; fora da área, arrastar escolhe outra.
        switch (area.grab(at: p, reach: 10), tool) {
        case (.handle(let h)?, _):
            gesture = .adjusting(.handle(h), area.rect, p)
        case (.inside?, .text?):
            return startText(at: p)
        case (.inside?, let tool?):
            gesture = .drawing(p)
            show(Mark(shape: shape(tool, from: p, to: p, shift: false), color: color, size: size))
        case (.inside?, nil):
            gesture = .adjusting(.inside, area.rect, p)
            NSCursor.closedHand.set()
        case (nil, _):
            gesture = .selecting(p)
        }
        update()
    }

    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        switch gesture {
        case .selecting(let start):
            area.select(from: start, to: p)
        case .adjusting(let grab, let start, let from):
            area.drag(grab, from: start, by: CGVector(dx: p.x - from.x, dy: p.y - from.y))
        case .drawing(let start):
            guard var m = current, let tool else { return }
            switch m.shape {
            case .pen(let pts): m.shape = .pen(pts + [p])
            case .marker(let pts): m.shape = .marker(pts + [p])
            default: m.shape = shape(tool, from: start, to: p, shift: e.modifierFlags.contains(.shift))
            }
            return show(m)
        case nil: return
        }
        update()
    }

    override func mouseUp(with e: NSEvent) {
        if case .drawing = gesture, let m = current {
            show(nil)
            if !bounds(of: m).isEmpty { add(m) }
        }
        gesture = nil
        update()
        cursor(at: convert(e.locationInWindow, from: nil))
    }

    override func mouseMoved(with e: NSEvent) { cursor(at: convert(e.locationInWindow, from: nil)) }

    /// A rolagem muda a espessura (e o tamanho da letra e do quadrado do pixelar), com um círculo do tamanho no mouse.
    override func scrollWheel(with e: NSEvent) {
        scrolled += e.scrollingDeltaY
        let step: CGFloat = e.hasPreciseScrollingDeltas ? 10 : 1
        guard abs(scrolled) >= step else { return }
        size = min(max(size + (scrolled > 0 ? 1 : -1), 1), 20)
        scrolled = 0
        if let text {
            text.font = textFont
            text.sizeToFit()
        }
        let p = convert(e.locationInWindow, from: nil), d = width(tool ?? .pen, size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hint.path = CGPath(ellipseIn: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d), transform: nil)
        hint.fillColor = color.withAlphaComponent(tool == .marker ? 0.4 : 1).cgColor
        hint.opacity = 1
        CATransaction.commit()
        hideHint?.cancel()
        hideHint = DispatchWorkItem { [weak self] in self?.hint.opacity = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: hideHint!)
    }

    private func cursor(at p: CGPoint) {
        guard gesture == nil else { return }
        if toolbar.isHidden == false && toolbar.frame.contains(p) { return NSCursor.arrow.set() }
        switch area.grab(at: p, reach: 10) {
        case .handle(let h):
            if #available(macOS 15, *) {
                let pos: NSCursor.FrameResizePosition = switch h {
                case .topLeft: .topLeft
                case .top: .top
                case .topRight: .topRight
                case .right: .right
                case .bottomRight: .bottomRight
                case .bottom: .bottom
                case .bottomLeft: .bottomLeft
                case .left: .left
                }
                NSCursor.frameResize(position: pos, directions: .all).set()
            } else {
                NSCursor.crosshair.set()
            }
        case .inside: (tool == nil ? NSCursor.openHand : tool == .text ? .iBeam : .crosshair).set()
        case nil: NSCursor.crosshair.set()
        }
    }

    // MARK: - Área

    private func update() {
        let r = area.rect, empty = area.isEmpty
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let full = CGMutablePath()
        full.addRect(bounds)
        if !empty { full.addRect(r) }
        dim.path = full
        outline.path = empty ? nil : CGPath(rect: r.insetBy(dx: -0.5, dy: -0.5), transform: nil)
        for (h, l) in zip(CaptureArea.Handle.allCases, handles) {
            l.position = h.point(in: r)
            l.isHidden = empty
        }
        // O tamanho em pixels, em cima do canto; sem espaço, dentro.
        let px = area.pixels
        let size = NSAttributedString(string: "\(Int(px.width)) × \(Int(px.height))", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white,
        ])
        label.string = size
        let w = size.size().width + 12
        let y = r.minY - 24 >= 4 ? r.minY - 24 : r.minY + 6
        labelBack.frame = CGRect(x: min(max(r.minX, 4), bounds.maxX - w - 4), y: y, width: w, height: 18)
        label.frame = CGRect(x: 0, y: 2, width: w, height: 15)
        labelBack.isHidden = empty
        ink.isHidden = empty
        ink.frame = r
        ink.layer?.sublayerTransform = CATransform3DMakeTranslation(-r.minX, -r.minY, 0)  // os desenhos estão em pontos da tela
        CATransaction.commit()
        // A barra só com a área parada.
        toolbar.isHidden = empty || gesture != nil
        if !toolbar.isHidden { toolbar.setFrameOrigin(area.toolbarOrigin(toolbar.frame.size, margin: 8)) }
    }

    // MARK: - Desenho

    private func width(_ t: Tool, _ size: CGFloat) -> CGFloat {
        switch t {
        case .marker: size * 4
        case .text: textSize(size)
        case .pixelate: max(6, size * 3)
        default: size
        }
    }

    private func textSize(_ size: CGFloat) -> CGFloat { 12 + size * 2 }
    private var textFont: NSFont { .systemFont(ofSize: textSize(size), weight: .semibold) }

    private func shape(_ t: Tool, from a: CGPoint, to b: CGPoint, shift: Bool) -> Mark.Shape {
        // Com Shift: linha e seta em múltiplos de 45°, retângulo quadrado.
        let dx = b.x - a.x, dy = b.y - a.y, len = hypot(dx, dy)
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        let straight = shift ? CGPoint(x: a.x + cos(angle) * len, y: a.y + sin(angle) * len) : b
        let side = max(abs(dx), abs(dy))
        let square = shift ? CGPoint(x: a.x + (dx < 0 ? -side : side), y: a.y + (dy < 0 ? -side : side)) : b
        let box = CGRect(x: min(a.x, square.x), y: min(a.y, square.y), width: abs(square.x - a.x), height: abs(square.y - a.y))
        switch t {
        case .pen: return .pen([a])
        case .marker: return .marker([a])
        case .line: return .line(a, straight)
        case .arrow: return .arrow(a, straight)
        case .rect: return .rect(box)
        case .pixelate: return .pixelate(box)
        case .text: return .text(NSAttributedString(), a)
        }
    }

    /// Onde o desenho pinta, com folga pra ponta da seta e o arredondado do traço. Vazio: não desenhou nada.
    private func bounds(of m: Mark) -> CGRect {
        let pad = m.size * 4 + 4
        switch m.shape {
        case .pen(let pts), .marker(let pts):
            let xs = pts.map(\.x), ys = pts.map(\.y)
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!).insetBy(dx: -pad, dy: -pad)
        case .line(let a, let b), .arrow(let a, let b):
            return a == b ? .null : CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)).insetBy(dx: -pad, dy: -pad)
        case .rect(let r):
            return r.width < 1 || r.height < 1 ? .null : r.insetBy(dx: -pad, dy: -pad)
        case .pixelate(let r):
            return r.width < 1 || r.height < 1 ? .null : r
        case .text(let s, let p):
            return CGRect(origin: p, size: s.size()).insetBy(dx: -2, dy: -2)  // a letra pode passar um pouco da caixa
        }
    }

    /// Na tela, cada desenho é uma camada: o traço é do Core Animation, sem bitmap do tamanho da área (desenhando numa
    /// view, o primeiro traço levava o editor de 17 a ~220 MB, medido). Texto e pixelado viram uma imagem do tamanho
    /// deles, feita pelo mesmo `draw` do arquivo.
    private func layer(for m: Mark) -> CALayer {
        func stroke(_ path: CGPath, _ width: CGFloat, join: CAShapeLayerLineJoin = .round) -> CAShapeLayer {
            let l = CAShapeLayer()
            l.path = path
            l.strokeColor = m.color.cgColor
            l.fillColor = nil
            l.lineWidth = width
            l.lineCap = .round
            l.lineJoin = join
            return l
        }
        switch m.shape {
        case .pen(let pts):
            return stroke(Self.smooth(pts), m.size)
        case .marker(let pts):
            let l = stroke(Self.smooth(pts), width(.marker, m.size))
            l.opacity = 0.4
            return l
        case .line(let a, let b):
            return stroke(Self.smooth([a, b]), m.size)
        case .rect(let r):
            return stroke(CGPath(rect: r, transform: nil), m.size, join: .miter)
        case .arrow(let a, let b):
            guard let (shaft, head) = Self.arrow(a, b, m.size) else { return CALayer() }
            let l = stroke(shaft, m.size), tip = CAShapeLayer()
            tip.path = head
            tip.fillColor = m.color.cgColor
            l.addSublayer(tip)
            return l
        case .pixelate(let r):
            let l = CALayer()
            guard let (img, px) = pixelated(r, block: width(.pixelate, m.size)) else { return l }
            l.contents = img
            l.magnificationFilter = .nearest
            l.frame = CGRect(x: px.minX / area.scale, y: px.minY / area.scale, width: px.width / area.scale, height: px.height / area.scale)
            return l
        case .text:
            let l = CALayer(), box = bounds(of: m).integral
            let w = Int(box.width * area.scale), h = Int(box.height * area.scale)
            guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                     bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return l }
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: area.scale, y: -area.scale)
            ctx.translateBy(x: -box.minX, y: -box.minY)
            draw(m, in: ctx)
            l.contents = ctx.makeImage()
            l.frame = box
            return l
        }
    }

    /// O desenho em andamento na tela (nil tira).
    private func show(_ m: Mark?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        currentLayer?.removeFromSuperlayer()
        current = m
        currentLayer = m.map(layer(for:))
        if let currentLayer { ink.layer?.addSublayer(currentLayer) }
        CATransaction.commit()
    }

    /// O traço da seta até a base da ponta (a ponta redonda do traço fica dentro do triângulo) e o triângulo da ponta.
    private static func arrow(_ a: CGPoint, _ b: CGPoint, _ size: CGFloat) -> (shaft: CGPath, head: CGPath)? {
        let len = hypot(b.x - a.x, b.y - a.y)
        guard len > 0 else { return nil }
        let head = min(len, max(10, size * 3.5)), ux = (b.x - a.x) / len, uy = (b.y - a.y) / len
        let base = CGPoint(x: b.x - ux * head, y: b.y - uy * head)
        let tip = CGMutablePath()
        tip.addLines(between: [b, CGPoint(x: base.x - uy * head * 0.55, y: base.y + ux * head * 0.55),
                               CGPoint(x: base.x + uy * head * 0.55, y: base.y - ux * head * 0.55)])
        tip.closeSubpath()
        return (smooth([a, base]), tip)
    }

    /// Em pontos, com y pra baixo: o arquivo (`render`) e a imagem do texto na tela (`layer`).
    private func draw(_ m: Mark, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(m.color.cgColor)
        ctx.setFillColor(m.color.cgColor)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(m.size)
        switch m.shape {
        case .pen(let pts):
            ctx.addPath(Self.smooth(pts))
            ctx.strokePath()
        case .marker(let pts):
            // Um traço só, transparente por inteiro: onde ele passa duas vezes não escurece.
            ctx.setAlpha(0.4)
            ctx.setLineWidth(width(.marker, m.size))
            ctx.addPath(Self.smooth(pts))
            ctx.strokePath()
        case .line(let a, let b):
            ctx.addPath(Self.smooth([a, b]))
            ctx.strokePath()
        case .arrow(let a, let b):
            guard let (shaft, head) = Self.arrow(a, b, m.size) else { return }
            ctx.addPath(shaft)
            ctx.strokePath()
            ctx.addPath(head)
            ctx.fillPath()
        case .rect(let r):
            ctx.setLineJoin(.miter)
            ctx.stroke(r)
        case .text(let s, let p):
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            s.draw(at: p)
            NSGraphicsContext.restoreGraphicsState()
        case .pixelate(let r):
            guard let (img, px) = pixelated(r, block: width(.pixelate, m.size)) else { return }
            // A imagem desenha de cabeça pra baixo num contexto com y pra baixo: desvira só ela.
            let rect = CGRect(x: px.minX / area.scale, y: px.minY / area.scale, width: px.width / area.scale, height: px.height / area.scale)
            ctx.interpolationQuality = .none
            ctx.translateBy(x: rect.minX, y: rect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(img, in: CGRect(origin: .zero, size: rect.size))
        }
    }

    /// A foto embaixo de `r` reduzida a um quadrado por bloco de `block` pt (a média das cores dele), pra desenhar
    /// ampliada sem suavizar. Usa só a foto: o que foi desenhado antes embaixo some junto.
    private func pixelated(_ r: CGRect, block: CGFloat) -> (CGImage, CGRect)? {
        let px = CGRect(x: r.minX * area.scale, y: r.minY * area.scale, width: r.width * area.scale, height: r.height * area.scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: photo.width, height: photo.height))
        guard !px.isEmpty, let crop = photo.cropping(to: px) else { return nil }
        let cols = max(1, Int((px.width / (block * area.scale)).rounded(.up))), rows = max(1, Int((px.height / (block * area.scale)).rounded(.up)))
        guard let small = CGContext(data: nil, width: cols, height: rows, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: photo.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        small.interpolationQuality = .high
        small.draw(crop, in: CGRect(x: 0, y: 0, width: cols, height: rows))
        return small.makeImage().map { ($0, px) }
    }

    /// O traço passa pelo meio entre os pontos do mouse, em curva: sem as quinas de ligar ponto a ponto.
    private static func smooth(_ pts: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        if pts.count < 3 {
            path.addLine(to: pts.last!)  // um clique só vira um ponto (a ponta redonda de um traço de tamanho zero)
            return path
        }
        for i in 1..<pts.count - 1 {
            path.addQuadCurve(to: CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2), control: pts[i])
        }
        path.addLine(to: pts.last!)
        return path
    }

    private func add(_ m: Mark) {
        let l = layer(for: m)
        marks.append((m, l))
        undone.removeAll()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ink.layer?.addSublayer(l)
        CATransaction.commit()
    }

    private func undo() {
        guard let m = marks.popLast() else { return }
        undone.append(m)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        m.layer.removeFromSuperlayer()
        CATransaction.commit()
    }

    private func redo() {
        guard let m = undone.popLast() else { return }
        marks.append(m)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ink.layer?.addSublayer(m.layer)
        CATransaction.commit()
    }

    // MARK: - Texto

    private func startText(at p: CGPoint) {
        let t = NSTextView(frame: CGRect(x: p.x - 4, y: p.y - textFont.boundingRectForFont.height / 2, width: 20, height: 20))
        t.font = textFont
        t.textColor = color
        t.insertionPointColor = color
        t.drawsBackground = false
        t.isRichText = false
        t.allowsUndo = true
        t.textContainerInset = CGSize(width: 3, height: 2)
        t.textContainer?.lineFragmentPadding = 0
        t.textContainer?.widthTracksTextView = false
        t.textContainer?.containerSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        t.isHorizontallyResizable = true
        t.isVerticallyResizable = true
        t.minSize = CGSize(width: 24, height: 0)
        t.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        t.delegate = self
        t.wantsLayer = true
        t.layer?.borderWidth = 1
        t.layer?.borderColor = NSColor.white.withAlphaComponent(0.6).cgColor
        t.layer?.cornerRadius = 3
        addSubview(t, positioned: .below, relativeTo: toolbar)
        t.sizeToFit()
        panel.makeFirstResponder(t)
        text = t
    }

    func textDidChange(_ notification: Notification) { text?.sizeToFit() }

    /// A caixa de texto vira desenho; vazia, some.
    private func commitText() {
        guard let t = text else { return }
        text = nil
        t.removeFromSuperview()
        panel.makeFirstResponder(self)
        let s = t.attributedString()
        guard !s.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        add(Mark(shape: .text(s, CGPoint(x: t.frame.minX + t.textContainerInset.width, y: t.frame.minY + t.textContainerInset.height)),
                 color: color, size: size))
    }

    // MARK: - Copiar e salvar

    /// Sem área escolhida, vale a tela toda. A janela sai antes de gerar o PNG (~100 a 300 ms numa tela Retina).
    private func finish(save: Bool) {
        commitText()
        if area.isEmpty { area.selectAll() }
        guard let img = render() else { exit(1) }
        finished = true
        panel.orderOut(nil)
        CATransaction.flush()
        try? FileHandle.standardOutput.write(contentsOf: Data("done\n".utf8))  // o niri-os volta a ter os atalhos
        guard let png = Self.png(img, dpi: 72 * area.scale) else { exit(1) }
        guard save else { copy(png) }
        let fm = FileManager.default
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stamp = format.string(from: .now)
        var url = folder.appendingPathComponent("Screenshot \(stamp).png"), n = 2
        while fm.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("Screenshot \(stamp) (\(n)).png")
            n += 1
        }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
            toast(img, "Salvo em \(fm.displayName(atPath: folder.path))", url.lastPathComponent, reveal: url)
        } catch {
            // Não perde o print: vai pro clipboard.
            log("print: não salvei em \(folder.path): \(error.localizedDescription)")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(png, forType: .png)
            toast(img, "Não salvei em \(fm.displayName(atPath: folder.path))", "Copiado pro clipboard", reveal: nil)
        }
    }

    private func copy(_ png: Data) -> Never {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
        exit(0)
    }

    /// A área em pixels da foto, com os desenhos por cima. Sem desenho, o recorte da foto como está.
    private func render() -> CGImage? {
        let px = area.pixels
        guard let crop = photo.cropping(to: px) else { return nil }
        guard !marks.isEmpty else { return crop }
        let w = Int(px.width), h = Int(px.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: photo.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Os desenhos estão em pontos da tela, com y pra baixo.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: area.scale, y: -area.scale)
        ctx.translateBy(x: -area.rect.minX, y: -area.rect.minY)
        for m in marks { draw(m.mark, in: ctx) }
        return ctx.makeImage()
    }

    /// Com a densidade da tela, como o print do macOS: num documento, ele entra no tamanho em que estava na tela.
    private static func png(_ img: CGImage, dpi: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// O aviso no canto de baixo da tela, como a miniatura do print do macOS: clique mostra no Finder. Sai em 3 s.
    private func toast(_ img: CGImage, _ title: String, _ detail: String, reveal: URL?) {
        let thumb = CGSize(width: 64, height: max(24, min(64, 64 * CGFloat(img.height) / CGFloat(img.width))))
        let content = Toast(frame: CGRect(x: 0, y: 0, width: 300, height: thumb.height + 24))
        content.reveal = reveal
        let image = NSImageView(frame: CGRect(x: 12, y: 12, width: thumb.width, height: thumb.height))
        image.image = NSImage(cgImage: img, size: .zero)
        image.imageScaling = .scaleProportionallyUpOrDown
        image.wantsLayer = true
        image.layer?.cornerRadius = 4
        image.layer?.masksToBounds = true
        let titleLabel = NSTextField(labelWithString: title), detailLabel = NSTextField(labelWithString: detail)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        let x = thumb.width + 24, mid = content.frame.height / 2
        titleLabel.frame = CGRect(x: x, y: mid, width: 300 - x - 12, height: 17)
        detailLabel.frame = CGRect(x: x, y: mid - 17, width: 300 - x - 12, height: 15)
        for v in [image, titleLabel, detailLabel] { content.addSubview(v) }
        let panel = Panel(contentRect: CGRect(x: visible.maxX - 300 - 16, y: visible.minY + 16, width: 300, height: content.frame.height),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = ClipboardPanel.glass(around: content, radius: 16)
        panel.orderFrontRegardless()
        Self.toastPanel = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
    }

    private static var toastPanel: NSPanel?

    private final class Toast: NSView {
        var reveal: URL?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            if let reveal { NSWorkspace.shared.activateFileViewerSelecting([reveal]) }
            exit(0)
        }
    }
}
