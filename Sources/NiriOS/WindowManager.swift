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
    private var workspaces: Workspaces
    /// A fita do workspace na tela.
    private var layout: Layout {
        get { workspaces.current }
        _modify { yield &workspaces.current }
    }
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
    /// O último app ativado pelo macOS (Cmd+Tab, Dock ou pedido nosso), pra saber se um aviso de foco veio disso.
    private var lastActivation: (pid: pid_t, time: Double)?
    /// Quando uma janela do workspace da tela fechou, minimizou ou o app dela escondeu ou saiu.
    private var lastVanish = 0.0
    /// Onde estava cada janela que saiu da fita sem fechar (tela cheia, minimizada, app escondido): o workspace,
    /// as vizinhas e a coluna (largura), pra ela voltar igual, e não como janela nova (à direita da focada, no
    /// workspace da tela, com 50%). Some quando ela volta, fecha ou o app sai.
    private struct Away {
        let pid: pid_t
        var workspace: String
        let left: CGWindowID?, right: CGWindowID?, column: Column
    }
    private var away: [CGWindowID: Away] = [:]
    /// A janela que ficou com o teclado quando a tela foi pra um workspace vazio (o macOS não tira o foco dela).
    /// Aviso dela não leva de volta: visto no uso, 1,5 s depois de ir pro 4 vazio o King Bot e o WhatsApp
    /// avisavam foco de novo e a tela voltava sozinha. Pra voltar, o atalho.
    private var leftBehind: CGWindowID?
    /// Largura mínima lida uma vez, esperando a 2ª leitura (ver `verified`).
    private var minCandidates: [CGWindowID: Double] = [:]
    private var link: CADisplayLink?
    private var started = false
    private var initialScans: [pid_t: ScanResult] = [:]
    private var animationStart = 0.0
    private var ticks = 0
    private var lastTick = 0.0
    private var maxTickGap = 0.0
    /// Só na instância de verdade: teste (--pid, --script) não mexe no papel de parede.
    private var wallpaper: WallpaperHost?
    /// `niri-os --workspace <nome>` (o clique na SketchyBar, por exemplo) chega por aqui.
    static let workspaceRequest = Notification.Name("niri-os.workspace")
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
        self.workspaces = Workspaces(names: config.workspaces.map(\.name), area: geo.area, bounds: geo.bounds, config: config.layout)
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

    /// Config recarregada (arquivo salvo ou painel). Atalhos, borda do vidro e regras de app valem na hora; gap,
    /// margens, mola, centralização e a lista de workspaces animam as janelas pro layout novo. `resizeStyle` e
    /// `axTimeout` só ao reiniciar.
    func apply(_ c: Config) {
        let old = config
        config = c
        hotkeys.setShortcuts(c.shortcuts)
        ghost?.border = (c.ghostBorderColor, c.ghostBorderWidth)
        wallpaper?.apply(c)
        if c.resizeStyle != old.resizeStyle || c.axTimeout != old.axTimeout {
            log("config: resizeStyle e axTimeout mudam só ao reiniciar o niri-os")
        }
        guard dev.pid == nil else { return }
        let now = CACurrentMediaTime(), geo = Self.screenGeometry(c), names = c.workspaces.map(\.name)
        guard c.layout != layout.config || geo.area != layout.area || names != workspaces.names else { return }
        let renamed = workspaces.setNames(names, at: now)
        for (id, a) in away { if let n = renamed[a.workspace] { away[id]?.workspace = n } }
        workspaces.setConfig(c.layout, at: now)
        workspaces.setArea(geo.area, bounds: geo.bounds, at: now)
        animate()
        if !renamed.isEmpty { announceWorkspace() }  // a barra mostra o nome novo
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
        if dev.pid == nil && dev.script.isEmpty {
            wallpaper = WallpaperHost()
            wallpaper?.apply(config)
        }

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
            self?.lastActivation = (app.processIdentifier, CACurrentMediaTime())
            self?.activated(app.processIdentifier)
            // Rescan aqui também: se algum evento de janela se perdeu, ativar o app corrige.
            self?.workers[app.processIdentifier]?.requestScan()
            self?.workers[app.processIdentifier]?.reportFocusedWindow()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screenChanged()
        }
        // Entrar e sair de tela cheia troca de Space e não manda nenhum aviso de janela que a gente escute:
        // sem reler, a janela que saiu da tela cheia ficava solta por cima ou por trás da fita até ser
        // minimizada. Relê de novo 0,5 s depois, quando a animação de saída do macOS já acabou.
        ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rescanAll()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.rescanAll() }
        }
        if dev.pid == nil && dev.script.isEmpty {
            DistributedNotificationCenter.default().addObserver(forName: Self.workspaceRequest, object: nil, queue: .main) { [weak self] n in
                if let name = n.object as? String { self?.perform(.workspace(name)) }
            }
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
        let w = AppWorker(pid: pid, name: app.localizedName ?? "pid \(pid)", bundleID: app.bundleIdentifier,
                          timeout: config.axTimeout, anySubrole: dev.pid != nil)
        w.onScan = { [weak self] pid, result in self?.scanned(pid, result) }
        w.onFocus = { [weak self] pid, id in self?.focusChanged(pid, id) }
        workers[pid] = w
        w.start()
    }

    private func rescanAll() {
        for w in workers.values { w.requestScan() }
    }

    private func removeApp(_ pid: pid_t) {
        guard let w = workers.removeValue(forKey: pid) else { return }
        w.stop()
        initialScans[pid] = nil
        appFocus[pid] = nil
        away = away.filter { $0.value.pid != pid }
        let gone = tracked.filter { $0.value.pid == pid }.map(\.key)
        guard !gone.isEmpty else { return }
        let wasFocused = layout.focusedWindow
        let now = CACurrentMediaTime()
        for id in gone {
            if workspaces.index(of: id) == workspaces.active { lastVanish = now }
            tracked[id] = nil
            workspaces.remove(id, at: now)
        }
        if let f = layout.focusedWindow, f != wasFocused { deferFocus(f) }
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

    /// Monta as fitas com as janelas que já estavam abertas, na ordem em que aparecem na tela,
    /// mantendo a largura de cada uma (arredondada pro passo de resize). Cada uma vai pro workspace salvo,
    /// senão pro do app no config, senão pro 1º.
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
            let k = c.workspace.flatMap(workspaces.index(named:)) ?? workspace(forApp: pid) ?? 0
            workspaces[k].append(w.id, proportion: c.proportion, savedProportion: c.saved, minWidth: c.minWidth)
            restored.insert(w.id)
        }
        for (pid, w) in all where !restored.contains(w.id) {
            tracked[w.id] = (pid, w.element)
            workspaces[workspace(forApp: pid) ?? 0].append(w.id, proportion: layout.proportion(forWidth: w.frame.width, step: config.widthStep))
        }
        if !restored.isEmpty { log("\(restored.count) janelas restauradas na ordem salva") }
        let now = CACurrentMediaTime()
        // Foco na janela do app da frente, e o workspace dela na tela. Se ele não informar a janela focada
        // pela Acessibilidade, vale a 1ª janela dele.
        if let pid = Self.frontPid(),
           let f = initialScans[pid]?.focused.flatMap({ tracked[$0] != nil ? $0 : nil })
               ?? workspaces.windows.first(where: { tracked[$0]?.pid == pid }) {
            workspaces.switchTo(workspaces.index(of: f) ?? 0, at: now)
            layout.focus(f, at: now)
        }
        if verbose, let f = layout.focusedWindow, let t = tracked[f] {
            log("foco inicial: \(workers[t.pid]?.name ?? "?") (janela \(f)), workspace \(workspaces.names[workspaces.active])")
        }
        for k in 0..<workspaces.count { workspaces[k].retarget(at: now) }
        workspaces.snapToTargets()
        initialScans = [:]
        announceWorkspace()
        let counts = (0..<workspaces.count).map { "\(workspaces.names[$0]): \(workspaces[$0].columns.count)" }
        log("\(all.count) janelas (\(counts.joined(separator: ", "))), \(workers.count) apps observados")
        animate()
        if !dev.script.isEmpty { runScript() }
    }

    /// Dono da janela normal mais à frente na tela. Logo depois de abrir, o NSWorkspace ainda diz que o
    /// app da frente é o próprio niri-os, e o foco inicial caía na 1ª coluna.
    private static func frontPid() -> pid_t? {
        frontWindowInfo()?[kCGWindowOwnerPID as String] as? pid_t ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    /// A janela normal mais à frente na tela, pro WindowServer (não fala com o app).
    private static func frontWindow() -> CGWindowID? { frontWindowInfo()?[kCGWindowNumber as String] as? CGWindowID }

    private static func frontWindowInfo() -> [String: Any]? {
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        return list.first { ($0[kCGWindowLayer as String] as? Int) == 0 && ($0[kCGWindowOwnerPID as String] as? pid_t) != getpid() }
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
        let expected = workspaces.frames(at: CACurrentMediaTime())
        let group = DispatchGroup()
        var actual: [CGWindowID: CGRect] = [:]
        for w in workers.values {
            group.enter()
            w.readFrames(expected.map(\.window)) { r in
                actual.merge(r) { a, _ in a }
                group.leave()
            }
        }
        let screen = layout.bounds
        group.notify(queue: .main) {
            var bad = 0
            for f in expected {
                // Estacionada: só a posição (1 pt na borda direita, com a largura que tiver; ver `AppWorker.origin`).
                let a = actual[f.window], parked = AppWorker.isParked(f.rect, screen: screen)
                let ok = parked ? a?.origin == AppWorker.origin(for: f.rect, screen: screen) : a == f.rect
                if !ok { bad += 1 }
                log("janela \(f.window): esperado \(parked ? "1 pt na borda direita" : "\(f.rect)")  real \(a.map { "\($0)" } ?? "?")  \(ok ? "ok" : "DIFERENTE")")
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
        let listed = Set(windows.map(\.id))
        // A Acessibilidade só lista as janelas do Space atual. Fora da lista mas ainda num Space é janela de
        // outro Space (a pessoa foi pra uma tela cheia ou outro desktop), não fechada: fica na fita. Sem isso,
        // ir pra outro Space tirava uma janela de cada app, e na volta elas entravam como novas: fora do lugar,
        // com 50% de largura e no workspace da regra (o Zed voltou do 4 pro 3; visto no uso em 2026-10-16).
        let removed = known.subtracting(current).subtracting(uncertain).filter { listed.contains($0) || !Private.isOnAnySpace($0) }
        let wasFocused = layout.focusedWindow
        var changed = false

        away = away.filter { $0.value.pid != pid || listed.contains($0.key) || Private.isOnAnySpace($0.key) }  // as que fecharam de vez
        // A focada foi pra tela cheia: a pessoa está nela, num Space à parte. Focar a vizinha tirava ela de lá.
        let toFullScreen = windows.contains { $0.fullScreen && $0.id == wasFocused }
        for id in removed {
            // Ainda na lista do app (tela cheia, minimizada, app escondido): guarda onde estava pra volta.
            let k = workspaces.index(of: id), cols = k.map { workspaces[$0].windows } ?? [], i = cols.firstIndex(of: id)
            if k == workspaces.active { lastVanish = now }
            tracked[id] = nil
            let column = workspaces.remove(id, at: now)
            if listed.contains(id), let k, let i, let column {
                away[id] = Away(pid: pid, workspace: workspaces.names[k], left: i > 0 ? cols[i - 1] : nil,
                                right: i + 1 < cols.count ? cols[i + 1] : nil, column: column)
            }
            workers[pid]?.forget(id)
            changed = true
        }
        let isFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        let home = workspace(forApp: pid)
        var added: [CGWindowID] = []
        for w in tileable.sorted(by: { $0.frame.minX < $1.frame.minX }) {
            if known.contains(w.id) {
                tracked[w.id] = (pid, w.element)
                continue
            }
            tracked[w.id] = (pid, w.element)
            // Como no niri: janela nova entra à direita da focada e ganha foco (se o app está na frente).
            // Voltando (de tela cheia, minimizada, app escondido), vai pro lugar de antes: o mesmo workspace,
            // entre as mesmas vizinhas, se ainda estão lá. App com workspace no config abre lá; o resto, no da tela.
            let back = away.removeValue(forKey: w.id)
            let k = back.flatMap { workspaces.index(named: $0.workspace) } ?? home ?? workspaces.active
            let focus = isFront || result.focused == w.id
            if let back {
                let position = back.left.flatMap { workspaces[k].index(of: $0) }.map { $0 + 1 } ?? back.right.flatMap { workspaces[k].index(of: $0) }
                workspaces[k].insert(back.column, position: position, focus: focus, at: now)
            } else {
                workspaces[k].insert(w.id, focus: focus, at: now)
            }
            added.append(w.id)
            changed = true
        }
        guard changed else { return }
        if verbose { log("\(workers[pid]?.name ?? "?"): +\(added.count) -\(removed.count) janelas") }
        // App na frente com janela nova em outro workspace (a pessoa acabou de abrir ou de mostrar o app): a
        // tela vai junto, pro da janela focada dele se ela é uma das novas.
        if isFront, let f = result.focused.flatMap({ added.contains($0) ? $0 : nil }) ?? added.first,
           let k = workspaces.index(of: f), k != workspaces.active {
            return switchWorkspace(to: k, focusing: f)
        }
        // A focada fechou: o foco vai pra vizinha que o layout escolheu, não pra onde o macOS quiser.
        if let f = layout.focusedWindow, f != wasFocused, !added.contains(f), !toFullScreen { deferFocus(f) }
        animate()
    }

    private func focusChanged(_ pid: pid_t, _ id: CGWindowID) {
        let changed = appFocus[pid] != id
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
        guard tracked[id] != nil, let k = workspaces.index(of: id) else { return }
        if k != workspaces.active {
            guard isUserSwitch(pid, id, changed: changed, at: now) else { return }
            if verbose { log("foco em \(workers[pid]?.name ?? "?") (\(changed ? "trocou de janela" : "app ativado")), no workspace \(workspaces.names[k]): vai pra lá") }
            return switchWorkspace(to: k, focusing: id)
        }
        // Com a mesa à mostra, foco em outra janela (Cmd+Tab, Dock) traz a fita de volta (ver `activated`).
        guard layout.focusedWindow != id else { return }
        if verbose && layout.showsDesktop { log("foco em \(workers[pid]?.name ?? "?") com a mesa à mostra: fita de volta") }
        layout.focus(id, at: now)
        animate()
    }

    /// Com a mesa à mostra, o app da janela focada ativado de novo pela pessoa (Cmd+Tab ou Dock depois de
    /// passar por outro) traz a fita de volta. Avisos de foco da própria janela focada não servem pra isso:
    /// a conferência de foco 0,6 s depois de cada pedido manda um, e desfazia o Option+D apertado logo
    /// depois de um Option+→. App de outra janela vem por `focusChanged`; app sem janela na fita (o Finder
    /// com clique na mesa, o painel de configurações) não mexe em nada.
    private func activated(_ pid: pid_t) {
        let now = CACurrentMediaTime()
        guard layout.showsDesktop, pendingFocus.map({ now - $0.time > 0.5 }) ?? true,
              let f = layout.focusedWindow, tracked[f]?.pid == pid else { return }
        if verbose { log("\(workers[pid]?.name ?? "?") ativado com a mesa à mostra: fita de volta") }
        layout.setDesktop(false, at: now)
        animate()
    }

    /// Foco numa janela de outro workspace só troca de workspace quando foi a pessoa: o app está na frente e
    /// trocou de janela (Cmd+`), ou acabou de ser ativado (Cmd+Tab, Dock) e a janela veio pra frente. Não trocam:
    /// a conferência de foco (mesma janela, sem ativação; desfazia a ida pra um workspace vazio), o clique na
    /// mesa (ativa o Finder sem trazer a janela dele pra frente) e o macOS escolhendo outro app ou janela
    /// porque uma daqui fechou, minimizou ou o app dela escondeu ou saiu. Esse aviso chega antes ou depois da
    /// leitura que tira a janela da fita: antes, a focada daqui já saiu da tela; depois, `lastVanish`.
    private func isUserSwitch(_ pid: pid_t, _ id: CGWindowID, changed: Bool, at now: Double) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, now - lastVanish > 0.5, id != leftBehind else { return false }
        let activated = lastActivation.map { $0.pid == pid && now - $0.time < 0.5 } ?? false
        guard changed || (activated && Self.frontWindow() == id) else { return false }
        return layout.focusedWindow.map(Self.isOnScreen) ?? true
    }

    /// Na tela pro WindowServer (estacionada com 1 pt conta; fechada, minimizada ou de app escondido, não).
    /// Não fala com o app.
    private static func isOnScreen(_ id: CGWindowID) -> Bool {
        let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?.first
        return info?[kCGWindowIsOnscreen as String] as? Bool ?? false
    }

    /// O workspace que o config dá pro app (pelo nome dele ou pelo bundle id), se algum dá.
    private func workspace(forApp pid: pid_t) -> Int? {
        guard let w = workers[pid], let rule = config.workspaces.first(where: { $0.matches(app: w.name, bundleID: w.bundleID) }) else { return nil }
        return workspaces.index(named: rule.name)
    }

    private func screenChanged() {
        guard dev.pid == nil else { return }
        let geo = Self.screenGeometry(config)
        guard geo.area != layout.area || geo.bounds != layout.bounds else { return }
        workspaces.setArea(geo.area, bounds: geo.bounds, at: CACurrentMediaTime())
        animate()
    }

    // MARK: - Ações

    private func perform(_ action: Action) {
        guard global == nil else { queuedAction = action; return }  // roda quando a transição acabar
        let now = CACurrentMediaTime()
        if case .workspace(let name) = action, let k = workspaces.index(named: name) {
            // Com a mesa à mostra, a fita sai de cena do mesmo jeito (ver `Workspaces.switchTo`).
            if k != workspaces.active { switchWorkspace(to: k) }
            // Vazio (de novo ou já estava): abre o app dele. A janela entra aqui (ou no workspace do app).
            if layout.columns.isEmpty, let app = config.workspaces.first(where: { $0.name == name })?.open, dev.pid == nil {
                if verbose { log("workspace \(name) vazio: abrindo \(app)") }
                run("/usr/bin/open", ["-a", app])
            }
            return
        }
        if action == .toggleDesktop || layout.showsDesktop {
            // Com a mesa à mostra, qualquer atalho traz a fita de volta (e faz o que pediu).
            layout.setDesktop(action == .toggleDesktop && !layout.showsDesktop, at: now)
            if verbose { log(layout.showsDesktop ? "mesa à mostra" : "fita de volta") }
            animate()
            if action == .toggleDesktop { return }
        }
        switch action {
        case .focusLeft, .focusRight:
            // Só rola; o app onde a fita parar é ativado no fim (ver `deferFocus`).
            guard let id = layout.focusNeighbor(action == .focusLeft ? -1 : 1, at: now) else {
                if verbose { log("ação \(action): já está na ponta da fita") }
                return
            }
            if verbose, let t = tracked[id] { log("ação \(action): foco em \(workers[t.pid]?.name ?? "?") (janela \(id))") }
            deferFocus(id)
        case .grow, .shrink, .toggleFullWidth:
            if transition != nil, startGlobal(action, at: now) { return }
            if ghost != nil { resizeWithGhost(action, at: now) } else { resize(&layout, action, at: now) }
        case .moveToWorkspace(let name):
            guard let k = workspaces.index(named: name), k != workspaces.active, let id = layout.focusedWindow else { return }
            workspaces.move(id, to: k, at: now)
            if verbose { log("ação \(action): janela \(id) foi pro workspace \(name)") }
            if let f = layout.focusedWindow { deferFocus(f) }
        case .toggleDesktop, .workspace: break
        }
        animate()
    }

    /// Troca de workspace. `focusing`: janela que já tem o foco do macOS (Cmd+Tab pra ela, ou janela nova do
    /// app da frente). Senão, o foco vai pra focada do workspace novo no fim da animação, como no `< >`.
    /// Workspace vazio não mexe no foco.
    private func switchWorkspace(to k: Int, focusing id: CGWindowID? = nil) {
        let now = CACurrentMediaTime(), previous = layout.focusedWindow
        workspaces.switchTo(k, at: now)
        deferredFocus = nil
        leftBehind = layout.focusedWindow == nil && id == nil ? leftBehind ?? previous : nil
        if let id {
            layout.focus(id, at: now)
        } else if let f = layout.focusedWindow {
            deferFocus(f)
        }
        if verbose { log("workspace \(workspaces.names[k]) (\(layout.columns.count) janelas)") }
        animate()
        announceWorkspace()
    }

    /// Roda o `onWorkspaceChange` do config (a SketchyBar, por exemplo) com o nome em NIRI_WORKSPACE. Teste
    /// (--pid, --script) não roda: mexeria na barra de quem está usando o Mac.
    private func announceWorkspace() {
        guard let cmd = config.onWorkspaceChange, dev.pid == nil, dev.script.isEmpty else { return }
        run("/bin/sh", ["-c", cmd], env: ["NIRI_WORKSPACE": workspaces.names[workspaces.active]])
    }

    /// Processo solto: não espera ele terminar. Abrir um processo custa ~2 ms, fora da main.
    private func run(_ exe: String, _ args: [String], env: [String: String] = [:]) {
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
            do { try p.run() } catch { log("não consegui rodar \(exe): \(error.localizedDescription)") }
        }
    }

    private func resize(_ l: inout Layout, _ action: Action, at t: Double) {
        switch action {
        case .grow, .shrink:
            let dir = action == .grow ? 1 : -1
            if config.widthPresets.isEmpty { l.resizeFocused(by: Double(dir) * config.widthStep, at: t) }
            else { l.resizeFocused(toPresetIn: config.widthPresets, direction: dir, at: t) }
        case .toggleFullWidth: l.toggleFullWidthFocused(at: t)
        default: break
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
        guard !down else { return }
        returnGhosts()  // ver `step`
        if let id = deferredFocus, workspaces.isNear(at: CACurrentMediaTime(), within: Self.focusDistance) { requestFocus(id) }
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
        workers[t.pid]?.park(id, screen: layout.bounds, y: r.minY, shrinkTo: to.width < r.width ? to.size : nil)
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

    /// Foco que espera a animação (ver `deferFocus`).
    private var deferredFocus: CGWindowID?
    /// O foco adiado sai quando falta menos que isso (pt) pra toda mola chegar: ~0,3 s depois da tecla, contra
    /// ~0,4 s pra assentar de vez. Se o app travar redesenhando, a janela dele para a ≤ 3 pt do lugar.
    private static let focusDistance = 3.0

    /// Ativar um app no meio da animação trava ele e quem perde o foco: os dois redesenham e param de responder
    /// AX. Medido no uso, trocando de workspace: Arc parado 208 ms ao perder o foco, WhatsApp 73 ms, e a
    /// main do niri-os perdendo um frame (21 ms) em 8 de 40 trocas, todas com ativação no começo (nos painéis,
    /// sem ativação, 8,4 ms). Então o foco espera a animação quase acabar e os modificadores do atalho
    /// subirem: navegando com o Option seguro, nenhum app atravessado é ativado. Enquanto espera, eventos de
    /// foco de outros apps são eco (senão o foco da 1ª tecla puxaria o layout de volta).
    private func deferFocus(_ id: CGWindowID) {
        deferredFocus = id
        pendingFocus = (id, CACurrentMediaTime())
    }

    /// Modificadores do atalho seguros, se o tap e o estado do teclado concordam (na dúvida, soltos).
    private var shortcutHeld: Bool { modifiersHeld && hotkeys.modifiersHeld() }

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
        // O vídeo do papel de parede toca só com a mesa à mostra; com janela na tela ele para.
        if started { wallpaper?.desktopShown(layout.showsDesktop || layout.windows.isEmpty) }
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
        let settled = workspaces.isSettled(at: now)
        if settled { workspaces.snapToTargets() }

        var byApp: [pid_t: [(CGWindowID, CGRect)]] = [:]
        let frames = workspaces.frames(at: now)
        for f in frames {
            if let t = tracked[f.window] { byApp[t.pid, default: []].append((f.window, f.rect)) }
        }
        for (pid, frames) in byApp { workers[pid]?.submit(frames, screen: layout.bounds, firstFrame: ticks == 0) }
        if let id = deferredFocus, !shortcutHeld, workspaces.isNear(at: now, within: Self.focusDistance) { requestFocus(id) }
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
            let held = shortcutHeld
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
            if verbose {
                report(duration: now - animationStart, ticks: ticks, maxTickGap: maxTickGap)
                audit()
            }
        }
    }

    /// Fita parada: as janelas escondidas pelo vidro voltam. A conferência espera o vidro sair: a janela
    /// acabou de mudar de tamanho de uma vez, e uma leitura cedo veria o tamanho velho e mandaria o
    /// resize de novo no meio do redesenho.
    private func returnGhosts() {
        guard !ghosted.isEmpty, link?.isPaused == true else { return }
        finishGhosts(workspaces.frames(at: CACurrentMediaTime()))
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

    /// Largura mínima só vale com duas leituras iguais, a 2ª 0,6 s depois. Uma leitura só pegava app assíncrono
    /// (Electron, Catalyst) ainda no tamanho velho, e o limite errado ficava salvo e mudava o tamanho da janela
    /// sozinho (visto no uso: Arc 1704, WhatsApp 1643, Discord 1223 pt).
    private func verified(_ w: AppWorker, _ fixed: Int, _ minWidths: [(CGWindowID, Double)]) {
        if fixed > 0, verbose { log("\(w.name): \(fixed) correção(ões) de posição/tamanho") }
        let now = CACurrentMediaTime(), reported = Set(minWidths.map(\.0))
        minCandidates = minCandidates.filter { id, _ in tracked[id].map { $0.pid != w.pid || reported.contains(id) } ?? false }
        var learned = false, recheck = false
        for (id, width) in minWidths {
            guard let k = workspaces.index(of: id) else { continue }
            if let first = minCandidates[id], abs(first - width) <= 2 {
                if verbose { log("\(w.name): janela \(id) não encolhe abaixo de \(Int(width)) pt; virou o limite da coluna") }
                workspaces[k].setMinWidth(id, width, at: now)
                minCandidates[id] = nil
                learned = true
            } else {
                minCandidates[id] = width
                recheck = true
            }
        }
        if recheck {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard self?.link?.isPaused == true else { return }  // animando: a próxima conferência repete
                w.verifyPlacement { [weak self] fixed, minWidths in self?.verified(w, fixed, minWidths) }
            }
        }
        if learned { animate() }
    }

    /// O que a última `audit` registrou: a mesma janela no mesmo lugar não sai de novo no log.
    private var audited: Set<String> = []

    /// Com -v, depois de cada animação: confere pelo WindowServer (não fala com os apps) e registra janela de app
    /// observado que está na tela fora do lugar ou fora da fita. É assim que se acha janela vazando de outro
    /// workspace ou app que não entrou na fita (Steam). Estacionada conta pela fatia visível (ver `AppWorker.origin`).
    private func audit() {
        let version = layoutVersion
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.4) {
            let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
            DispatchQueue.main.async { [weak self] in
                guard let self, self.layoutVersion == version, self.link?.isPaused == true else { return }
                let expected = Dictionary(uniqueKeysWithValues: self.workspaces.frames(at: CACurrentMediaTime()).map { ($0.window, $0.rect) })
                let screen = self.layout.bounds
                var found: Set<String> = []
                for info in list {
                    guard (info[kCGWindowLayer as String] as? Int) == 0, let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                          let name = self.workers[pid]?.name, let id = info[kCGWindowNumber as String] as? CGWindowID,
                          !self.ghosted.contains(id),
                          let d = info[kCGWindowBounds as String], let b = CGRect(dictionaryRepresentation: d as! CFDictionary) else { continue }
                    let shown = b.intersection(screen)
                    if let r = expected[id] {
                        let parked = AppWorker.isParked(r, screen: screen)
                        let wrong = parked ? abs(b.minX - (screen.maxX - 1)) > 2 || abs(b.minY - r.minY) > 2
                            : abs(b.minX - r.minX) > 2 || abs(b.minY - r.minY) > 2 || abs(b.width - r.width) > 2 || abs(b.height - r.height) > 2
                        if wrong { found.insert("\(name): janela \(id) fora do lugar: esperada \(parked ? "1 pt na borda direita" : "\(r)"), no WindowServer \(b)") }
                    } else if shown.width > 40 && shown.height > 40 {
                        found.insert("\(name): janela \(id) na tela fora da fita: \(b)")
                    }
                }
                for m in found.subtracting(self.audited).sorted() { log("conferência: \(m)") }
                self.audited = found
            }
        }
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
        /// Nome do workspace. Ausente no estado de antes dos workspaces.
        var workspace: String?
    }

    private static let statePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/niri-os/state.json")
    private var saveWork: DispatchWorkItem?

    private static func loadState() -> [SavedColumn] {
        guard let data = try? Data(contentsOf: statePath) else { return [] }
        return (try? JSONDecoder().decode([SavedColumn].self, from: data)) ?? []
    }

    private static let saveQueue = DispatchQueue(label: "niri.state", qos: .utility)

    /// Grava fora da main (a gravação marcada 0,5 s depois de uma animação caía no meio da seguinte). `wait`:
    /// ao sair, espera gravar.
    func saveState(wait: Bool = true) {
        guard dev.pid == nil else { return }
        let cols = (0..<workspaces.count).flatMap { k in
            workspaces[k].columns.map {
                SavedColumn(window: $0.window, proportion: $0.proportion, saved: $0.savedProportion, minWidth: $0.minWidth,
                            workspace: workspaces.names[k])
            }
        }
        let write = {
            try? FileManager.default.createDirectory(at: Self.statePath.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(cols).write(to: Self.statePath, options: .atomic)
        }
        if wait { Self.saveQueue.sync(execute: write) } else { Self.saveQueue.async(execute: write) }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveState(wait: false) }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Ao sair: tira as janelas da borda e devolve todas pra dentro da tela, em cascata (as de todos os workspaces).
    func shutdown() {
        saveState()
        link?.isPaused = true
        let area = layout.area
        let frames = workspaces.frames(at: CACurrentMediaTime())
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
