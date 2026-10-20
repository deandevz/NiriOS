import AppKit
import NiriCore
import os

/// O nome de cada ação fixa é a chave dela em "shortcuts" no config.json. As de workspace vêm de "workspaces".
enum Action: Hashable {
    case grow, shrink, growHeight, shrinkHeight, focusLeft, focusRight, focusUp, focusDown, moveColumnLeft, moveColumnRight
    case consumeOrExpelLeft, consumeOrExpelRight, toggleFullWidth, toggleDesktop
    /// Solta a janela com o teclado da fita (fica por cima dela, no workspace) ou prende na fita (ver `Layout.float`).
    case toggleFloating
    /// O foco vai da fita pra solta de cima e volta (ver `Layout.toggleFloatingFocus`).
    case focusFloating
    /// Fixa a solta focada na tela, fora da gaveta, ou devolve (ver `Layout.togglePinned`).
    case pinFloating
    /// Abre e fecha o histórico do que foi copiado (ver `Clipboard`).
    case clipboard
    /// Congela a tela pra escolher a área do print (ver `Screenshot`). De novo, fecha.
    case screenshot
    /// Vai pro workspace com esse nome / manda a janela focada pra ele.
    case workspace(String), moveToWorkspace(String)

    /// As ações de "shortcuts", na ordem do painel.
    static let allCases: [Action] = [.grow, .shrink, .growHeight, .shrinkHeight, .focusLeft, .focusRight, .focusUp, .focusDown,
                                     .moveColumnLeft, .moveColumnRight, .consumeOrExpelLeft, .consumeOrExpelRight, .toggleFullWidth, .toggleDesktop,
                                     .toggleFloating, .focusFloating, .pinFloating, .clipboard, .screenshot]
    var rawValue: String { String(describing: self) }
    init?(rawValue: String) {
        guard let a = Self.allCases.first(where: { $0.rawValue == rawValue }) else { return nil }
        self = a
    }

    /// O recurso que precisa estar ligado pro atalho valer (ver `Config.active`).
    var feature: Feature {
        switch self {
        case .clipboard: .clipboard
        case .screenshot: .screenshot
        default: .tiling
        }
    }

    /// Segurar a tecla repete resize, navegação e mover coluna. Tela cheia e mesa alternando sem parar não fazem sentido,
    /// juntar e separar ficaria indo e voltando, e mandar pra outro workspace mandaria uma janela atrás da outra.
    var repeats: Bool {
        [.grow, .shrink, .growHeight, .shrinkHeight, .focusLeft, .focusRight, .focusUp, .focusDown, .moveColumnLeft, .moveColumnRight].contains(self)
    }
}

/// Atalhos globais via CGEventTap.
///
/// Por que não RegisterEventHotKey (Carbon): o macOS 15 passou a restringir atalhos só com Option
/// nessa API, e ela não informa se a tecla é repetição. O tap usa a mesma permissão de
/// Acessibilidade que o resto já exige.
/// Roda numa thread própria: se a main travar, o tap não estoura o timeout do sistema.
final class HotkeyTap {
    /// Escrito na main (config recarregada, painel gravando atalho) e lido na thread do tap.
    private struct State {
        var bindings: [Shortcut: Action] = [:]
        /// Os modificadores de cada atalho, sem o Shift (ver `onModifiers`).
        var holds: Set<UInt64> = []
        var paused = false
        /// Ações que agora não fariam nada: a tecla passa pro app (ver `idle`).
        var idle: Set<Action> = []
        var solo: Action?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    private let handler: (Action) -> Void
    /// Os modificadores de algum atalho apertados (no padrão, o Option sozinho) / soltos: a transição do
    /// resize fotografa antes da tecla chegar, e o resize fantasma só devolve a janela quando eles sobem.
    /// Shift não conta, pra Option+< (Shift+,) não soltar no meio.
    var onModifiers: ((Bool) -> Void)?
    private var modifiersDown = false
    private let verbose: Bool
    private var port: CFMachPort?

    init(verbose: Bool, handler: @escaping (Action) -> Void) {
        self.verbose = verbose
        self.handler = handler
    }

    func setShortcuts(_ shortcuts: [Action: [Shortcut]]) {
        var bindings: [Shortcut: Action] = [:]
        for (action, keys) in shortcuts { for k in keys { bindings[k] = action } }
        // Atalho sem modificador não segura nada: a janela do resize fantasma volta assim que a fita para.
        let holds = Set(bindings.keys.map { $0.mods.subtracting(.maskShift).rawValue }).subtracting([0])
        state.withLock { [bindings] in $0.bindings = bindings; $0.holds = holds }
    }

    /// Pausado, toda tecla passa direto pro app da frente (o painel gravando um atalho novo).
    var paused: Bool {
        get { state.withLock { $0.paused } }
        set { state.withLock { $0.paused = newValue } }
    }

    /// O atalho dessas ações vai pro app da frente em vez de ser engolido: Option ↑ ↓ fora de uma coluna com mais de uma
    /// janela continua subindo e descendo parágrafo no editor.
    var idle: Set<Action> {
        get { state.withLock { $0.idle } }
        set { state.withLock { $0.idle = newValue } }
    }

    /// Só esse atalho é do niri-os; os outros vão pro app da frente. O editor do print aberto recebe o Option+, no texto,
    /// e as janelas não andam por baixo da foto congelada.
    var solo: Action? {
        get { state.withLock { $0.solo } }
        set { state.withLock { $0.solo = newValue } }
    }

    /// Os modificadores de algum atalho estão apertados agora, segundo o estado do teclado.
    func modifiersHeld() -> Bool {
        let mods = CGEventSource.flagsState(.hidSystemState).intersection(Shortcut.modifierMask).subtracting(.maskShift)
        return state.withLock { $0.holds.contains(mods.rawValue) }
    }

    func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
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
            // Os modificadores podem ter subido com o tap desligado: sem isso a janela do resize fantasma ficaria escondida.
            if modifiersDown, let onModifiers {
                modifiersDown = false
                DispatchQueue.main.async { onModifiers(false) }
            }
            return Unmanaged.passUnretained(event)
        }
        let (bindings, holds, paused, idle, solo) = state.withLock { ($0.bindings, $0.holds, $0.paused, $0.idle, $0.solo) }
        let mods = event.flags.intersection(Shortcut.modifierMask)
        if type == .flagsChanged {
            let down = holds.contains(mods.subtracting(.maskShift).rawValue)
            if down != modifiersDown, let onModifiers {
                modifiersDown = down
                DispatchQueue.main.async { onModifiers(down) }
            }
            return Unmanaged.passUnretained(event)
        }
        guard !paused else { return Unmanaged.passUnretained(event) }
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        // Com Shift: o atalho com Shift, se existe; senão o mesmo sem ele (Option+< = Option+,).
        let action = bindings[Shortcut(key: keycode, mods: mods)]
            ?? (mods.contains(.maskShift) ? bindings[Shortcut(key: keycode, mods: mods.subtracting(.maskShift))] : nil)
        // Só com os modificadores de algum atalho: o log não registra o que a pessoa digita.
        if verbose && type == .keyDown && holds.contains(mods.subtracting(.maskShift).rawValue) {
            log("tecla: \(Shortcut(key: keycode, mods: mods)) (código \(keycode)) -> \(action.map { "\($0)" } ?? "sem atalho")")
        }
        guard let action, !idle.contains(action), solo == nil || solo == action else { return Unmanaged.passUnretained(event) }

        if type == .keyDown {
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if !isRepeat || action.repeats {
                DispatchQueue.main.async { self.handler(action) }
            }
        }
        return nil  // engole keyDown e keyUp: o app não recebe "≠", "ƒ" etc.
    }
}
