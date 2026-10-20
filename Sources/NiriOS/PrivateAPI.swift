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

    private typealias SpacesFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private static let spacesForWindows = symbol("SLSCopySpacesForWindows", in: skyLight, as: SpacesFn.self)

    /// A janela existe e está em algum Space, o atual ou outro (o de uma tela cheia, outro desktop). Fechada, ou
    /// "fechada" por app que só esconde a janela, não está em nenhum (medido em 2026-10-16: as janelas
    /// escondidas do Arc vêm sem Space). Pergunta ao WindowServer, não ao app: ~0,3 ms.
    static func isOnAnySpace(_ window: CGWindowID) -> Bool {
        guard let mainConnection, let spacesForWindows else { return false }
        let spaces = spacesForWindows(mainConnection(), 7, [NSNumber(value: window)] as CFArray)?.takeRetainedValue()
        return (spaces as? [NSNumber])?.isEmpty == false
    }

    /// A janela ainda existe no WindowServer, em qualquer Space, na tela ou não. Fechada de vez, o `SLSGetWindowBounds`
    /// falha e ela não está em Space nenhum (medido em 2026-10-17 com a janela que ficou na fita). Sem as funções, existe.
    static func exists(_ window: CGWindowID) -> Bool {
        guard let mainConnection, let getBounds, spacesForWindows != nil else { return true }
        var r = CGRect.zero
        return getBounds(mainConnection(), window, &r) == 0 || isOnAnySpace(window)
    }

    private typealias ActiveSpaceFn = @convention(c) (Int32) -> UInt64
    private static let activeSpace = symbol("SLSGetActiveSpace", in: skyLight, as: ActiveSpaceFn.self)

    /// A janela está no Space da tela (e não numa tela cheia ou em outro desktop).
    static func isOnActiveSpace(_ window: CGWindowID) -> Bool {
        guard let mainConnection, let spacesForWindows, let activeSpace else { return true }
        let spaces = spacesForWindows(mainConnection(), 7, [NSNumber(value: window)] as CFArray)?.takeRetainedValue()
        return (spaces as? [NSNumber])?.contains { $0.uint64Value == activeSpace(mainConnection()) } ?? true
    }

    private typealias BoundsFn = @convention(c) (Int32, CGWindowID, UnsafeMutablePointer<CGRect>) -> Int32
    private static let getBounds = symbol("SLSGetWindowBounds", in: skyLight, as: BoundsFn.self)

    /// Onde a janela está pro WindowServer agora (coordenadas AX). Não fala com o app: ~0,02 ms.
    static func bounds(_ window: CGWindowID) -> CGRect? {
        guard let mainConnection, let getBounds else { return nil }
        var r = CGRect.zero
        return getBounds(mainConnection(), window, &r) == 0 ? r : nil
    }

    private typealias QueryFn = @convention(c) (Int32, CFArray, Int32) -> Unmanaged<CFTypeRef>?
    private typealias IteratorFn = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
    private typealias AdvanceFn = @convention(c) (CFTypeRef) -> Bool
    private typealias RadiiFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias TagsFn = @convention(c) (CFTypeRef) -> UInt64
    private static let queryWindows = symbol("SLSWindowQueryWindows", in: skyLight, as: QueryFn.self)
    private static let queryResult = symbol("SLSWindowQueryResultCopyWindows", in: skyLight, as: IteratorFn.self)
    private static let advance = symbol("SLSWindowIteratorAdvance", in: skyLight, as: AdvanceFn.self)
    private static let radii = symbol("SLSWindowIteratorGetCornerRadii", in: skyLight, as: RadiiFn.self)
    private static let tags = symbol("SLSWindowIteratorGetTags", in: skyLight, as: TagsFn.self)

    /// O que o WindowServer sabe da janela, numa consulta só (não fala com o app).
    private static func query<T>(_ window: CGWindowID, _ read: (CFTypeRef) -> T?) -> T? {
        guard let mainConnection, let queryWindows, let queryResult, let advance,
              let query = queryWindows(mainConnection(), [NSNumber(value: window)] as CFArray, 1)?.takeRetainedValue(),
              let iterator = queryResult(query)?.takeRetainedValue(), advance(iterator) else { return nil }
        return read(iterator)
    }

    /// Raio do canto da janela, como o WindowServer recorta ela. Pergunta ao WindowServer, não ao app: 0,2 ms pra
    /// 9 janelas, sem Gravação de Tela. Medido no macOS 26: Arc, Discord e Spotify 16, WhatsApp 26, Zed 12, WezTerm 0.
    static func cornerRadius(_ window: CGWindowID) -> Double? {
        query(window) { it in radii.flatMap { ($0(it)?.takeRetainedValue() as? [Double])?.first } }
    }

    /// A janela está indo pro Dock ou voltando dele. Medido com as tags do WindowServer a cada 5 ms: minimizando, 1 << 60
    /// liga aos 24 ms (e fica ligado enquanto ela está no Dock) e 1 << 34 enquanto anima; voltando, 1 << 34 enquanto anima.
    /// Os avisos com o número da janela (816, 815 e o da Acessibilidade) só chegam no fim da animação, ~550 ms depois.
    static func isMinimizing(_ window: CGWindowID) -> Bool {
        (query(window) { it in tags.map { $0(it) } } ?? 0) & (1 << 60 | 1 << 34) != 0
    }

    private typealias NotifyFn = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?) -> Void
    private typealias RegisterFn = @convention(c) (Int32, NotifyFn, UInt32, UnsafeMutableRawPointer?) -> Int32
    private typealias RequestFn = @convention(c) (Int32, UnsafeMutablePointer<CGWindowID>?, Int32) -> Int32
    private static let register = symbol("SLSRegisterConnectionNotifyProc", in: skyLight, as: RegisterFn.self)
    private static let request = symbol("SLSRequestNotificationsForWindows", in: skyLight, as: RequestFn.self)
    private static var windowChanged: ((WindowEvent, CGWindowID) -> Void)?
    private static let registered: Bool = {
        guard let mainConnection, let register else { return false }
        let notify: NotifyFn = { event, data, _, _ in
            guard let data, let e = WindowEvent(rawValue: event) else { return }
            Private.windowChanged?(e, data.load(as: CGWindowID.self))
        }
        return [806, 807, 815, 816, 1327, 1328].allSatisfy { register(mainConnection(), notify, $0, nil) == 0 }
    }()

    /// O dado de cada um é o número da janela, menos o das animações. `hidden`: medido fechando no X uma janela que o app
    /// só esconde (como WhatsApp e Discord): ela continua existindo, com o mesmo frame, e só sai da tela. `animation*`:
    /// começo e fim de uma animação do WindowServer (ir pro Dock e voltar dele), sem dizer de qual janela.
    enum WindowEvent: UInt32 { case moved = 806, resized = 807, shown = 815, hidden = 816, animationStarted = 1327, animationEnded = 1328 }

    /// Avisos do WindowServer quando `windows` mudam de lugar ou de tamanho, ou saem e voltam pra tela, na main, no
    /// instante em que a mudança vale (não quando o app recebe o pedido). Cada chamada troca a lista. Medido com uma
    /// janela movida via AX: o WindowServer só aplica 3 a 9 ms depois de o AX voltar, e o aviso chega logo depois disso.
    static func watch(_ windows: [CGWindowID], onChange: @escaping (WindowEvent, CGWindowID) -> Void) {
        guard let mainConnection, let request, registered else { return }
        windowChanged = onChange
        var list = windows
        _ = list.withUnsafeMutableBufferPointer { request(mainConnection(), $0.baseAddress, Int32($0.count)) }
    }

    private typealias OrderedInFn = @convention(c) (Int32, CGWindowID, UnsafeMutablePointer<UInt8>) -> Int32
    private static let orderedIn = symbol("SLSWindowIsOrderedIn", in: skyLight, as: OrderedInFn.self)

    /// A janela está na tela pro WindowServer (estacionada com 1 pt conta). Fechada no X por app que só esconde, não.
    /// ~0,08 ms.
    static func isOrderedIn(_ window: CGWindowID) -> Bool {
        guard let mainConnection, let orderedIn else { return true }
        var v: UInt8 = 1
        return orderedIn(mainConnection(), window, &v) != 0 || v != 0
    }

    /// Foto da janela inteira de outro app, mesmo fora da tela. Precisa de Gravação de Tela.
    /// Opções: 1<<11 ignora o recorte global, 1<<8 resolução Retina, 1<<15 a janela toda (sem ela
    /// só vem a parte visível). Medido: 10 a 60 ms; a ScreenCaptureKit leva ~95 ms.
    static func capture(_ window: CGWindowID) -> CGImage? {
        guard let mainConnection, let captureWindows else { return nil }
        var id = window
        let list = captureWindows(mainConnection(), &id, 1, 1 << 11 | 1 << 8 | 1 << 15)?.takeRetainedValue()
        return (list as? [CGImage])?.first
    }

    private typealias ListImageFn = @convention(c) (CGRect, UInt32, CGWindowID, UInt32) -> Unmanaged<CGImage>?
    /// Saiu do SDK no macOS 15 (a Apple empurra a ScreenCaptureKit), mas continua no sistema.
    private static let listImage = symbol("CGWindowListCreateImage", in: defaultHandle, as: ListImageFn.self)

    /// `rect` da tela como o WindowServer mostra, só com a janela e o que está abaixo dela (sem a nossa
    /// camada nem a sombra das janelas de cima). Janela com desfoque de fundo (WezTerm, barra lateral
    /// do Arc) só sai certa aqui: em `capture`, com qualquer uma das 32 opções, e também na
    /// ScreenCaptureKit, a parte translúcida vem sobre cinza 192 em vez do papel de parede.
    /// Medido: igual à tela pixel a pixel, 10 a 20 ms por coluna.
    static func captureShown(_ window: CGWindowID, in rect: CGRect) -> CGImage? {
        // kCGWindowListOptionOnScreenBelowWindow | kCGWindowListOptionIncludingWindow
        listImage?(rect, 4 | 8, window, 0)?.takeRetainedValue()
    }

    /// `rect` da tela só com a janela, sem sombra, em resolução Retina, com a transparência dela. Só a parte que
    /// está na tela: estacionada, vem vazia. ~10 a 35 ms pra 48 pt.
    static func captureAlone(_ window: CGWindowID, in rect: CGRect) -> CGImage? {
        // kCGWindowListOptionIncludingWindow; kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution
        listImage?(rect, 8, window, 1 | 8)?.takeRetainedValue()
    }

    /// `rect` da tela inteira como ela está, em resolução Retina, sem o cursor. ~15 ms numa tela de 3456x2234 px, mais
    /// ~25 ms na primeira leitura dos pixels (a foto vem sem copiar).
    static func captureScreen(_ rect: CGRect) -> CGImage? {
        // kCGWindowListOptionOnScreenOnly, todas as janelas
        listImage?(rect, 1, kCGNullWindowID, 0)?.takeRetainedValue()
    }

    private typealias ArrayImageFn = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
    private static let arrayImage = symbol("CGWindowListCreateImageFromArray", in: defaultHandle, as: ArrayImageFn.self)

    /// `rect` da tela composto só com `windows` (da frente pra trás), como o WindowServer mostra.
    static func captureShown(_ windows: [CGWindowID], in rect: CGRect) -> CGImage? {
        // A lista guarda o número da janela no lugar do ponteiro, não CFNumber.
        var items = windows.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let arrayImage, let list = CFArrayCreate(nil, &items, items.count, nil) else { return nil }
        return arrayImage(rect, list, 0)?.takeRetainedValue()
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
    /// `raise`: sobe a janela mesmo sem troca (o AXRaise sozinho), pra ela passar por cima de uma solta. Logo depois do
    /// setFront, sobe em 10 de 10 vezes, aos 18 ms (mediana; medido em 2026-10-20).
    static func focus(pid: pid_t, window: CGWindowID, element: AXUIElement, switchWindow: Bool, raise: Bool = false) {
        var psn = ProcessSerialNumber()
        if let getPSN, let setFront, getPSN(pid, &psn) == noErr {
            _ = setFront(&psn, window, 0x200)  // kCPSUserGenerated
            if switchWindow { makeKeyWindow(&psn, window) }
        } else {
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
        if switchWindow || raise { AXUIElementPerformAction(element, kAXRaiseAction as CFString) }
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
    private var latest: (pid: pid_t, window: CGWindowID, element: AXUIElement, switchWindow: Bool, raise: Bool)?
    private var scheduled = false

    func request(pid: pid_t, window: CGWindowID, element: AXUIElement, switchWindow: Bool, raise: Bool) {
        lock.lock()
        latest = (pid, window, element, switchWindow, raise)
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
        Private.focus(pid: req.pid, window: req.window, element: req.element, switchWindow: req.switchWindow, raise: req.raise)
    }
}

func log(_ message: String) {
    let t = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second().secondFraction(.fractional(3)))
    FileHandle.standardError.write(Data("[\(t)] \(message)\n".utf8))
}
