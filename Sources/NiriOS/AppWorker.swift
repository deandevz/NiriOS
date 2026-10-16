import AppKit
import ApplicationServices
import QuartzCore

struct WindowInfo {
    let id: CGWindowID
    let element: AXUIElement
    let frame: CGRect
    let title: String
    let subrole: String
    /// nil = entra na fita. Senão, o motivo de ficar de fora (aparece no --list).
    let skipReason: String?
    /// O app não respondeu direito sobre esta janela. Não dá pra concluir nada: quem está na fita
    /// continua, quem não está não entra.
    let uncertain: Bool
    /// Em tela cheia nativa (num Space à parte).
    let fullScreen: Bool
    var tileable: Bool { skipReason == nil && !uncertain }
}

struct ScanResult {
    /// nil = o app não respondeu (timeout, ocupado). Diferente de lista vazia, que é "não tem janela".
    /// Tratar as duas coisas igual faria janelas saírem da fita e voltarem em outro lugar.
    let windows: [WindowInfo]?
    let focused: CGWindowID?
}

/// Uma fila serial por app. Toda chamada de Acessibilidade pra esse app passa por aqui,
/// então um app lento (Electron, app travado) só atrasa as próprias janelas.
///
/// Frames chegam a 120 Hz, mas o app aplica no ritmo dele: se ainda está ocupado com o frame
/// anterior, os intermediários são descartados e ele pula direto pro mais recente.
final class AppWorker {
    let pid: pid_t
    let name: String
    let bundleID: String?
    private let app: AXUIElement
    private let queue: DispatchQueue
    private let timeout: Float

    /// Chamados na main.
    var onScan: ((pid_t, ScanResult) -> Void)?
    var onFocus: ((pid_t, CGWindowID) -> Void)?

    // Só acessados na `queue`.
    private var observer: AXObserver?
    private var elements: [CGWindowID: AXUIElement] = [:]
    private var observed: Set<CGWindowID> = []
    private var seen: Set<CGWindowID> = []
    /// Último frame que o layout pediu pra cada janela.
    private var requested: [CGWindowID: CGRect] = [:]
    /// Onde a janela está de fato (até onde sabemos): posição que aplicamos + tamanho real.
    /// O tamanho real vem do scan e da conferência pós-animação; app pode recusar um tamanho.
    private var current: [CGWindowID: CGRect] = [:]
    private var enhancedUIChecked = false
    private var enhancedUIWasOn = false

    // Compartilhados entre threads, protegidos por `lock`.
    private let lock = NSLock()
    private var pending: [CGWindowID: CGRect] = [:]
    private var clip = CGRect.infinite
    private var drainScheduled = false
    private var scanScheduled = false
    private var stopped = false
    private var observerSource: CFRunLoopSource?
    private var stats = Stats()
    /// Janelas que a transição do resize (`TransitionOverlay` ou `GhostOverlay`) está desenhando no
    /// lugar delas: os frames da fita são ignorados até elas voltarem (`attach`).
    private var detached: Set<CGWindowID> = []

    struct Stats {
        var frames = 0
        var calls = 0
        var seconds = 0.0
        var errors = 0
        /// Frames em que duas janelas deste app ficaram sobrepostas (parte visível) depois de aplicar.
        var overlapFrames = 0
        /// Maior intervalo entre dois frames aplicados. Acima de ~17 ms o olho vê travada.
        var maxGap = 0.0
        var lastDrain = 0.0
    }

    /// Modo de teste: aceita painéis flutuantes também.
    private let anySubrole: Bool

    init(pid: pid_t, name: String, bundleID: String?, timeout: Double, anySubrole: Bool = false) {
        self.anySubrole = anySubrole
        self.pid = pid
        self.name = name
        self.bundleID = bundleID
        self.app = AXUIElementCreateApplication(pid)
        self.timeout = Float(timeout)
        self.queue = DispatchQueue(label: "niri.app.\(pid)", qos: .userInteractive)
        AXUIElementSetMessagingTimeout(app, self.timeout)
    }

    func start() {
        queue.async {
            self.createObserver(attempt: 0)
            self.scanNow()
        }
    }

    /// Na main. Depois disso nenhum callback do observer chega mais.
    func stop() {
        lock.lock()
        stopped = true
        let source = observerSource
        observerSource = nil
        lock.unlock()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }

    // MARK: - Eventos

    /// App recém-aberto ainda não responde AX: tenta de novo por até ~3 s.
    private func createObserver(attempt: Int) {
        var obs: AXObserver?
        guard AXObserverCreate(pid, axCallback, &obs) == .success, let obs else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let err = AXObserverAddNotification(obs, app, kAXWindowCreatedNotification as CFString, refcon)
        if err != .success && err != .notificationAlreadyRegistered {
            if attempt < 12 {
                queue.asyncAfter(deadline: .now() + 0.25) { self.createObserver(attempt: attempt + 1) }
            } else {
                log("\(name): sem eventos de Acessibilidade (erro \(err.rawValue))")
            }
            return
        }
        for n in [kAXFocusedWindowChangedNotification, kAXApplicationHiddenNotification, kAXApplicationShownNotification] {
            AXObserverAddNotification(obs, app, n as CFString, refcon)
        }
        observer = obs
        for (_, el) in elements { observeWindow(el) }
        let source = AXObserverGetRunLoopSource(obs)
        lock.lock()
        if !stopped {
            observerSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        lock.unlock()
        if attempt > 0 { scanNow() }
    }

    private func observeWindow(_ el: AXUIElement) {
        guard let observer else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
            AXObserverAddNotification(observer, el, n as CFString, refcon)
        }
    }

    /// Na main (o observer roda no run loop da main). Só despacha; nada de AX aqui.
    fileprivate func notify(_ name: String, element: AXUIElement) {
        switch name {
        case kAXFocusedWindowChangedNotification:
            queue.async { self.reportFocus(element) }
        case kAXWindowCreatedNotification:
            requestScan()
            // Alguns apps só preenchem subrole e tamanho um instante depois de criar a janela.
            queue.asyncAfter(deadline: .now() + 0.3) { self.scanNow() }
        default:
            requestScan()
        }
    }

    func requestScan() {
        lock.lock()
        let already = scanScheduled
        scanScheduled = true
        lock.unlock()
        guard !already else { return }
        queue.asyncAfter(deadline: .now() + 0.02) {
            self.lock.lock()
            self.scanScheduled = false
            self.lock.unlock()
            self.scanNow()
        }
    }

    func reportFocusedWindow() {
        queue.async { self.reportFocus(nil) }
    }

    private func reportFocus(_ element: AXUIElement?) {
        let id = element.flatMap(Private.windowID) ?? AX.element(app, kAXFocusedWindowAttribute).flatMap(Private.windowID)
        guard let id else { return }
        DispatchQueue.main.async { self.onFocus?(self.pid, id) }
    }

    private func scanNow() {
        let result = Self.readWindows(app: app, timeout: timeout, anySubrole: anySubrole)
        var current: [CGWindowID: AXUIElement] = [:]
        guard let windows = result.windows else {
            DispatchQueue.main.async { self.onScan?(self.pid, result) }
            return
        }
        for w in windows {
            current[w.id] = w.element
            if !observed.contains(w.id) {
                observeWindow(w.element)
                observed.insert(w.id)
            }
        }
        elements = current
        observed.formIntersection(current.keys)
        seen.formIntersection(current.keys)
        requested = requested.filter { current[$0.key] != nil }
        lock.lock(); detached.formIntersection(current.keys); lock.unlock()
        var placed: [CGWindowID: CGRect] = [:]
        for w in windows { placed[w.id] = w.frame }  // o scan lê o frame real
        self.current = placed
        DispatchQueue.main.async { self.onScan?(self.pid, result) }
    }

    // MARK: - Leitura

    static func readWindows(app: AXUIElement, timeout: Float, anySubrole: Bool = false) -> ScanResult {
        let focused = AX.element(app, kAXFocusedWindowAttribute).flatMap(Private.windowID)
        let hidden = AX.bool(app, kAXHiddenAttribute) ?? false
        var rawList: CFTypeRef?
        let listErr = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &rawList)
        if listErr == .noValue { return ScanResult(windows: [], focused: focused) }
        guard listErr == .success, let list = rawList as? [AXUIElement] else {
            return ScanResult(windows: nil, focused: focused)
        }
        let attrs = [kAXRoleAttribute, kAXSubroleAttribute, kAXMinimizedAttribute, "AXFullScreen",
                     kAXPositionAttribute, kAXSizeAttribute, kAXTitleAttribute] as CFArray
        var out: [WindowInfo] = []
        for el in list {
            AXUIElementSetMessagingTimeout(el, timeout)
            guard let id = Private.windowID(of: el) else { continue }
            // Uma ida e volta ao app em vez de sete.
            var raw: CFArray?
            let multiErr = AXUIElementCopyMultipleAttributeValues(el, attrs, AXCopyMultipleAttributeOptions(rawValue: 0), &raw)
            let v = (raw as? [AnyObject]) ?? []
            func at(_ i: Int) -> AnyObject? { i < v.count ? v[i] : nil }
            let role = at(0) as? String ?? ""
            let subrole = at(1) as? String ?? ""
            let minimized = AX.isError(at(2)) ? false : (at(2) as? Bool ?? false)
            let fullScreen = AX.isError(at(3)) ? false : (at(3) as? Bool ?? false)
            let pos = AX.point(at(4)) ?? .zero
            let size = AX.size(at(5)) ?? .zero
            let title = at(6) as? String ?? ""
            var settable: DarwinBoolean = false
            let settableErr = AXUIElementIsAttributeSettable(el, kAXSizeAttribute as CFString, &settable)
            let uncertain = multiErr != .success || AX.isError(at(0)) || AX.isError(at(1)) || settableErr != .success

            let reason: String? =
                hidden ? "app oculto" :
                role != kAXWindowRole ? "role \(role)" :
                (subrole != kAXStandardWindowSubrole && !anySubrole) ? "subrole \(subrole)" :
                minimized ? "minimizada" :
                fullScreen ? "tela cheia nativa" :
                !settable.boolValue ? "tamanho fixo" :
                (size.width < 50 || size.height < 50) ? "pequena demais" : nil
            out.append(WindowInfo(id: id, element: el, frame: CGRect(origin: pos, size: size),
                                  title: title, subrole: subrole, skipReason: reason, uncertain: uncertain, fullScreen: fullScreen))
        }
        return ScanResult(windows: out, focused: focused)
    }

    // MARK: - Escrita

    /// Na main, a cada frame. Barato: só guarda e agenda.
    /// `firstFrame`: começo de animação. Zera o relógio de intervalo pra não medir o tempo parado.
    func submit(_ frames: [(CGWindowID, CGRect)], screen: CGRect, firstFrame: Bool) {
        lock.lock()
        clip = screen
        if firstFrame { stats.lastDrain = 0 }
        for (id, r) in frames { pending[id] = r }
        let needsDrain = !drainScheduled
        drainScheduled = true
        lock.unlock()
        if needsDrain { queue.async { self.drain() } }
    }

    /// Transição do resize: a janela sai da animação (os frames da fita são ignorados) e vai direto pro
    /// lugar e tamanho finais, na tela, por baixo das fotos. `done` quando o app devolveu.
    func placeHidden(_ id: CGWindowID, at r: CGRect, done: @escaping () -> Void) {
        lock.lock(); detached.insert(id); lock.unlock()
        queue.async {
            if let el = self.elements[id] {
                let shrinking = (self.current[id]?.width ?? 0) > r.width
                if shrinking { _ = AX.setSize(el, r.size) }
                _ = AX.setPosition(el, r.origin)
                if !shrinking { _ = AX.setSize(el, r.size) }
                self.current[id] = r
            }
            DispatchQueue.main.async(execute: done)
        }
    }

    /// Resize fantasma: a janela sai da fita (os frames da fita são ignorados) e espera fora da tela, com
    /// 1 pt na borda direita, até `attach`. Encolhendo, o tamanho novo vai antes, ainda na tela e por baixo do
    /// vidro (fora da tela o Electron recusa resize): na volta ela já cabe no lugar e não invade a vizinha.
    func park(_ id: CGWindowID, screen: CGRect, y: Double, shrinkTo size: CGSize?) {
        lock.lock(); detached.insert(id); lock.unlock()
        queue.async {
            guard let el = self.elements[id] else { return }
            if let size { _ = AX.setSize(el, size) }
            let p = CGPoint(x: screen.maxX - 1, y: y)
            _ = AX.setPosition(el, p)
            self.current[id] = CGRect(origin: p, size: size ?? self.current[id]?.size ?? .zero)
        }
    }

    /// Devolve a janela ao lugar final. Da transição por fotos ela volta já no tamanho final (só posição);
    /// do resize fantasma, crescendo, cresce aqui, dentro do lugar final.
    /// Volta pra fita aqui, na main, e não no fim do bloco na fila: um `park` de outra tecla logo depois (a fita parou
    /// e a janela começou a voltar) era desfeito quando o bloco rodava depois dele, e a janela andava pela fita por
    /// baixo do vidro, por cima da vizinha. Os frames que a fila aplicar antes do bloco já são o lugar final.
    func attach(_ id: CGWindowID, at r: CGRect, done: @escaping () -> Void) {
        lock.lock(); detached.remove(id); lock.unlock()
        queue.async {
            if let el = self.elements[id] {
                let c = self.current[id]
                let resized = c.map { abs($0.width - r.width) > 1 || abs($0.height - r.height) > 1 } ?? false
                // Encolhendo: tamanho antes da posição, senão ela invade a vizinha (do lado ou de baixo) por um instante.
                if resized, let c, r.width < c.width || r.height < c.height { _ = AX.setSize(el, r.size) }
                _ = AX.setPosition(el, r.origin)
                if resized {
                    _ = AX.setSize(el, r.size)
                    _ = AX.setPosition(el, r.origin)
                }
                self.current[id] = r
                self.requested[id] = r
            }
            DispatchQueue.main.async(execute: done)
        }
    }

    /// A janela saiu da fita sem fechar (tela cheia, minimizada, app escondido): para de mandar frame e de
    /// conferir. Senão a conferência pós-animação devolvia o tamanho e a posição da fita pra uma janela em
    /// tela cheia, em outro Space.
    func forget(_ id: CGWindowID) {
        lock.lock(); pending[id] = nil; lock.unlock()
        queue.async { self.requested[id] = nil }
    }

    /// Depois que a animação assenta (fora do caminho crítico): lê o frame real de cada janela.
    /// - Devolve pro lugar a que o usuário arrastou ou que o app moveu sozinho.
    /// - Janela inteira na tela e mais larga ou mais alta que o pedido = o app recusou encolher. Esse é o
    ///   limite dela (`minSizes`, 0 na direção em que ela obedeceu), e o layout passa a respeitar.
    /// Lido depois de assentar, não durante: Electron aplica o tamanho de forma assíncrona,
    /// e uma leitura logo após o set mostraria o tamanho velho como se fosse recusa.
    func verifyPlacement(completion: @escaping (_ fixed: Int, _ minSizes: [(CGWindowID, CGSize)]) -> Void) {
        queue.async {
            self.lock.lock()
            let screen = self.clip
            let detached = self.detached
            self.lock.unlock()
            var fixed = 0
            var minSizes: [(CGWindowID, CGSize)] = []
            for (id, r) in self.requested where !detached.contains(id) {
                guard let el = self.elements[id],
                      let p = AX.point(AX.copy(el, kAXPositionAttribute)),
                      let s = AX.size(AX.copy(el, kAXSizeAttribute)) else { continue }
                let onScreen = r.minX >= screen.minX && r.maxX <= screen.maxX
                let wider = s.width > r.width + 1, taller = s.height > r.height + 1
                if onScreen && (wider || taller) { minSizes.append((id, CGSize(width: wider ? s.width : 0, height: taller ? s.height : 0))) }
                let origin = Self.origin(for: r, screen: screen)
                var size = s
                if onScreen && (s.width < r.width - 1 || abs(s.height - r.height) > 1) {
                    _ = AX.setSize(el, r.size)
                    size = r.size
                    fixed += 1
                }
                if abs(p.x - origin.x) > 1 || abs(p.y - origin.y) > 1 {
                    _ = AX.setPosition(el, origin)
                    fixed += 1
                }
                self.current[id] = CGRect(origin: origin, size: size)
            }
            DispatchQueue.main.async { completion(fixed, minSizes) }
        }
    }

    /// Janela estacionada: fatia de 1 pt na borda da tela.
    static func isParked(_ r: CGRect, screen: CGRect) -> Bool {
        r.maxX <= screen.minX + 1.5 || r.minX >= screen.maxX - 1.5
    }

    /// Toda estacionada fica na borda direita, com 1 pt à mostra, mesmo a que o layout põe na esquerda: lá a
    /// posição não depende da largura. Na esquerda é x = 1 - largura, e com a largura velha (app que muda
    /// sozinho, ou que recusa encolher fora da tela: o Discord ficou com 24 pt) sobrava um pedaço na tela. O
    /// pulo de uma borda pra outra, quando ela volta pela esquerda, é de uma fatia de 1 pt e não aparece.
    static func origin(for r: CGRect, screen: CGRect) -> CGPoint {
        isParked(r, screen: screen) ? CGPoint(x: screen.maxX - 1, y: r.minY) : r.origin
    }

    private func drain() {
        lock.lock()
        let batch = pending.filter { !detached.contains($0.key) }
        let screen = clip
        pending.removeAll()
        drainScheduled = false
        lock.unlock()
        guard !batch.isEmpty else { return }
        disableEnhancedUIIfNeeded()

        let t0 = CACurrentMediaTime()
        var calls = 0, errors = 0, gone = false
        for (id, r) in orderedToAvoidOverlap(batch, screen: screen) {
            guard let el = elements[id] else { continue }
            requested[id] = r
            let now = current[id]
            // Estacionada não muda de tamanho: app Electron recusa resize fora da tela, e não
            // adianta gastar chamada com janela invisível. O resize acontece quando ela voltar.
            let parked = Self.isParked(r, screen: screen)
            let real = now?.size ?? r.size
            let size = parked ? real : r.size
            let origin = Self.origin(for: r, screen: screen)
            let moved = now?.origin != origin
            let resized = abs(real.width - size.width) > 0.5 || abs(real.height - size.height) > 0.5
            guard moved || resized else { continue }
            var errs: [AXError] = []
            // Encolhendo: tamanho antes da posição. Ao contrário, o estado intermediário
            // (posição nova, tamanho velho) invade a vizinha por um instante.
            if resized && (size.width < real.width || size.height < real.height) {
                errs.append(AX.setSize(el, size))
                if moved { errs.append(AX.setPosition(el, origin)) }
            } else {
                errs.append(AX.setPosition(el, origin))
                if resized { errs.append(AX.setSize(el, size)) }
            }
            // Primeira vez: o app pode ter limitado a posição pelo tamanho antigo. Reposiciona.
            if !seen.contains(id) && resized { errs.append(AX.setPosition(el, origin)) }
            seen.insert(id)
            current[id] = CGRect(origin: origin, size: size)
            calls += errs.count
            errors += errs.filter { $0 != .success }.count
            if errs.contains(.invalidUIElement) { gone = true }
        }
        let dt = CACurrentMediaTime() - t0
        // Só a parte dentro da tela conta: estacionadas empilhadas fora da tela não aparecem.
        let rects = current.values.map { $0.intersection(screen) }.filter { !$0.isNull }
        var overlap = false
        for i in rects.indices where !overlap {
            for j in rects.indices where j > i {
                let x = rects[i].intersection(rects[j])
                if !x.isNull && x.width > 2 && x.height > 2 { overlap = true; break }
            }
        }
        let now = CACurrentMediaTime()
        lock.lock()
        if overlap { stats.overlapFrames += 1 }
        if stats.lastDrain > 0 { stats.maxGap = max(stats.maxGap, now - stats.lastDrain) }
        stats.lastDrain = now
        stats.frames += 1
        stats.calls += calls
        stats.errors += errors
        stats.seconds += dt
        lock.unlock()
        if gone { requestScan() }
    }

    /// Ordem de aplicação dentro do frame: primeiro quem vai pra um lugar já livre.
    /// Ex.: coluna cresce e empurra a vizinha; se a coluna crescer antes da vizinha sair,
    /// as duas se sobrepõem por um frame. Só resolve entre janelas do mesmo app (cada app
    /// tem sua fila, sem ordem entre filas).
    private func orderedToAvoidOverlap(_ batch: [CGWindowID: CGRect], screen: CGRect) -> [(CGWindowID, CGRect)] {
        var occupied = current.mapValues { $0.intersection(screen) }
        var todo = batch.map { ($0.key, $0.value) }
        var out: [(CGWindowID, CGRect)] = []
        out.reserveCapacity(todo.count)
        func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
            let i = a.intersection(b)
            return !i.isNull && i.width > 2 && i.height > 2  // fatias de 1 pt na borda não contam
        }
        while !todo.isEmpty {
            let free = todo.firstIndex { op in
                !occupied.contains { $0.key != op.0 && overlaps($0.value, op.1) }
            }
            guard let i = free else {
                out += todo  // ciclo (troca de lugar): sem ordem perfeita, aplica o resto
                break
            }
            let op = todo.remove(at: i)
            occupied[op.0] = op.1.intersection(screen)
            out.append(op)
        }
        return out
    }

    /// AXEnhancedUserInterface ligado faz Chrome/Electron animarem cada mudança de frame
    /// por conta própria, o que trava a nossa animação. Desliga uma vez e devolve ao sair.
    private func disableEnhancedUIIfNeeded() {
        guard !enhancedUIChecked else { return }
        enhancedUIChecked = true
        if AX.bool(app, "AXEnhancedUserInterface") == true {
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
            enhancedUIWasOn = true
        }
    }

    /// Frame real de cada janela, lido do app (pra conferir o que foi aplicado).
    func readFrames(_ ids: [CGWindowID], completion: @escaping ([CGWindowID: CGRect]) -> Void) {
        queue.async {
            var out: [CGWindowID: CGRect] = [:]
            for id in ids {
                guard let el = self.elements[id],
                      let p = AX.point(AX.copy(el, kAXPositionAttribute)),
                      let s = AX.size(AX.copy(el, kAXSizeAttribute)) else { continue }
                out[id] = CGRect(origin: p, size: s)
            }
            DispatchQueue.main.async { completion(out) }
        }
    }

    func takeStats() -> Stats {
        lock.lock()
        defer { stats = Stats(); lock.unlock() }
        return stats
    }

    /// Usado ao sair: aplica e avisa o grupo quando terminar.
    func applyNow(_ frames: [(CGWindowID, CGRect)], group: DispatchGroup) {
        group.enter()
        queue.async {
            for (id, r) in frames {
                guard let el = self.elements[id] else { continue }
                _ = AX.setPosition(el, r.origin)
                _ = AX.setSize(el, r.size)
                _ = AX.setPosition(el, r.origin)
            }
            if self.enhancedUIWasOn {
                AXUIElementSetAttributeValue(self.app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            }
            group.leave()
        }
    }
}

private let axCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    Unmanaged<AppWorker>.fromOpaque(refcon).takeUnretainedValue().notify(notification as String, element: element)
}

/// Atalhos pra API de Acessibilidade em C.
enum AX {
    static func copy(_ el: AXUIElement, _ attr: String) -> AnyObject? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v
    }

    static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = copy(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func bool(_ el: AXUIElement, _ attr: String) -> Bool? {
        copy(el, attr) as? Bool
    }

    private static func axValue(_ v: AnyObject?, _ type: AXValueType) -> AXValue? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        let ax = v as! AXValue
        return AXValueGetType(ax) == type ? ax : nil
    }

    /// `AXUIElementCopyMultipleAttributeValues` devolve erro como AXValue do tipo .axError.
    static func isError(_ v: AnyObject?) -> Bool { axValue(v, .axError) != nil }

    static func point(_ v: AnyObject?) -> CGPoint? {
        guard let ax = axValue(v, .cgPoint) else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(ax, .cgPoint, &p) ? p : nil
    }

    static func size(_ v: AnyObject?) -> CGSize? {
        guard let ax = axValue(v, .cgSize) else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(ax, .cgSize, &s) ? s : nil
    }

    static func setPosition(_ el: AXUIElement, _ p: CGPoint) -> AXError {
        var p = p
        return AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &p)!)
    }

    static func setSize(_ el: AXUIElement, _ s: CGSize) -> AXError {
        var s = s
        return AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &s)!)
    }
}
