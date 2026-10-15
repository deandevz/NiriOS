import AppKit
import ApplicationServices

/// Funções privadas resolvidas em tempo de execução (dlsym), sem linkar framework privado.
/// Todas funcionam com SIP ligado e sem nada injetado no Dock: são as mesmas que yabai e AltTab
/// usam pra focar janela de outro app.
enum Private {
    private static let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func symbol<T>(_ name: String, in handle: UnsafeMutableRawPointer?, as _: T.Type) -> T? {
        guard let p = dlsym(handle, name) else {
            log("API privada ausente: \(name)")
            return nil
        }
        return unsafeBitCast(p, to: T.self)
    }

    private typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias GetPSNFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private typealias SetFrontFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> Int32
    private typealias PostEventFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32

    private static let axGetWindow = symbol("_AXUIElementGetWindow", in: defaultHandle, as: AXGetWindowFn.self)
    private static let getPSN = symbol("GetProcessForPID", in: defaultHandle, as: GetPSNFn.self)
    private static let setFront = symbol("_SLPSSetFrontProcessWithOptions", in: skyLight, as: SetFrontFn.self)
    private static let postEvent = symbol("SLPSPostEventRecordTo", in: skyLight, as: PostEventFn.self)
    private typealias MainConnFn = @convention(c) () -> Int32
    private typealias CaptureFn = @convention(c) (Int32, UnsafeMutablePointer<UInt32>, Int32, UInt32) -> Unmanaged<CFArray>?
    private static let mainConnection = symbol("SLSMainConnectionID", in: skyLight, as: MainConnFn.self)
    private static let captureWindows = symbol("SLSHWCaptureWindowList", in: skyLight, as: CaptureFn.self)

    /// Foto da janela inteira de outro app, mesmo fora da tela. Precisa de Gravação de Tela.
    /// Opções: 1<<11 ignora o recorte global, 1<<8 resolução Retina, 1<<15 a janela toda (sem ela
    /// só vem a parte visível). Medido: 10 a 60 ms; a ScreenCaptureKit leva ~95 ms.
    static func capture(_ window: CGWindowID) -> CGImage? {
        guard let mainConnection, let captureWindows else { return nil }
        var id = window
        let list = captureWindows(mainConnection(), &id, 1, 1 << 11 | 1 << 8 | 1 << 15)?.takeRetainedValue()
        return (list as? [CGImage])?.first
    }

    /// ID da janela no WindowServer a partir do elemento AX.
    static func windowID(of element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard let axGetWindow, axGetWindow(element, &id) == .success, id != 0 else { return nil }
        return id
    }

    /// Traz o app pra frente com aquela janela como key window.
    /// `NSRunningApplication.activate` sozinho não basta desde o macOS 14 (ativação cooperativa).
    /// `switchWindow`: o app considera outra janela como a focada. Só aí manda o evento de "make key"
    /// e o AXRaise. Sem troca, o setFront já devolve o foco à janela certa, e o make key a mais faz o
    /// app redesenhar de novo: o WhatsApp fica 70 ms sem responder em vez de 25 (medido).
    static func focus(pid: pid_t, window: CGWindowID, element: AXUIElement, switchWindow: Bool) {
        var psn = ProcessSerialNumber()
        if let getPSN, let setFront, getPSN(pid, &psn) == noErr {
            _ = setFront(&psn, window, 0x200)  // kCPSUserGenerated
            if switchWindow { makeKeyWindow(&psn, window) }
        } else {
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
        if switchWindow { AXUIElementPerformAction(element, kAXRaiseAction as CFString) }
    }

    /// Evento sintético que o WindowServer entende como "torne esta janela key" (layout do yabai).
    private static func makeKeyWindow(_ psn: UnsafeMutablePointer<ProcessSerialNumber>, _ window: CGWindowID) {
        guard let postEvent else { return }
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: window) { for (i, b) in $0.enumerated() { bytes[0x3c + i] = b } }
        for i in 0x20..<0x30 { bytes[i] = 0xff }
        bytes[0x08] = 0x01
        _ = postEvent(psn, &bytes)
        bytes[0x08] = 0x02
        _ = postEvent(psn, &bytes)
    }
}

/// Fila única pra pedidos de foco. Só o último pedido vale: segurar Option+. dispara dezenas de
/// pedidos, e executar todos (ou fora de ordem, em filas por app) deixaria o foco real
/// diferente do foco do layout.
final class FocusController {
    private let queue = DispatchQueue(label: "niri.focus", qos: .userInteractive)
    private let lock = NSLock()
    private var latest: (pid: pid_t, window: CGWindowID, element: AXUIElement, switchWindow: Bool)?
    private var scheduled = false

    func request(pid: pid_t, window: CGWindowID, element: AXUIElement, switchWindow: Bool) {
        lock.lock()
        latest = (pid, window, element, switchWindow)
        let needsDrain = !scheduled
        scheduled = true
        lock.unlock()
        if needsDrain { queue.async { self.drain() } }
    }

    private func drain() {
        lock.lock()
        let req = latest
        latest = nil
        scheduled = false
        lock.unlock()
        guard let req else { return }
        Private.focus(pid: req.pid, window: req.window, element: req.element, switchWindow: req.switchWindow)
    }
}

func log(_ message: String) {
    let t = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second().secondFraction(.fractional(3)))
    FileHandle.standardError.write(Data("[\(t)] \(message)\n".utf8))
}
