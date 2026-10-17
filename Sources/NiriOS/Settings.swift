import AppKit

/// Ícone na barra de menu e recarga do config.json. O arquivo é a única fonte: tudo que muda nele (pelo
/// painel ou à mão) é aplicado na hora. Vigiado por FSEvents, sem polling.
///
/// Clique (esquerdo ou direito) no ícone abre o painel, que roda em outro processo (`niri-os --settings`)
/// e termina quando a janela fecha. O update também (ver `Updater`). Dentro deste, abrir o painel uma vez subia a memória de 12 pra 50 MB,
/// com pico de 260 MB (o `Form` do SwiftUI), e fechar só devolvia 6 MB. Menu no ícone também ficou de
/// fora: abrir um `NSMenu` uma vez custa 3,3 MB que não voltam. Os dois processos conversam pelo arquivo
/// e por linhas no pipe (`command`).
final class Settings: NSObject {
    private let wm: WindowManager
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var stream: FSEventStreamRef?
    /// O conteúdo do arquivo na última recarga: evento do FSEvents sem mudança real não recarrega de novo.
    private var loaded: Data?
    private var panel: Process?
    private var updater: Process?
    /// A janela de cada processo nosso aberto, pra trazer pra frente (ver `front`).
    private var windows: [pid_t: CGWindowID] = [:]
    private var updateTimer: DispatchSourceTimer?

    init(wm: WindowManager) {
        self.wm = wm
        super.init()
        // A fita com a coluna focada no meio. Desenhado aqui: o símbolo SF parecido carregava o catálogo de
        // símbolos (+0,6 MB; o item na barra em si custa 1,4 MB).
        let icon = NSImage(size: NSSize(width: 19, height: 14), flipped: false) { _ in
            for (x, w) in [(0.0, 4.0), (5.5, 8.0), (15.0, 4.0)] {
                NSBezierPath(roundedRect: NSRect(x: x, y: 1, width: w, height: 12), xRadius: 1.5, yRadius: 1.5).fill()
            }
            return true
        }
        icon.isTemplate = true
        icon.accessibilityDescription = "NiriOS"
        item.button?.image = icon
        item.button?.toolTip = "NiriOS: configurações"
        item.button?.target = self
        item.button?.action = #selector(openPanel)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        loaded = try? Data(contentsOf: Config.path)
        watch()
        scheduleUpdates()
        // Sair pelo macOS (ver `AppDelegate`).
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.closeChildren()
        }
    }

    /// O painel e o update saem junto: sozinhos, ficariam abertos sem ninguém pra atender os pedidos.
    private func closeChildren() {
        panel?.terminate()
        updater?.terminate()
    }

    private func watch() {
        // Pasta do arquivo de verdade: com dotfiles, config.json ou a pasta costumam ser link simbólico.
        let dir = Config.path.resolvingSymlinksInPath().deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            let s = Unmanaged<Settings>.fromOpaque(info!).takeUnretainedValue()
            if (try? Data(contentsOf: Config.path)) != s.loaded { s.reload() }
        }
        // Eventos por arquivo pegam a gravação no lugar e a atômica (editor que grava num temporário e
        // renomeia). NoDefer: o primeiro evento chega na hora, os seguintes juntam em 50 ms.
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &ctx, [dir.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags) else {
            log("não consegui vigiar \(dir.path): recarregue pelo painel")
            return
        }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }

    private func reload() {
        loaded = try? Data(contentsOf: Config.path)
        let c = Config.load()
        // Arquivo pela metade (editor que esvazia e depois escreve, `echo >`): com os padrões, os workspaces que não são
        // 1 a 4 sumiam e as janelas deles iam pro da tela. Fica o que estava; a gravação que completa recarrega.
        guard !c.invalid else { return log("config: continuo com a anterior até o arquivo ser um JSON válido") }
        if c.has(.tiling) != wm.config.has(.tiling) { restart() }
        wm.apply(c)
    }

    /// `NIRI_OPEN_SETTINGS`: o processo novo abre o painel (ver `restart`).
    static let reopenKey = "NIRI_OPEN_SETTINGS"

    /// Ligar ou desligar a fita reinicia o niri-os: um processo novo, com os mesmos argumentos (ver `AppBundle.relaunch`),
    /// e este sai. Montar e desmontar a fita com o app aberto teria que desfazer as filas por app, os observadores, o
    /// display link e as janelas nossas, e é desse tipo de sobra que nasce estado que discorda do layout. Assim são dois
    /// caminhos que já existem: desligar devolve as janelas pra tela (o mesmo do Ctrl+C) e guarda o estado; ligar monta a
    /// fita do state.json, como ao abrir. O painel aberto fecha e abre de novo no processo novo. Com `exec` (mesmo pid) o
    /// ícone ia pra fora da barra de menu e não voltava, nem tirando ele antes.
    private func restart() -> Never {
        log("fita \(wm.config.has(.tiling) ? "desligada" : "ligada"): reiniciando o niri-os")
        let reopen = panel != nil
        closeChildren()
        wm.shutdown()  // sem a fita, não mexe em nada
        AppBundle.relaunch(environment: reopen ? [Self.reopenKey: "1"] : [:])
    }

    static func openFile(reveal: Bool = false) {
        if !FileManager.default.fileExists(atPath: Config.path.path) { _ = Config.save([:]) }
        if reveal { NSWorkspace.shared.activateFileViewerSelecting([Config.path]) } else { NSWorkspace.shared.open(Config.path) }
    }

    /// O que o painel e o update pedem, uma linha por pedido.
    private func command(_ line: Substring, from p: Process) {
        let word = line.split(separator: " ")
        switch word.first ?? "" {
        case "pause", "resume": wm.shortcutsPaused = line == "pause"
        case "front":
            windows[p.processIdentifier] = word.last.flatMap { CGWindowID($0) }
            front(p)
        case "reload": reload()
        case "update": checkUpdate(manual: true)
        // Pelos argumentos e não por `updater`: o processo sai logo depois de pedir, e o fim dele pode chegar antes.
        case "install" where p.arguments?.first == "--update": install(String(line.dropFirst("install ".count)))
        case "quit":
            log("saindo pelo painel: devolvendo as janelas pra dentro da tela")
            closeChildren()
            wm.shutdown()
            exit(0)
        default: log("painel: pedido desconhecido '\(line)'")
        }
    }

    /// A janela de um processo nosso na frente, com o teclado nela. Pedido daqui, do mesmo jeito que o foco da fita:
    /// pedido pelo próprio processo (`NSApp.activate()` ou o SkyLight), o painel às vezes ficava atrás do app da frente.
    private func front(_ p: Process?) {
        guard let pid = p?.processIdentifier, let w = windows[pid] else { return }
        Private.focus(pid: pid, window: w, element: AXUIElementCreateApplication(pid), switchWindow: true)
    }

    @objc func openPanel() {
        guard panel == nil else { return front(panel) }  // já aberto, atrás de outro app
        // O log do niri-os mostra a recarga dele, não a do painel.
        panel = child(["--settings"], quiet: true) { [weak self] p in
            // SIGTERM é o "Sair do NiriOS" fechando o painel junto; o resto é queda.
            let crashed = p.terminationReason == .uncaughtSignal ? p.terminationStatus != SIGTERM : p.terminationStatus != 0
            if crashed { log("painel caiu (\(p.terminationReason == .uncaughtSignal ? "sinal" : "código") \(p.terminationStatus))") }
            self?.panel = nil
            self?.wm.shortcutsPaused = false  // mesmo se o painel caiu gravando
            self?.wm.refocus()  // o teclado volta pra janela focada da fita
        }
    }

    /// Um processo nosso com janela (o painel, o update), que pede coisas por linhas no stdout (ver `command`).
    private func child(_ args: [String], quiet: Bool, ended: @escaping (Process) -> Void) -> Process? {
        guard let exe = Bundle.main.executableURL else { return nil }
        let p = Process(), out = Pipe()
        p.executableURL = exe
        p.arguments = args
        p.standardOutput = out
        if quiet { p.standardError = FileHandle.nullDevice }
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }  // o processo fechou
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
            DispatchQueue.main.async { lines.forEach { self?.command($0, from: p) } }
        }
        p.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                self?.windows[p.processIdentifier] = nil
                ended(p)
            }
        }
        do {
            try p.run()
            return p
        } catch {
            log("não consegui abrir \(args.joined(separator: " ")): \(error)")
            return nil
        }
    }

    // MARK: - Update (ver `Updater`)

    /// Uma vez por dia, a primeira 1 min depois de abrir. No relógio de parede: no monotônico o tempo com o Mac dormindo
    /// não conta, e cada noite empurraria a conferência. Só no app (o `.build/release/niri-os` não tem versão).
    private func scheduleUpdates() {
        guard AppBundle.version != nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(wallDeadline: .now() + 60, repeating: .seconds(24 * 3600), leeway: .seconds(600))
        t.setEventHandler { [weak self] in self?.checkUpdate(manual: false) }
        t.resume()
        updateTimer = t
    }

    private func checkUpdate(manual: Bool) {
        guard updater == nil else { return front(updater) }  // a pergunta de antes continua aberta
        updater = child(["--update"] + (manual ? ["--manual"] : []), quiet: false) { [weak self] _ in self?.updater = nil }
    }

    /// O app novo, já conferido pelo processo do update, no lugar deste. A troca é um rename (os dois na mesma partição);
    /// se falhar, fica tudo como estava. Depois guarda o estado sem mexer nas janelas, como o SIGUSR1, e reabre.
    private func install(_ path: String) {
        let staged = URL(fileURLWithPath: path)
        do {
            _ = try FileManager.default.replaceItemAt(Bundle.main.bundleURL, withItemAt: staged)
        } catch {
            return log("update: não consegui trocar o app (\(error.localizedDescription)); continuo nesta versão")
        }
        try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())  // a pasta temporária, já vazia
        log("update: app trocado, reabrindo")
        closeChildren()
        wm.saveState()
        AppBundle.relaunch()
    }
}
