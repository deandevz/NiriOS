import AppKit

/// O seletor do Option Tab (ver `WindowManager.switchFloating`), como o Cmd+Tab do macOS: o ícone do app de cada item no
/// meio da tela, o escolhido marcado e com o nome embaixo. Uma janela nossa, criada no 1º uso e reaproveitada: fechada,
/// fica fora da tela e nada roda. Só camadas (sem view por ícone).
final class Switcher {
    struct Item {
        let icon: NSImage?
        let name: String
    }

    private static let icon = 64.0, cell = 88.0, pad = 18.0, labelHeight = 26.0
    private let panel: NSPanel
    private let effect = NSVisualEffectView()
    private let highlight = CALayer(), label = CATextLayer()
    private var icons: [CALayer] = []
    private var names: [String] = []

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu  // por cima das janelas e do vidro do resize
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 22
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        panel.contentView = effect
        highlight.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        highlight.cornerRadius = 14
        highlight.cornerCurve = .continuous
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.fontSize = 13
        label.foregroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
        label.alignmentMode = .center
        label.truncationMode = .end
        effect.layer?.addSublayer(highlight)
        effect.layer?.addSublayer(label)
    }

    var isShown: Bool { panel.isVisible }

    func show(_ items: [Item], selected: Int) {
        let screen = NSScreen.screens[0], scale = screen.backingScaleFactor
        let w = Double(items.count) * Self.cell + 2 * Self.pad, h = Self.cell + Self.labelHeight + 2 * Self.pad
        panel.setFrame(CGRect(x: screen.frame.midX - w / 2, y: screen.frame.midY - h / 2, width: w, height: h), display: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        icons.forEach { $0.removeFromSuperlayer() }
        icons = items.enumerated().map { i, item in
            let l = CALayer()
            let inset = (Self.cell - Self.icon) / 2
            l.frame = CGRect(x: Self.pad + Double(i) * Self.cell + inset, y: Self.pad + Self.labelHeight + inset, width: Self.icon, height: Self.icon)
            var r = CGRect(x: 0, y: 0, width: Self.icon * scale, height: Self.icon * scale)
            l.contents = item.icon?.cgImage(forProposedRect: &r, context: nil, hints: nil)
            l.contentsGravity = .resizeAspect
            effect.layer?.addSublayer(l)
            return l
        }
        label.contentsScale = scale
        names = items.map(\.name)
        CATransaction.commit()
        select(selected)
        panel.orderFrontRegardless()
    }

    func select(_ i: Int) {
        guard icons.indices.contains(i) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.frame = CGRect(x: Self.pad + Double(i) * Self.cell, y: Self.pad + Self.labelHeight, width: Self.cell, height: Self.cell)
        label.string = names[i]
        label.frame = CGRect(x: Self.pad, y: Self.pad, width: panel.frame.width - 2 * Self.pad, height: 18)
        CATransaction.commit()
    }

    func hide() { panel.orderOut(nil) }
}
