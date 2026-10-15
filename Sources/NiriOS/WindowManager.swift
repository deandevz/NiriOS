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
    private let config: Config
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
    private lazy var hotkeys = HotkeyTap(verbose: verbose) { [weak self] in self?.perform($0) }

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
        if let front = NSWorkspace.shared.frontmostApplication,
           let f = initialScans[front.processIdentifier]?.focused {
            layout.focus(f, at: now)
        }
        layout.retarget(at: now)
        layout.snapToTargets()
        initialScans = [:]
        log("\(all.count) janelas na fita, \(workers.count) apps observados")
        animate()
        if !dev.script.isEmpty { runScript() }
    }

    /// Executa as ações do --script com 0,6 s entre elas, confere o resultado e sai.
    private func runScript() {
        for (i, action) in dev.script.enumerated() {
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
        let now = CACurrentMediaTime()
        switch action {
        case .grow:
            layout.resizeFocused(by: config.widthStep, at: now)
        case .shrink:
            layout.resizeFocused(by: -config.widthStep, at: now)
        case .focusLeft, .focusRight:
            guard let id = layout.focusNeighbor(action == .focusLeft ? -1 : 1, at: now) else {
                if verbose { log("ação \(action): já está na ponta da fita") }
                return
            }
            if verbose, let t = tracked[id] { log("ação \(action): foco em \(workers[t.pid]?.name ?? "?") (janela \(id))") }
            requestFocus(id)
        case .toggleFullWidth:
            layout.toggleFullWidthFocused(at: now)
        }
        animate()
    }

    private func requestFocus(_ id: CGWindowID) {
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
        for f in layout.frames(at: now) {
            if let t = tracked[f.window] { byApp[t.pid, default: []].append((f.window, f.rect)) }
        }
        for (pid, frames) in byApp { workers[pid]?.submit(frames, screen: layout.bounds, firstFrame: ticks == 0) }
        ticks += 1
        if lastTick > 0 { maxTickGap = max(maxTickGap, now - lastTick) }
        lastTick = now

        if settled {
            link?.isPaused = true
            if verbose { report(duration: now - animationStart, ticks: ticks, maxTickGap: maxTickGap) }
            // Espera o app terminar de aplicar (Electron é assíncrono) e confere.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.link?.isPaused == true else { return }
                for w in self.workers.values {
                    w.verifyPlacement { [weak self] fixed, minWidths in self?.verified(w, fixed, minWidths) }
                }
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
