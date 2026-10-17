import AppKit
import Carbon.HIToolbox
import ImageIO
import NiriCore

/// A janela do Option+V, num processo só dela (`niri-os --clipboard <x> <y>`, aberto por `Clipboard`): pesquisa no
/// topo, fixados e recentes em cartões, com o canto no mouse. Recebe a lista pelo stdin, uma linha de JSON por versão,
/// manda os pedidos pelo stdout e sai ao fechar.
///
/// Não ativa o processo (`nonactivatingPanel`, como o Spotlight): o app da frente continua o mesmo, e o Cmd+V do colar
/// cai nele.
final class ClipboardPanel: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private static let width = 380.0, inset = 8.0, searchHeight = 46.0, hintHeight = 30.0, maxHeight = 540.0
    private static let hintText = "↩ colar    ⌘P fixar    ⌘⌫ apagar    esc fechar"

    private var list: ClipboardList
    private let window = Window(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let root = Flipped()
    private let search = NSTextField(string: "")
    private let scroll = OverlayScroll()
    private let doc = Flipped()
    private let hint = label(hintText, size: 11, color: .tertiaryLabelColor)
    private let empty = label("", size: 13, color: .secondaryLabelColor)
    private let pinnedHeader = label("", size: 11, color: .secondaryLabelColor, weight: .semibold)
    private let recentHeader = label("RECENTES", size: 11, color: .secondaryLabelColor, weight: .semibold)
    /// Todos os cartões, fixados primeiro; `shown` são os que passam na pesquisa.
    private var cards: [Card] = []
    private var shown: [Card] = []
    private var selected: String?
    private var keys: Any?
    /// A imagem grande do clique direito, aberta.
    private var preview: Preview?

    /// A borderless não vira janela do teclado sem isso.
    final class Window: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    /// O processo do painel: espera a primeira lista no stdin e abre a janela; as seguintes (cópia nova) atualizam.
    static func run(at mouse: NSPoint) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // Sem menu, os atalhos de texto não chegam na pesquisa.
        let edit = NSMenu()
        edit.addItem(withTitle: "Desfazer", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Recortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Colar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Selecionar tudo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        app.mainMenu = NSMenu()
        app.mainMenu!.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = edit
        var panel: ClipboardPanel?, buffer = Data()
        FileHandle.standardInput.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty { exit(0) }  // o niri-os saiu
            // A lista passa de 64 KB (o pipe) com textos grandes: chega em pedaços até o fim da linha.
            buffer.append(data)
            guard let end = buffer.lastIndex(of: UInt8(ascii: "\n")) else { return }
            let last = buffer[..<end].split(separator: UInt8(ascii: "\n")).last
            buffer.removeSubrange(...end)
            guard let last, let list = try? JSONDecoder().decode(ClipboardList.self, from: Data(last)) else { return }
            DispatchQueue.main.async {
                if let panel { panel.reload(list) } else { panel = ClipboardPanel(list, at: mouse) }
            }
        }
        app.run()
        exit(0)
    }

    private init(_ list: ClipboardList, at mouse: NSPoint) {
        self.list = list
        super.init()
        window.isFloatingPanel = true
        window.level = .popUpMenu
        window.becomesKeyOnlyIfNeeded = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.acceptsMouseMovedEvents = true
        window.delegate = self

        let w = Self.width
        let icon = NSImageView(frame: NSRect(x: 16, y: (Self.searchHeight - 18) / 2, width: 18, height: 18))
        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        icon.contentTintColor = .secondaryLabelColor
        search.frame = NSRect(x: 42, y: (Self.searchHeight - 22) / 2, width: w - 42 - 16, height: 22)
        search.isBezeled = false
        search.drawsBackground = false
        search.focusRingType = .none
        search.font = .systemFont(ofSize: 15)
        search.placeholderString = "Pesquisar"
        search.cell?.usesSingleLineMode = true
        search.delegate = self
        let line = NSBox(frame: NSRect(x: 0, y: Self.searchHeight, width: w, height: 1))
        line.boxType = .separator
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = doc
        for v in [pinnedHeader, recentHeader] { doc.addSubview(v) }
        empty.alignment = .center
        for v in [icon, search, line, scroll, empty, hint] { root.addSubview(v) }

        // Altura pelo conteúdo de agora, e fixa enquanto aberta: a janela não pula enquanto a pesquisa filtra.
        scroll.frame.size.width = w
        rebuild()
        let content = max(doc.frame.height, 90)
        let h = min(Self.maxHeight, Self.searchHeight + 1 + content + Self.hintHeight)
        root.frame = NSRect(x: 0, y: 0, width: w, height: h)
        scroll.frame = NSRect(x: 0, y: Self.searchHeight + 1, width: w, height: h - Self.searchHeight - 1 - Self.hintHeight)
        empty.frame = NSRect(x: 0, y: scroll.frame.midY - 9, width: w, height: 18)
        hint.frame = NSRect(x: 16, y: h - Self.hintHeight + 7, width: w - 32, height: 16)
        layoutCards()

        // ⌘P e ⌘⌫ valem pro cartão escolhido, mesmo com o teclado na pesquisa. Com a imagem grande aberta, Esc fecha só ela.
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [unowned self] e in
            if preview != nil, Int(e.keyCode) == kVK_Escape { closePreview(); return nil }
            guard e.modifierFlags.contains(.command), let id = selected else { return e }
            if e.charactersIgnoringModifiers == "p" { act(.pin, id); return nil }
            if Int(e.keyCode) == kVK_Delete { act(.delete, id); return nil }
            return e
        }

        window.contentView = Self.glass(around: root)
        // O canto de cima à esquerda no mouse, dentro da tela dele.
        let vis = (NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.screens[0]).visibleFrame
        let x = min(max(mouse.x, vis.minX + 8), vis.maxX - w - 8)
        let y = min(max(mouse.y - h, vis.minY + 8), vis.maxY - h - 8)
        window.setFrame(NSRect(x: x, y: y, width: w, height: h), display: false)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(search)
        // A sombra é calculada no primeiro quadro, ainda transparente pelo fade: recalculada com o vidro já na tela.
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.window.invalidateShadow() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.duration = 0.12
        window.contentView?.layer?.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    /// Vidro do Tahoe; antes dele, o desfoque do vidro do resize. `blending`: `.withinWindow` desfoca o que a própria
    /// janela desenha embaixo (a foto congelada do print, ver `ScreenshotEditor`).
    static func glass(around content: NSView, radius: CGFloat = 22, blending: NSVisualEffectView.BlendingMode = .behindWindow) -> NSView {
        if #available(macOS 26, *) {
            let g = NSGlassEffectView(frame: content.frame)
            g.wantsLayer = true
            g.cornerRadius = radius
            g.contentView = content
            // Recortado nos cantos: o vidro é desenhado pelo servidor de janelas, e sem isso a sombra da janela saía do
            // retângulo inteiro, uma linha quadrada em volta dos cantos arredondados.
            g.layer?.cornerRadius = radius
            g.layer?.cornerCurve = .continuous
            g.layer?.masksToBounds = true
            return g
        }
        let v = NSVisualEffectView(frame: content.frame)
        v.material = .hudWindow
        v.blendingMode = blending
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = radius
        v.layer?.cornerCurve = .continuous
        v.layer?.masksToBounds = true
        v.addSubview(content)
        return v
    }

    /// Clique fora (outro app, outra janela) fecha.
    func windowDidResignKey(_ notification: Notification) { exit(0) }

    private func tell(_ line: String) { try? FileHandle.standardOutput.write(contentsOf: Data((line + "\n").utf8)) }

    /// Cópia nova com o painel aberto.
    private func reload(_ list: ClipboardList) {
        self.list = list
        rebuild()
    }

    // MARK: - Cartões

    private func rebuild() {
        cards.forEach { $0.removeFromSuperview() }
        cards = (list.items.filter(\.pinned) + list.items.filter { !$0.pinned }).map { item in
            let c = Card(item, thumbnail: item.text == nil ? Self.thumbnail(item.id) : nil, width: Self.width - 2 * Self.inset)
            c.action = { [unowned self] in act($0, $1) }
            doc.addSubview(c)
            return c
        }
        filter()
    }

    private func filter() {
        let matches = Set(list.search(search.stringValue).map(\.id))
        shown = cards.filter { matches.contains($0.id) }
        for c in cards { c.isHidden = !matches.contains(c.id) }
        if !shown.contains(where: { $0.id == selected }) { selected = shown.first?.id }
        layoutCards()
    }

    private func layoutCards() {
        var y = 4.0
        func place(_ header: NSTextField, _ group: [Card]) {
            header.isHidden = group.isEmpty
            guard !group.isEmpty else { return }
            header.frame = NSRect(x: Self.inset + 8, y: y + 6, width: 200, height: 14)
            y += 26
            for c in group {
                c.frame.origin = NSPoint(x: Self.inset, y: y)
                y += c.frame.height + 6
            }
        }
        pinnedHeader.stringValue = "FIXADOS  \(list.pinnedCount)/\(ClipboardList.maxPinned)"
        place(pinnedHeader, shown.filter(\.pinned))
        place(recentHeader, shown.filter { !$0.pinned })
        doc.frame = NSRect(x: 0, y: 0, width: Self.width, height: max(y + 2, scroll.contentSize.height))
        empty.isHidden = !shown.isEmpty
        empty.stringValue = list.items.isEmpty ? "Nada copiado ainda" : "Nada encontrado"
        for c in cards { c.selected = c.id == selected }
    }

    private func select(_ id: String, reveal: Bool = false) {
        selected = id
        for c in cards { c.selected = c.id == id }
        guard reveal, let c = cards.first(where: { $0.id == id }) else { return }
        // O primeiro mostra o título da seção junto.
        if c === shown.first { doc.scroll(.zero) } else { doc.scrollToVisible(c.frame.insetBy(dx: 0, dy: -Self.inset)) }
    }

    /// Fixar e apagar mudam a lista daqui e pedem o mesmo ao niri-os, que aplica igual (`ClipboardList`).
    private func act(_ a: Card.Action, _ id: String) {
        switch a {
        case .hover: select(id)
        case .preview:
            select(id)
            guard let data = Clipboard.load(id), let bytes = Clipboard.imageTypes.lazy.compactMap({ data[$0.rawValue] }).first,
                  let image = NSImage(data: bytes) else { return }
            preview = Preview(image, on: window.screen ?? NSScreen.screens[0]) { [unowned self] in closePreview() }
        case .paste:
            // Escrito daqui, que sai em seguida: o NSPasteboard guarda os buffers de quem escreve (ver `Clipboard`).
            guard let data = Clipboard.load(id) else { return flash("Essa cópia sumiu do disco") }
            let item = NSPasteboardItem()
            for t in Clipboard.textTypes + Clipboard.imageTypes { if let d = data[t.rawValue] { item.setData(d, forType: t) } }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([item])
            // O teclado volta pro app antes do Cmd+V do niri-os. Sem o delegate: perder o teclado fecha o processo na hora.
            window.delegate = nil
            window.orderOut(nil)
            tell("paste \(id) \(pb.changeCount)")
            exit(0)
        case .pin:
            let pin = !(list.items.first { $0.id == id }?.pinned ?? true)
            guard list.setPinned(id, pin).ok else { return flash("Já tem \(ClipboardList.maxPinned) fixados: desafixe um antes") }
            tell("\(pin ? "pin" : "unpin") \(id)")
            selected = id
            rebuild()
        case .delete:
            // A escolha passa pra que estava embaixo.
            let i = shown.firstIndex { $0.id == id } ?? 0
            list.remove(id)
            tell("delete \(id)")
            selected = nil
            rebuild()
            if !shown.isEmpty { select(shown[min(i, shown.count - 1)].id) }
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        filter()
        doc.scroll(.zero)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)):
            guard let i = shown.firstIndex(where: { $0.id == selected }) else { break }
            let d = selector == #selector(NSResponder.moveUp(_:)) ? -1 : 1
            select(shown[min(max(i + d, 0), shown.count - 1)].id, reveal: true)
        case #selector(NSResponder.insertNewline(_:)):
            if let selected { act(.paste, selected) }
        case #selector(NSResponder.cancelOperation(_:)):
            guard !search.stringValue.isEmpty else { exit(0) }
            search.stringValue = ""
            filter()
        default: return false
        }
        return true
    }

    private func closePreview() {
        preview?.orderOut(nil)
        preview = nil
    }

    private func flash(_ text: String) {
        hint.stringValue = text
        hint.textColor = .systemOrange
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.hint.stringValue = Self.hintText
            self?.hint.textColor = .tertiaryLabelColor
        }
    }

    /// A miniatura fica em disco ao lado da cópia: só a primeira abertura depois de copiar decodifica a imagem inteira.
    /// Feita aqui, e não na cópia: o ImageIO no niri-os custava +3 MB que ficavam.
    private static func thumbnail(_ id: String) -> NSImage? {
        let url = Clipboard.file(id, "thumbnail.png")
        if let image = NSImage(contentsOf: url) { return image }
        guard let data = Clipboard.load(id), let image = Clipboard.imageTypes.lazy.compactMap({ data[$0.rawValue] }).first,
              let src = CGImageSourceCreateWithData(image as CFData, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                                                        kCGImageSourceThumbnailMaxPixelSize: 720] as CFDictionary)
        else { return nil }
        if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, thumb, nil)
            CGImageDestinationFinalize(dest)
        }
        return NSImage(cgImage: thumb, size: .zero)
    }

    static func label(_ s: String, size: Double, color: NSColor, weight: NSFont.Weight = .regular) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.lineBreakMode = .byTruncatingTail
        return l
    }
}

private final class Flipped: NSView {
    override var isFlipped: Bool { true }
}

/// Sempre a barra fina por cima do conteúdo, a do trackpad. Com mouse ligado o macOS troca pela que ocupa 15 pt, e ela
/// cortava a borda direita dos cartões.
private final class OverlayScroll: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set {}
    }
}

/// A imagem grande do clique direito: a tela escurecida e a imagem no meio, no tamanho real até 85% da tela. Não vira
/// janela do teclado: o painel continua com ele (perder o teclado fecha o painel), e o Esc chega lá. Clique fora da
/// imagem fecha, e o clique não chega no app de baixo.
private final class Preview: NSPanel {
    private let onClose: () -> Void
    private var imageFrame = NSRect.zero

    init(_ image: NSImage, on screen: NSScreen, onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .popUpMenu  // o mesmo do painel, e na frente dele
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = NSColor.black.withAlphaComponent(0.4)
        isOpaque = false
        hasShadow = false
        // Pixels da imagem em pt da tela: um print Retina aparece do tamanho que tinha na tela.
        let px = image.representations.first.map { NSSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? image.size
        let native = NSSize(width: px.width / screen.backingScaleFactor, height: px.height / screen.backingScaleFactor)
        let vis = screen.visibleFrame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        let scale = min(1, vis.width * 0.85 / max(native.width, 1), (vis.height - 30) * 0.85 / max(native.height, 1))
        let size = NSSize(width: native.width * scale, height: native.height * scale)
        imageFrame = NSRect(x: vis.midX - size.width / 2, y: vis.midY - size.height / 2 + 12, width: size.width, height: size.height)
        let view = NSImageView(frame: imageFrame)
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown
        view.wantsLayer = true
        view.layer?.cornerRadius = 10
        view.layer?.masksToBounds = true
        let caption = ClipboardPanel.label("\(Int(px.width)) × \(Int(px.height)) px    esc ou clique fora fecha", size: 12,
                                           color: NSColor.white.withAlphaComponent(0.7))
        caption.alignment = .center
        caption.frame = NSRect(x: vis.minX, y: imageFrame.minY - 28, width: vis.width, height: 16)
        contentView = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        contentView?.wantsLayer = true
        contentView?.addSubview(view)
        contentView?.addSubview(caption)
        orderFrontRegardless()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.duration = 0.12
        contentView?.layer?.add(fade, forKey: "fade")
    }

    override var canBecomeKey: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if [.leftMouseDown, .rightMouseDown].contains(event.type), !imageFrame.contains(event.locationInWindow) { return onClose() }
        super.sendEvent(event)
    }
}

/// Uma cópia: o texto (até 3 linhas) ou a miniatura, e embaixo o app e quando. No canto, o alfinete (sempre visível no
/// fixado) e o x de apagar, os dois no cartão escolhido.
private final class Card: NSView {
    enum Action { case hover, paste, pin, delete, preview }
    let id: String, pinned: Bool, image: Bool
    var action: ((Action, String) -> Void)?
    var selected = false {
        didSet {
            guard selected != oldValue else { return }
            pin.isHidden = !pinned && !selected
            remove.isHidden = !selected
            needsDisplay = true
        }
    }
    private let pin: NSButton, remove: NSButton

    init(_ item: ClipboardList.Item, thumbnail: NSImage?, width: Double) {
        id = item.id
        pinned = item.pinned
        image = item.text == nil
        pin = Self.button(item.pinned ? "pin.fill" : "pin", tip: item.pinned ? "Desafixar (⌘P)" : "Fixar (⌘P)")
        remove = Self.button("xmark", tip: "Apagar (⌘⌫)")
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 0))
        let pad = 12.0, inner = width - 2 * pad - 44  // 44: os dois botões
        var y = 10.0
        if let text = item.text {
            let l = NSTextField(wrappingLabelWithString: String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400)))
            l.font = .systemFont(ofSize: 13)
            l.maximumNumberOfLines = 3
            l.cell?.truncatesLastVisibleLine = true
            let h = l.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: inner, height: 1000)).height
            l.frame = NSRect(x: pad, y: y, width: inner, height: h)
            addSubview(l)
            y += h
        } else {
            let s = thumbnail?.size ?? NSSize(width: 16, height: 9), aspect = s.height / max(s.width, 1)
            let h = min(96, inner * aspect), v = NSImageView(frame: NSRect(x: pad, y: y + 2, width: h / aspect, height: h))
            v.image = thumbnail
            v.imageScaling = .scaleProportionallyUpOrDown
            v.wantsLayer = true
            v.layer?.cornerRadius = 6
            v.layer?.masksToBounds = true
            addSubview(v)
            y += h + 2
        }
        let meta = ClipboardPanel.label([item.text == nil ? "Imagem" : nil, item.app, Self.ago(item.date)].compactMap { $0 }.joined(separator: " · "),
                                        size: 11, color: .secondaryLabelColor)
        meta.frame = NSRect(x: pad, y: y + 4, width: inner, height: 14)
        addSubview(meta)
        frame.size.height = y + 4 + 14 + 9
        pin.frame = NSRect(x: width - pad - 42, y: 7, width: 20, height: 20)
        remove.frame = NSRect(x: width - pad - 20, y: 7, width: 20, height: 20)
        if pinned { pin.contentTintColor = .controlAccentColor }
        pin.isHidden = !pinned
        remove.isHidden = true
        pin.target = self
        pin.action = #selector(pinClicked)
        remove.target = self
        remove.action = #selector(removeClicked)
        addSubview(pin)
        addSubview(remove)
        if image { toolTip = "Clique direito: ver maior" }
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    /// Aqui as cores dinâmicas resolvem pro modo da tela (claro ou escuro).
    override func updateLayer() {
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = (selected ? NSColor.controlAccentColor.withAlphaComponent(0.3) : NSColor.labelColor.withAlphaComponent(0.06)).cgColor
        layer?.borderWidth = selected ? 1 : 0
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
    }

    /// Clique em qualquer lugar do cartão (fora dos botões) é dele, não do texto.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        return v is NSButton ? v : v == nil ? nil : self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // Só com o mouse andando: com `mouseEntered`, a lista rolando pelo teclado passava por baixo do mouse parado
        // e roubava a escolha.
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { if !selected { action?(.hover, id) } }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?(.paste, id) }
    }

    override func rightMouseDown(with event: NSEvent) { if image { action?(.preview, id) } }

    @objc private func pinClicked() { action?(.pin, id) }
    @objc private func removeClicked() { action?(.delete, id) }

    private static func button(_ symbol: String, tip: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium)) ?? NSImage()
        let b = NSButton(image: image, target: nil, action: nil)
        b.isBordered = false
        b.refusesFirstResponder = true  // o teclado fica na pesquisa
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = tip
        return b
    }

    private static func ago(_ date: Date) -> String {
        let s = Int(-date.timeIntervalSinceNow)
        switch s {
        case ..<60: return "agora"
        case ..<3600: return "há \(s / 60) min"
        case ..<86400: return "há \(s / 3600) h"
        case ..<172_800: return "ontem"
        default: return "há \(s / 86400) dias"
        }
    }
}
