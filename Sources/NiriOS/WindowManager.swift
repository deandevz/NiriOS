import AppKit
import NiriCore
import QuartzCore

/// Modo de teste: um app só, numa área pequena, com uma sequência de ações no lugar do teclado.
/// Dá pra testar com o OmniWM rodando, sem tocar nas outras janelas.
struct DevOptions {
    var pid: pid_t?
    var area: CGRect?
    var script: [Action] = []
}

/// Dono do estado. Tudo aqui roda na main; chamadas de Acessibilidade vão pras filas dos apps.
final class WindowManager: NSObject {
    private(set) var config: Config
    private let verbose: Bool
    private let dev: DevOptions
    private var layout: Layout
    private var workers: [pid_t: AppWorker] = [:]
    /// Janelas na fita: de qual app são e o elemento AX (usado pra focar).
    private var tracked: [CGWindowID: (pid: pid_t, element: AXUIElement)] = [:]
    private let focuser = FocusController()
    /// Foco que pedimos e o macOS ainda não confirmou. Eventos de foco de outras janelas nesse
    /// meio-tempo são ecos de pedidos antigos e são ignorados; senão o layout "volta sozinho".
    private var pendingFocus: (window: CGWindowID, time: Double)?
    /// Janela que cada app considera a sua focada (do scan e dos eventos de foco do app).
    /// Se é a mesma que vamos focar, ativar o app basta (ver `Private.focus`).
    private var appFocus: [pid_t: CGWindowID] = [:]
    private var link: CADisplayLink?
    private var started = false
    private var initialScans: [pid_t: ScanResult] = [:]
    private var animationStart = 0.0
    private var ticks = 0
    private var lastTick = 0.0
    private var maxTickGap = 0.0
    private lazy var hotkeys: HotkeyTap = {
        let tap = HotkeyTap(verbose: verbose) { [weak self] in self?.perform($0) }
        tap.setShortcuts(config.shortcuts)
        tap.onModifiers = { [weak self] down in self?.modifiersChanged(down) }
        return tap
    }()

    init(config: Config, verbose: Bool, dev: DevOptions = DevOptions()) {
        self.config = config
        self.verbose = verbose
        self.dev = dev
        // No teste, a borda continua sendo a da tela de verdade (janela sai e estaciona igual ao
        // uso normal). Sem --area, usa uma faixa da largura toda no pé da tela.
        var geo = Self.screenGeometry(config)
        if dev.pid != nil {
            geo.area = dev.area ?? CGRect(x: geo.area.minX, y: geo.area.maxY - 340, width: geo.area.width, height: 340)
        }
        self.layout = Layout(area: geo.area, bounds: geo.bounds, config: config.layout)
        super.init()
    }

    /// Área útil e tela inteira, em coordenadas AX (origem no topo esquerdo da tela principal).
    /// MVP: só a tela principal.
    private static func screenGeometry(_ c: Config) -> (area: CGRect, bounds: CGRect) {
        let screen = NSScreen.screens[0]
        let h = screen.frame.height
        func toAX(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height) }
        let vis = toAX(screen.visibleFrame)
        let area = CGRect(x: vis.minX + c.gap,
                          y: vis.minY + c.gap + c.topPadding,
                          width: vis.width - 2 * c.gap,
                          height: vis.height - 2 * c.gap - c.topPadding - c.bottomPadding)
        return (area, toAX(screen.frame))
    }

    /// Config recarregada (arquivo salvo ou painel). Atalhos e borda do vidro valem na hora; gap, margens,
    /// mola e centralização animam as janelas pro layout novo. `resizeStyle` e `axTimeout` só ao reiniciar.
    func apply(_ c: Config) {
        let old = config
        config = c
        hotkeys.setShortcuts(c.shortcuts)
        ghost?.border = (c.ghostBorderColor, c.ghostBorderWidth)
        if c.resizeStyle != old.resizeStyle || c.axTimeout != old.axTimeout {
            log("config: resizeStyle e axTimeout mudam só ao reiniciar o niri-os")
        }
        guard dev.pid == nil else { return }
        let now = CACurrentMediaTime(), geo = Self.screenGeometry(c)
        guard c.layout != layout.config || geo.area != layout.area else { return }
        layout.setConfig(c.layout, at: now)
        layout.setArea(geo.area, bounds: geo.bounds, at: now)
        animate()
    }

    /// Painel de configurações fechado: o teclado volta pra janela focada da fita.
    func refocus() {
        if let f = layout.focusedWindow { requestFocus(f) }
    }

    /// O painel pausa os atalhos enquanto grava um novo: senão o tap engoliria a combinação.
    var shortcutsPaused: Bool {
        get { hotkeys.paused }
        set { hotkeys.paused = newValue }
    }

    // MARK: - Ciclo de vida

    func start() {
        guard dev.pid != nil || hotkeys.start() else {
            log("não consegui criar o tap de teclado (permissão de Acessibilidade?)")
            exit(1)
        }
        let link = NSScreen.screens[0].displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        link.isPaused = true
        self.link = link
        _ = transition  // a janela da transição já fica pronta na tela, vazia
        _ = ghost

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.addApp(app)
        }
        ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.removeApp(app.processIdentifier)
        }
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            // Rescan aqui também: se algum evento de janela se perdeu, ativar o app corrige.
            self?.workers[app.processIdentifier]?.requestScan()
            self?.workers[app.processIdentifier]?.reportFocusedWindow()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screenChanged()
        }

        for app in NSWorkspace.shared.runningApplications { addApp(app) }
        // App que não respondeu até aqui entra depois, como janela nova.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.finishStartup() }
    }

    private func addApp(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        if let only = dev.pid {
            guard pid == only, workers[pid] == nil else { return }
        } else {
            guard app.activationPolicy == .regular, pid != getpid(), workers[pid] == nil else { return }
        }
        let w = AppWorker(pid: pid, name: app.localizedName ?? "pid \(pid)", timeout: config.axTimeout,
                          anySubrole: dev.pid != nil)
        w.onScan = { [weak self] pid, result in self?.scanned(pid, result) }
        w.onFocus = { [weak self] pid, id in self?.focusChanged(pid, id) }
        workers[pid] = w
        w.start()
    }

    private func removeApp(_ pid: pid_t) {
        guard let w = workers.removeValue(forKey: pid) else { return }
        w.stop()
        initialScans[pid] = nil
        appFocus[pid] = nil
        let gone = tracked.filter { $0.value.pid == pid }.map(\.key)
        guard !gone.isEmpty else { return }
        let wasFocused = layout.focusedWindow
        let now = CACurrentMediaTime()
        for id in gone {
            tracked[id] = nil
            layout.remove(id, at: now)
        }
        if let f = layout.focusedWindow, f != wasFocused { requestFocus(f) }
        animate()
    }

    private func scanned(_ pid: pid_t, _ result: ScanResult) {
        guard workers[pid] != nil else { return }
        if let f = result.focused { appFocus[pid] = f }
        if !started {
            initialScans[pid] = result
            if initialScans.count == workers.count { finishStartup() }
        } else {
            sync(pid, result)
        }
    }

    /// Monta a fita com as janelas que já estavam abertas, na ordem em que aparecem na tela,
    /// mantendo a largura de cada uma (arredondada pro passo de resize).
    private func finishStartup() {
        guard !started else { return }
        started = true
        let all = initialScans
            .flatMap { pid, r in (r.windows ?? []).filter(\.tileable).map { (pid, $0) } }
            .sorted { ($0.1.frame.minX, $0.1.id) < ($1.1.frame.minX, $1.1.id) }
        // Reinício: as janelas que continuam abertas voltam na mesma ordem e largura.
        let byID = Dictionary(all.map { ($0.1.id, $0) }, uniquingKeysWith: { a, _ in a })
        var restored: Set<CGWindowID> = []
        for c in (dev.pid == nil ? Self.loadState() : []) {
            guard let (pid, w) = byID[c.window] else { continue }
            tracked[w.id] = (pid, w.element)
            layout.append(w.id, proportion: c.proportion, savedProportion: c.saved, minWidth: c.minWidth)
            restored.insert(w.id)
        }
        for (pid, w) in all where !restored.contains(w.id) {
            tracked[w.id] = (pid, w.element)
            layout.append(w.id, proportion: layout.proportion(forWidth: w.frame.width, step: config.widthStep))
        }
        if !restored.isEmpty { log("\(restored.count) janelas restauradas na ordem salva") }
        let now = CACurrentMediaTime()
        // Foco na janela do app da frente. Se ele não informar a janela focada pela Acessibilidade,
        // vale a 1ª janela dele na fita.
        if let pid = Self.frontPid(),
           let f = initialScans[pid]?.focused.flatMap({ tracked[$0] != nil ? $0 : nil })
               ?? layout.windows.first(where: { tracked[$0]?.pid == pid }) {
            layout.focus(f, at: now)
        }
        if verbose, let f = layout.focusedWindow, let t = tracked[f] {
            log("foco inicial: \(workers[t.pid]?.name ?? "?") (janela \(f))")
        }
        layout.retarget(at: now)
        layout.snapToTargets()
        initialScans = [:]
        log("\(all.count) janelas na fita, \(workers.count) apps observados")
        animate()
        if !dev.script.isEmpty { runScript() }
    }

    /// Dono da janela normal mais à frente na tela. Logo depois de abrir, o NSWorkspace ainda diz que o
    /// app da frente é o próprio niri-os, e o foco inicial caía na 1ª coluna.
    private static func frontPid() -> pid_t? {
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        let front = list.first { ($0[kCGWindowLayer as String] as? Int) == 0 && ($0[kCGWindowOwnerPID as String] as? pid_t) != getpid() }
        return front?[kCGWindowOwnerPID as String] as? pid_t ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    /// Executa as ações do --script com 0,6 s entre elas, confere o resultado e sai.
    private func runScript() {
        for (i, action) in dev.script.enumerated() {
            // Experimento global: simula o Option descendo 100 ms antes, como numa tecla de verdade.
            if transition != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 * Double(i + 1) - 0.1) { self.prefetchPhotos(true) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 * Double(i + 1)) {
                log("ação: \(action)")
                self.perform(action)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 * Double(dev.script.count + 1) + 0.4) {
            self.verifyAndExit()
        }
    }

    private func verifyAndExit() {
        let expected = layout.frames(at: CACurrentMediaTime())
        let group = DispatchGroup()
        var actual: [CGWindowID: CGRect] = [:]
        for w in workers.values {
            group.enter()
            w.readFrames(expected.map(\.window)) { r in
                actual.merge(r) { a, _ in a }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            var bad = 0
            for f in expected {
                let a = actual[f.window]
                let ok = a == f.rect
                if !ok { bad += 1 }
                log("janela \(f.window): esperado \(f.rect)  real \(a.map { "\($0)" } ?? "?")  \(ok ? "ok" : "DIFERENTE")")
            }
            log(bad == 0 ? "verificação: tudo no lugar" : "verificação: \(bad) janela(s) fora do lugar")
            self.saveState()  // modo normal: sai como o SIGUSR1, janelas onde estão
            exit(bad == 0 ? 0 : 2)
        }
    }

    /// Diferença entre o que o app tem agora e o que está na fita.
    private func sync(_ pid: pid_t, _ result: ScanResult) {
        guard let windows = result.windows else { return }  // app não respondeu: não mexe em nada
        let now = CACurrentMediaTime()
        let tileable = windows.filter(\.tileable)
        let current = Set(tileable.map(\.id))
        let uncertain = Set(windows.filter(\.uncertain).map(\.id))
        let known = Set(tracked.filter { $0.value.pid == pid }.map(\.key))
        let removed = known.subtracting(current).subtracting(uncertain)
        let wasFocused = layout.focusedWindow
        var changed = false

        for id in removed {
            tracked[id] = nil
            layout.remove(id, at: now)
            changed = true
        }
        let isFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        var added: Set<CGWindowID> = []
        for w in tileable.sorted(by: { $0.frame.minX < $1.frame.minX }) {
            if known.contains(w.id) {
                tracked[w.id] = (pid, w.element)
                continue
            }
            tracked[w.id] = (pid, w.element)
            // Como no niri: janela nova entra à direita da focada e ganha foco (se o app está na frente).
            layout.insert(w.id, focus: isFront || result.focused == w.id, at: now)
            added.insert(w.id)
            changed = true
        }
        guard changed else { return }
        if verbose { log("\(workers[pid]?.name ?? "?"): +\(added.count) -\(removed.count) janelas") }
        // A focada fechou: o foco vai pra vizinha que o layout escolheu, não pra onde o macOS quiser.
        if let f = layout.focusedWindow, f != wasFocused, !added.contains(f) { requestFocus(f) }
        animate()
    }

    private func focusChanged(_ pid: pid_t, _ id: CGWindowID) {
        appFocus[pid] = id
        let now = CACurrentMediaTime()
        if let p = pendingFocus {
            if p.window == id {
                pendingFocus = nil
            } else if now - p.time < 0.5 {
                return
            } else {
                pendingFocus = nil
            }
        }
        guard tracked[id] != nil, layout.focusedWindow != id else { return }
        layout.focus(id, at: now)
        animate()
    }

    private func screenChanged() {
        guard dev.pid == nil else { return }
        let geo = Self.screenGeometry(config)
        guard geo.area != layout.area || geo.bounds != layout.bounds else { return }
        layout.setArea(geo.area, bounds: geo.bounds, at: CACurrentMediaTime())
        animate()
    }

    // MARK: - Ações

    private func perform(_ action: Action) {
        guard global == nil else { queuedAction = action; return }  // roda quando a transição acabar
        let now = CACurrentMediaTime()
        switch action {
        case .focusLeft, .focusRight:
            // Tecla de novo com a fita andando: só rola, e o app onde ela parar é ativado quando assentar.
            // App ativado ou desativado redesenha e para de responder AX; ativando cada app atravessado,
            // as janelas dele congelavam no meio da rolagem (spam de 6 s, maior intervalo: Arc 403 ms,
            // outro app 326, WhatsApp 208; a main em 8,7).
            // Experimento NIRI_FOCUS_DELAY (ms): com a fita parada, a rolagem começa esse tanto depois
            // da tecla, o tempo do app que ganha ou perde foco se redesenhar (WhatsApp: 25 a 45 ms).
            let moving = link?.isPaused == false
            guard let id = layout.focusNeighbor(action == .focusLeft ? -1 : 1, at: now + (moving ? 0 : focusDelay)) else {
                if verbose { log("ação \(action): já está na ponta da fita") }
                return
            }
            if verbose, let t = tracked[id] { log("ação \(action): foco em \(workers[t.pid]?.name ?? "?") (janela \(id))\(moving ? ", ativa ao assentar" : "")") }
            if moving { deferFocus(id) } else { requestFocus(id) }
        case .grow, .shrink, .toggleFullWidth:
            if transition != nil, startGlobal(action, at: now) { return }
            if ghost != nil { resizeWithGhost(action, at: now) } else { resize(&layout, action, at: now) }
        }
        animate()
    }

    private func resize(_ l: inout Layout, _ action: Action, at t: Double) {
        switch action {
        case .grow, .shrink:
            let dir = action == .grow ? 1 : -1
            if config.widthPresets.isEmpty { l.resizeFocused(by: Double(dir) * config.widthStep, at: t) }
            else { l.resizeFocused(toPresetIn: config.widthPresets, direction: dir, at: t) }
        case .toggleFullWidth: l.toggleFullWidthFocused(at: t)
        case .focusLeft, .focusRight: break
        }
    }

    // MARK: - Transição do resize (ver TransitionOverlay)

    /// Precisa de Gravação de Tela (pra fotografar as janelas); sem ela, o resize anima as janelas
    /// reais direto, como antes. Só com `"resizeStyle": "photos"`.
    private lazy var transition: TransitionOverlay? = {
        guard config.resizeStyle == .photos, dev.pid == nil else { return nil }
        guard CGPreflightScreenCaptureAccess() else {
            log("sem permissão de Gravação de Tela: resize sem a transição por fotos")
            return nil
        }
        return TransitionOverlay(screen: NSScreen.screens[0])
    }()
    /// Transição em andamento: janelas desenhadas por nós, a que muda de tamanho e se ela já voltou.
    private struct Global {
        let windows: [CGWindowID], morph: CGWindowID
        let action: Action
        /// `running`: camada na tela. `animating`: a fita já começou a andar (só depois que o app
        /// entrega o tamanho novo, como o niri espera o commit).
        var running = false, animating = false, settled = false
        var latestLive: CGImage?
        /// Quando o app devolveu o resize, e quando saiu a última captura estável (igual à anterior).
        var appliedAt = Double.infinity, stableAt = 0.0
        /// Pro log (-v): a tecla e as capturas ao vivo (ms desde a tecla, t = da tela ou j = da janela,
        /// diferença pra anterior em 255, * = estável).
        var t0 = 0.0, trace = ""
    }
    private var global: Global?
    /// Tecla que chegou durante a transição; roda quando ela acabar.
    private var queuedAction: Action?
    /// Fotos tiradas quando o Option desceu, antes da tecla: o atraso da transição cai pra ~1 frame.
    /// Valem só pro layout daquele momento (`layoutVersion`) e somem quando o Option sobe.
    private var prefetched: (version: Int, photos: [CGWindowID: TransitionOverlay.Photo], background: CGImage?)?
    private var prefetchVersion = 0
    private var layoutVersion = 0
    /// Os modificadores de um atalho apertados (no padrão, o Option).
    private var modifiersHeld = false

    private func modifiersChanged(_ down: Bool) {
        modifiersHeld = down
        if transition != nil { prefetchPhotos(down) }
        if !down { returnGhosts() }  // ver `step`
    }

    private func prefetchPhotos(_ optionDown: Bool) {
        prefetchVersion += 1
        guard optionDown, global == nil, link?.isPaused == true, let below = transition?.windowID else { prefetched = nil; return }
        let ticket = prefetchVersion, version = layoutVersion
        let screen = layout.bounds.insetBy(dx: 2, dy: 0), bounds = layout.bounds
        let visible = layout.frames(at: CACurrentMediaTime()).filter { tracked[$0.window] != nil && $0.rect.intersects(screen) }
        DispatchQueue.global(qos: .userInteractive).async {
            var photos: [CGWindowID: TransitionOverlay.Photo] = [:]
            for f in visible { photos[f.window] = TransitionOverlay.photo(f.window, at: f.rect, screen: bounds) }
            // Fundo sem as visíveis: vale se a tecla não trouxer pra tela uma estacionada.
            let background = TransitionOverlay.captureBackground(below: below, drawn: Set(visible.map(\.window)), in: bounds)
            DispatchQueue.main.async {
                guard ticket == self.prefetchVersion, version == self.layoutVersion else { return }
                self.prefetched = (version, photos, background)
            }
        }
    }

    /// Fotos de tudo que aparece na área (no começo ou no fim), camada nossa por cima idêntica à tela,
    /// janelas reais direto pro lugar final por baixo, e a fita anima as fotos.
    private func startGlobal(_ action: Action, at now: Double) -> Bool {
        guard let transition, link?.isPaused == true, global == nil,
              let id = layout.focusedWindow, tracked[id] != nil else { return false }
        var next = layout
        resize(&next, action, at: now)
        next.snapToTargets()
        let start = Dictionary(uniqueKeysWithValues: layout.frames(at: now).map { ($0.window, $0.rect) })
        let end = Dictionary(uniqueKeysWithValues: next.frames(at: now).map { ($0.window, $0.rect) })
        guard let from = start[id], let to = end[id], from.size != to.size else { return false }
        // Janelas que aparecem no começo ou no fim (as estacionadas que continuam estacionadas, não).
        let screen = layout.bounds.insetBy(dx: 2, dy: 0)
        var ids = layout.windows.filter { w in
            tracked[w] != nil && [start[w], end[w]].contains { $0.map { $0.intersects(screen) } ?? false }
        }
        ids.removeAll { $0 == id }
        ids.append(id)  // a que muda de tamanho fica por cima
        global = Global(windows: ids, morph: id, action: action, t0: now)
        let ready = prefetched.flatMap { $0.version == layoutVersion ? $0 : nil }
        prefetched = nil
        let bounds = layout.bounds, below = transition.windowID
        DispatchQueue.global(qos: .userInteractive).async {
            // O que não veio da foto antecipada é tirado agora (20 a 35 ms cada; em paralelo não acelera).
            let photos = ids.map { ready?.photos[$0] ?? TransitionOverlay.photo($0, at: start[$0]!, screen: bounds) }
            let background = ready.flatMap { Set($0.photos.keys) == Set(ids) ? $0.background : nil }
                ?? TransitionOverlay.captureBackground(below: below, drawn: Set(ids), in: bounds)
            let tCaptured = CACurrentMediaTime()
            DispatchQueue.main.async {
                let tMain = CACurrentMediaTime()
                let shown = zip(ids, photos).compactMap { w, p in p.map { (id: w, photo: $0, frame: start[w]!, active: w == id) } }
                guard shown.count == ids.count else { self.global = nil; self.resize(&self.layout, action, at: CACurrentMediaTime()); self.animate(); return }
                transition.show(background: background, windows: shown)
                CATransaction.flush()
                if self.verbose {
                    let ms = { (t: Double) in String(format: "%.0f", (t - now) * 1000) }
                    log("global: \(ids.count) janelas; fotos prontas aos \(ms(tCaptured)) ms, main aos \(ms(tMain)), camada enviada aos \(ms(CACurrentMediaTime()))")
                }
                // A animação espera o app entregar o tamanho novo (como o niri espera o commit). As
                // janelas reais vão pro lugar final 2 frames depois, quando a camada já está na tela
                // (com 1 frame, às vezes dava pra ver as janelas reais pulando).
                self.global?.running = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.034) {
                    for w in ids {
                        guard let tw = self.tracked[w], let r = end[w] else { continue }
                        self.workers[tw.pid]?.placeHidden(w, at: r) {
                            guard w == id else { self.captureAhead(w, at: r); return }
                            self.global?.appliedAt = CACurrentMediaTime()
                            // Limite do niri pra esperar o app: 300 ms. Depois disso anima com o que tiver.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                guard let g = self.global, g.morph == id, g.running, !g.animating else { return }
                                if let img = g.latestLive { self.transition?.setLive(id, img) }
                                if self.verbose { self.global?.trace += " | 300 ms" }
                                self.startGlobalAnimation()
                            }
                            self.finishGlobalIfDone()
                        }
                    }
                    self.liveCaptureGlobal(id, at: to)
                }
            }
        }
        return true
    }

    /// Capturas seguidas da janela que muda de tamanho. Só entra na tela a captura igual à anterior:
    /// Chromium/Electron redimensionam e desenham depois, e uma captura no meio disso (meio branca ou
    /// preta) aparecia como piscada no corte.
    /// Depois que a janela chegou em `r` (o lugar final), a captura vem da tela, com o fundo translúcido
    /// certo; antes disso, ou se ela não cabe inteira na tela, da janela.
    private func liveCaptureGlobal(_ id: CGWindowID, at r: CGRect, last: [UInt8]? = nil) {
        let placed = (global?.appliedAt ?? .infinity) < .infinity && layout.bounds.contains(r)
        DispatchQueue.global(qos: .userInteractive).async {
            let img = (placed ? Private.captureShown(id, in: r) : nil) ?? Private.capture(id)
            let sig = img.map(TransitionOverlay.signature)
            let diff = sig.flatMap { s in last.map { TransitionOverlay.difference($0, s) } } ?? -1
            let stable = diff >= 0 && diff < 1  // `TransitionOverlay.same`
            DispatchQueue.main.async {
                guard let g = self.global, g.morph == id, g.running else { return }
                self.global?.latestLive = img
                if self.verbose { self.global?.trace += String(format: " %.0f%@%.1f%@", (CACurrentMediaTime() - g.t0) * 1000, placed ? "t" : "j", diff, stable ? "*" : "") }
                if stable, let img {
                    self.transition?.setLive(id, img)
                    self.global?.stableAt = CACurrentMediaTime()
                    // A fita espera a imagem nova pronta pra começar.
                    if !g.animating, g.appliedAt < .infinity, self.global!.stableAt > g.appliedAt { self.startGlobalAnimation() }
                    self.finishGlobalIfDone()
                }
                self.liveCaptureGlobal(id, at: r, last: sig)
            }
        }
    }

    /// Vizinha já no lugar final, por baixo da camada: a parte que vai estar na tela no fim, tirada da
    /// tela 1 frame depois (tempo do WindowServer mover a janela).
    private func captureAhead(_ w: CGWindowID, at r: CGRect) {
        let area = r.intersection(layout.bounds)
        guard area.width >= 1 else { return }
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.017) {
            guard let img = Private.captureShown(w, in: area) else { return }
            DispatchQueue.main.async {
                guard self.global?.running == true, self.global?.windows.contains(w) == true else { return }
                self.transition?.setAhead(w, img, area: area, frame: r)
            }
        }
    }

    private func startGlobalAnimation() {
        guard let g = global, !g.animating else { return }
        if verbose { global?.trace += String(format: " | anima %.0f |", (CACurrentMediaTime() - g.t0) * 1000) }
        global?.animating = true
        resize(&layout, g.action, at: CACurrentMediaTime())
        animate()
    }

    /// Fim: animação assentada, a janela que mudou de tamanho já devolveu e já tem captura estável
    /// (a última camada bate com a janela real). Devolve as janelas e 2 frames depois a camada sai.
    private func finishGlobalIfDone() {
        guard let g = global, g.running, g.settled, g.appliedAt < .infinity else { return }
        // Espera uma captura estável tirada depois do resize; vídeo tocando nunca estabiliza: 250 ms.
        let now = CACurrentMediaTime()
        if g.stableAt < g.appliedAt && now - g.appliedAt < 0.25 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 - (now - g.appliedAt)) { self.finishGlobalIfDone() }
            return
        }
        global?.running = false
        let finals = Dictionary(uniqueKeysWithValues: layout.frames(at: now).map { ($0.window, $0.rect) })
        transition?.update([:], morph: g.morph)
        let group = DispatchGroup()
        for w in g.windows {
            guard let tw = tracked[w], let r = finals[w] else { continue }
            group.enter()
            workers[tw.pid]?.attach(w, at: r) { group.leave() }
        }
        let bounds = layout.bounds, lastLive = transition?.liveImage(g.morph)
        group.notify(queue: .main) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.034) {
                // A parte na tela de cada janela, de novo, no lugar final (~10 a 20 ms cada).
                DispatchQueue.global(qos: .userInteractive).async {
                    var shown: [CGWindowID: (img: CGImage, area: CGRect, frame: CGRect)] = [:]
                    for w in g.windows {
                        guard let r = finals[w], case let area = r.intersection(bounds), area.width >= 1,
                              let img = Private.captureShown(w, in: area) else { continue }
                        shown[w] = (img, area, r)
                    }
                    // Quanto a última imagem ao vivo difere da tela no fim (o salto que o fade suaviza).
                    var endDiff: Double?
                    if self.verbose, let a = lastLive, let b = shown[g.morph]?.img {
                        endDiff = TransitionOverlay.difference(TransitionOverlay.signature(a), TransitionOverlay.signature(b))
                    }
                    DispatchQueue.main.async {
                        if self.verbose { log("ao vivo:\(g.trace) fim: imagem ao vivo x tela \(endDiff.map { String(format: "%.1f", $0) } ?? "?")") }
                        self.transition?.setShown(shown)
                        self.transition?.hide {
                            self.global = nil
                            if let a = self.queuedAction { self.queuedAction = nil; self.perform(a) }
                            // Option ainda apertado: a próxima tecla provavelmente é outro +/-.
                            else if self.modifiersHeld { self.prefetchPhotos(true) }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Resize fantasma (ver GhostOverlay)

    private lazy var ghost: GhostOverlay? = {
        guard config.resizeStyle == .ghost else { return nil }
        let g = GhostOverlay(screen: NSScreen.screens[0])
        g.border = (config.ghostBorderColor, config.ghostBorderWidth)
        return g
    }()
    /// Janelas esperando fora da tela enquanto o vidro anda no lugar delas.
    private var ghosted: Set<CGWindowID> = []

    /// O vidro entra no lugar da janela focada e ela espera fora da tela até a fita parar
    /// (`finishGhosts`). Outra tecla no meio só muda o alvo da fita: o vidro segue, a janela não volta.
    private func resizeWithGhost(_ action: Action, at now: Double) {
        let id = layout.focusedWindow, before = finalFrame(id)
        resize(&layout, action, at: now)
        guard let ghost, let id, let t = tracked[id], let to = finalFrame(id), to.size != before?.size,
              let r = layout.frames(at: now).first(where: { $0.window == id })?.rect else { return }
        ghost.show(id, of: t.pid, at: r)
        guard ghosted.insert(id).inserted else { return }
        CATransaction.flush()  // o vidro entra antes de a janela sair
        workers[t.pid]?.park(id, at: CGPoint(x: layout.bounds.maxX - layout.config.sliver, y: r.minY),
                             shrinkTo: to.width < r.width ? to.size : nil)
    }

    /// Onde a janela fica quando a fita parar.
    private func finalFrame(_ id: CGWindowID?) -> CGRect? {
        var l = layout
        l.snapToTargets()
        return l.frames(at: 0).first { $0.window == id }?.rect
    }

    /// Fita parada: as janelas escondidas voltam no lugar e tamanho finais, por baixo do vidro, e o vidro
    /// some depois que o app teve tempo de redesenhar.
    private func finishGhosts(_ frames: [WindowFrame]) {
        for id in ghosted {
            guard let t = tracked[id], let w = workers[t.pid], let r = frames.first(where: { $0.window == id })?.rect else {
                ghost?.fadeOut(id)  // fechou no meio
                continue
            }
            w.attach(id, at: r) {
                self.whenDrawn(id, width: r.width) {
                    // Alguns apps ainda se reorganizam depois de 50 ms parados, e isso aparecia no fade.
                    DispatchQueue.main.asyncAfter(deadline: .now() + GhostOverlay.hold) {
                        if !self.ghosted.contains(id) { self.ghost?.fadeOut(id) }  // senão outra tecla escondeu de novo
                    }
                }
            }
        }
        ghosted = []
    }

    private lazy var canCapture = CGPreflightScreenCaptureAccess()

    /// `done` quando o app terminou de redesenhar no tamanho novo. Com tempo fixo, o vidro sumia com a
    /// página do Arc ainda se reorganizando e o texto do WezTerm refluindo. Terminou = a captura da janela
    /// já tem a largura final (o app entregou o tamanho novo) e não muda há 50 ms. Sem Gravação de Tela,
    /// espera fixa de 300 ms.
    private func whenDrawn(_ id: CGWindowID, width: Double, since t0: Double = CACurrentMediaTime(),
                           last: (sig: [UInt8], at: Double)? = nil, done: @escaping () -> Void) {
        guard canCapture else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: done); return }
        let now = CACurrentMediaTime()
        let ms = String(format: "%.0f ms", (now - t0) * 1000)
        if let last, now - last.at >= 0.05 {
            if verbose { log("vidro: janela \(id) pronta em \(ms)") }
            return done()
        }
        guard now - t0 < GhostOverlay.maxWait, !ghosted.contains(id) else {
            if verbose && !ghosted.contains(id) { log("vidro: janela \(id) ainda desenhando aos \(ms), sai assim mesmo") }
            return done()
        }
        let px = width * NSScreen.screens[0].backingScaleFactor
        DispatchQueue.global(qos: .userInteractive).async {
            let sig = Private.capture(id).flatMap { abs(Double($0.width) - px) <= 2 ? TransitionOverlay.signature($0) : nil }
            DispatchQueue.main.async {
                // Igual à anterior: continua contando desde ela. Diferente (ou ainda no tamanho velho): recomeça.
                let same = sig != nil && last.map { TransitionOverlay.same($0.sig, sig!) } == true
                self.whenDrawn(id, width: width, since: t0, last: same ? last : sig.map { ($0, CACurrentMediaTime()) }, done: done)
            }
        }
    }

    private let focusDelay = (ProcessInfo.processInfo.environment["NIRI_FOCUS_DELAY"].flatMap(Double.init) ?? 0) / 1000
    /// Foco que espera a fita assentar (ver `perform`).
    private var deferredFocus: CGWindowID?

    /// Enquanto espera, eventos de foco de outros apps são eco (senão o foco da 1ª tecla puxaria o
    /// layout de volta no meio do spam).
    private func deferFocus(_ id: CGWindowID) {
        deferredFocus = id
        pendingFocus = (id, CACurrentMediaTime())
    }

    private func requestFocus(_ id: CGWindowID) {
        deferredFocus = nil
        guard let t = tracked[id] else { return }
        if dev.pid != nil { return }  // teste não rouba o foco de quem está usando o Mac
        pendingFocus = (id, CACurrentMediaTime())
        focuser.request(pid: t.pid, window: id, element: t.element, switchWindow: appFocus[t.pid] != id)
        // Se o usuário clicou em outra janela enquanto o pedido estava pendente, o clique foi
        // ignorado como eco. Confere o foco real quando a janela de proteção expira.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
            self?.workers[pid]?.reportFocusedWindow()
        }
    }

    // MARK: - Animação

    private func animate() {
        layoutVersion += 1
        scheduleSave()
        guard let link else { return }
        if link.isPaused {
            animationStart = CACurrentMediaTime()
            ticks = 0
            lastTick = 0
            maxTickGap = 0
            link.isPaused = false
        }
        step()  // primeiro frame já, sem esperar o próximo vsync
    }

    @objc private func tick(_ link: CADisplayLink) {
        step()
    }

    private func step() {
        let now = CACurrentMediaTime()
        let settled = layout.isSettled(at: now)
        if settled { layout.snapToTargets() }

        var byApp: [pid_t: [(CGWindowID, CGRect)]] = [:]
        let frames = layout.frames(at: now)
        for f in frames {
            if let t = tracked[f.window] { byApp[t.pid, default: []].append((f.window, f.rect)) }
        }
        for (pid, frames) in byApp { workers[pid]?.submit(frames, screen: layout.bounds, firstFrame: ticks == 0) }
        ghost?.update(frames)
        if let g = global, g.running {
            let fr = Dictionary(uniqueKeysWithValues: frames.filter { g.windows.contains($0.window) }.map { ($0.window, $0.rect) })
            transition?.update(fr, morph: g.morph)
            if settled && g.animating { global?.settled = true; finishGlobalIfDone() }
        }
        ticks += 1
        if lastTick > 0 { maxTickGap = max(maxTickGap, now - lastTick) }
        lastTick = now

        if settled {
            link?.isPaused = true
            // A janela escondida pelo vidro volta com o Option solto, ou com ele seguro e nenhuma tecla por
            // `optionIdle`: apertando +/- várias vezes, a fita parava entre uma tecla e outra e a página
            // aparecia pelo vidro até a tecla seguinte. Segurado só se o tap e o estado do teclado
            // concordam: na dúvida, volta.
            let held = modifiersHeld && hotkeys.modifiersHeld()
            if ghosted.isEmpty {
                verifyPlacement(after: 0.15)  // o app teve tempo de aplicar (Electron é assíncrono)
            } else if !held {
                returnGhosts()
            } else {
                let version = layoutVersion  // outra tecla nesse meio tempo cancela
                DispatchQueue.main.asyncAfter(deadline: .now() + GhostOverlay.optionIdle) { [weak self] in
                    if self?.layoutVersion == version { self?.returnGhosts() }
                }
            }
            if let id = deferredFocus { requestFocus(id) }
            if verbose { report(duration: now - animationStart, ticks: ticks, maxTickGap: maxTickGap) }
        }
    }

    /// Fita parada: as janelas escondidas pelo vidro voltam. A conferência espera o vidro sair: a janela
    /// acabou de mudar de tamanho de uma vez, e uma leitura cedo veria o tamanho velho e mandaria o
    /// resize de novo no meio do redesenho.
    private func returnGhosts() {
        guard !ghosted.isEmpty, link?.isPaused == true else { return }
        finishGhosts(layout.frames(at: CACurrentMediaTime()))
        verifyPlacement(after: 0.15 + GhostOverlay.maxWait + GhostOverlay.hold + GhostOverlay.fade)
    }

    private func verifyPlacement(after wait: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, self.link?.isPaused == true else { return }
            for w in self.workers.values {
                w.verifyPlacement { [weak self] fixed, minWidths in self?.verified(w, fixed, minWidths) }
            }
        }
    }

    private func verified(_ w: AppWorker, _ fixed: Int, _ minWidths: [(CGWindowID, Double)]) {
        if fixed > 0, verbose { log("\(w.name): \(fixed) correção(ões) de posição/tamanho") }
        guard !minWidths.isEmpty else { return }
        let now = CACurrentMediaTime()
        for (id, width) in minWidths {
            if verbose { log("\(w.name): janela \(id) não encolhe abaixo de \(Int(width)) pt; virou o limite da coluna") }
            layout.setMinWidth(id, width, at: now)
        }
        animate()
    }

    /// Com -v: quantos frames cada app conseguiu aplicar e quanto custou cada um.
    private func report(duration: Double, ticks: Int, maxTickGap: Double) {
        guard ticks > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            var parts = [String(format: "animação %.0f ms, %d ticks, maior intervalo %.1f ms", duration * 1000, ticks, maxTickGap * 1000)]
            for w in self.workers.values.sorted(by: { $0.name < $1.name }) {
                let s = w.takeStats()
                guard s.frames > 0 else { continue }
                parts.append(String(format: "%@: %d frames, %.1f ms/frame, maior intervalo %.1f ms%@", w.name, s.frames,
                                    s.seconds / Double(s.frames) * 1000, s.maxGap * 1000,
                                    (s.errors > 0 ? ", \(s.errors) erros" : "")
                                        + (s.overlapFrames > 0 ? ", \(s.overlapFrames) frames com sobreposição" : "")))
            }
            log(parts.joined(separator: " | "))
        }
    }

    // MARK: - Estado salvo

    private struct SavedColumn: Codable {
        let window: CGWindowID
        let proportion: Double
        let saved: Double?
        let minWidth: Double
    }

    private static let statePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/niri-os/state.json")
    private var saveWork: DispatchWorkItem?

    private static func loadState() -> [SavedColumn] {
        guard let data = try? Data(contentsOf: statePath) else { return [] }
        return (try? JSONDecoder().decode([SavedColumn].self, from: data)) ?? []
    }

    func saveState() {
        guard dev.pid == nil else { return }
        let cols = layout.columns.map {
            SavedColumn(window: $0.window, proportion: $0.proportion, saved: $0.savedProportion, minWidth: $0.minWidth)
        }
        try? FileManager.default.createDirectory(at: Self.statePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(cols).write(to: Self.statePath, options: .atomic)
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveState() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Ao sair: tira as janelas da borda e devolve todas pra dentro da tela, em cascata.
    func shutdown() {
        saveState()
        link?.isPaused = true
        let area = layout.area
        let frames = layout.frames(at: CACurrentMediaTime())
        var byApp: [pid_t: [(CGWindowID, CGRect)]] = [:]
        for (i, f) in frames.enumerated() {
            guard let t = tracked[f.window] else { continue }
            let step = Double(i % 8) * 30
            let r = CGRect(x: area.minX + step, y: area.minY + step,
                           width: min(f.rect.width, area.width - step), height: area.height - step)
            byApp[t.pid, default: []].append((f.window, r))
        }
        let group = DispatchGroup()
        for (pid, frames) in byApp { workers[pid]?.applyNow(frames, group: group) }
        if group.wait(timeout: .now() + 2) == .timedOut { log("algum app não respondeu ao sair") }
    }
}
