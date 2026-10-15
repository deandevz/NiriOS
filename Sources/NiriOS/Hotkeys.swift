import AppKit
import Carbon.HIToolbox

enum Action {
    case grow, shrink, focusLeft, focusRight, toggleFullWidth
}

/// Atalhos globais via CGEventTap.
///
/// Por que não RegisterEventHotKey (Carbon): o macOS 15 passou a restringir atalhos só com Option
/// nessa API, e ela não informa se a tecla é repetição. O tap usa a mesma permissão de
/// Acessibilidade que o resto já exige.
/// Roda numa thread própria: se a main travar, o tap não estoura o timeout do sistema.
final class HotkeyTap {
    /// Códigos de tecla são posicionais: valem pra US, US Internacional e ABNT2.
    /// Shift é aceito, então Option+< e Option+> funcionam igual a Option+, e Option+.
    static let bindings: [Int64: Action] = [
        Int64(kVK_ANSI_Equal): .grow,
        Int64(kVK_ANSI_KeypadPlus): .grow,
        Int64(kVK_ANSI_Minus): .shrink,
        Int64(kVK_ANSI_KeypadMinus): .shrink,
        Int64(kVK_ANSI_Comma): .focusLeft,
        Int64(kVK_ANSI_Period): .focusRight,
        // Option+setas também: no terminal e no editor elas deixam de pular palavra.
        Int64(kVK_LeftArrow): .focusLeft,
        Int64(kVK_RightArrow): .focusRight,
        Int64(kVK_ANSI_F): .toggleFullWidth,
    ]

    private let handler: (Action) -> Void
    private let verbose: Bool
    private var port: CFMachPort?

    init(verbose: Bool, handler: @escaping (Action) -> Void) {
        self.verbose = verbose
        self.handler = handler
    }

    func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let tap = Unmanaged<HotkeyTap>.fromOpaque(refcon!).takeUnretainedValue()
            return tap.handle(type, event)
        }
        // Nível HID: a tecla chega aqui antes de virar atalho global de outro app
        // (no nível de sessão, um app que registrou Option+, pegaria a tecla antes).
        guard let port = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        self.port = port
        let thread = Thread {
            let source = CFMachPortCreateRunLoopSource(nil, port, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            CFRunLoopRun()
        }
        thread.name = "niri.hotkeys"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            log("tap de teclado reativado (\(type == .tapDisabledByTimeout ? "timeout" : "input"))")
            return Unmanaged.passUnretained(event)
        }
        let mods = event.flags.intersection([.maskAlternate, .maskCommand, .maskControl])
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        if verbose && type == .keyDown && mods.contains(.maskAlternate) {
            log("tecla: código \(keycode), modificadores 0x\(String(event.flags.rawValue, radix: 16)) -> \(Self.bindings[keycode].map { "\($0)" } ?? "sem atalho")")
        }
        guard mods == .maskAlternate, let action = Self.bindings[keycode]
        else { return Unmanaged.passUnretained(event) }

        if type == .keyDown {
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            // Segurar a tecla repete resize e navegação; tela cheia alternando sem parar não faz sentido.
            if !(isRepeat && action == .toggleFullWidth) {
                DispatchQueue.main.async { self.handler(action) }
            }
        }
        return nil  // engole keyDown e keyUp: o app não recebe "≠", "ƒ" etc.
    }
}
