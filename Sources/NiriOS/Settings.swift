import AppKit

/// Ícone na barra de menu e recarga do config.json. O arquivo é a única fonte: tudo que muda nele (pelo
/// painel ou à mão) é aplicado na hora. Vigiado por FSEvents, sem polling.
///
/// Clique (esquerdo ou direito) no ícone abre o painel, que roda em outro processo (`niri-os --settings`)
/// e termina quando a janela fecha. Dentro deste, abrir o painel uma vez subia a memória de 12 pra 50 MB,
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
    private var panelWindow: CGWindowID?

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

    /// Ligar ou desligar a fita reinicia o niri-os: um processo novo do mesmo executável, com os mesmos argumentos e o
    /// mesmo log, e este sai. Montar e desmontar a fita com o app aberto teria que desfazer as filas por app, os
    /// observadores, o display link e as janelas nossas, e é desse tipo de sobra que nasce estado que discorda do layout.
    /// Assim são dois caminhos que já existem: desligar devolve as janelas pra tela (o mesmo do Ctrl+C) e guarda o
    /// estado; ligar monta a fita do state.json, como ao abrir. O painel aberto fecha e abre de novo no processo novo.
    /// Com `exec` (mesmo pid) o ícone ia pra fora da barra de menu e não voltava, nem tirando ele antes.
    private func restart() -> Never {
        log("fita \(wm.config.has(.tiling) ? "desligada" : "ligada"): reiniciando o niri-os")
        let reopen = panel != nil
        panel?.terminate()
        wm.shutdown()  // sem a fita, não mexe em nada
        let p = Process()  // herda o stdout e o stderr (o log); os outros descritores ficam fechados no filho
        p.executableURL = Bundle.main.executableURL
        p.arguments = Array(CommandLine.arguments.dropFirst())
        p.environment = ProcessInfo.processInfo.environment.merging(reopen ? [Self.reopenKey: "1"] : [:]) { $1 }
        do {
            try p.run()
        } catch {
            log("não consegui reiniciar (\(error)): abra o niri-os de novo")
            exit(1)
        }
        exit(0)  // o pipe do papel de parede fecha: ele vê o fim do stdin e sai, e o processo novo abre outro
    }

    static func openFile(reveal: Bool = false) {
        if !FileManager.default.fileExists(atPath: Config.path.path) { _ = Config.save([:]) }
        if reveal { NSWorkspace.shared.activateFileViewerSelecting([Config.path]) } else { NSWorkspace.shared.open(Config.path) }
    }

    /// O que o painel pede, uma linha por pedido.
    private func command(_ line: Substring) {
        let word = line.split(separator: " ")
        switch word.first ?? "" {
        case "pause", "resume": wm.shortcutsPaused = line == "pause"
        case "front":
            panelWindow = word.last.flatMap { CGWindowID($0) }
            frontPanel()
        case "reload": reload()
        case "quit":
            log("saindo pelo painel: devolvendo as janelas pra dentro da tela")
            panel?.terminate()
            wm.shutdown()
            exit(0)
        default: log("painel: pedido desconhecido '\(line)'")
        }
    }

    /// O painel na frente, com o teclado nele. Pedido daqui, do mesmo jeito que o foco da fita: pedido pelo
    /// próprio painel (`NSApp.activate()` ou o SkyLight), ele às vezes ficava atrás do app da frente.
    private func frontPanel() {
        guard let pid = panel?.processIdentifier, let w = panelWindow else { return }
        Private.focus(pid: pid, window: w, element: AXUIElementCreateApplication(pid), switchWindow: true)
    }

    @objc func openPanel() {
        guard panel == nil else { return frontPanel() }  // já aberto, atrás de outro app
        guard let exe = Bundle.main.executableURL else { return }
        let p = Process(), out = Pipe()
        p.executableURL = exe
        p.arguments = ["--settings"]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice  // o log do niri-os mostra a recarga dele, não a do painel
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }  // o painel fechou
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
            DispatchQueue.main.async { lines.forEach { self?.command($0) } }
        }
        p.terminationHandler = { [weak self] p in
            // SIGTERM é o "Sair do NiriOS" fechando o painel junto; o resto é queda.
            let crashed = p.terminationReason == .uncaughtSignal ? p.terminationStatus != SIGTERM : p.terminationStatus != 0
            if crashed { log("painel caiu (\(p.terminationReason == .uncaughtSignal ? "sinal" : "código") \(p.terminationStatus))") }
            DispatchQueue.main.async {
                self?.panel = nil
                self?.panelWindow = nil
                self?.wm.shortcutsPaused = false  // mesmo se o painel caiu gravando
                self?.wm.refocus()  // o teclado volta pra janela focada da fita
            }
        }
        do {
            try p.run()
            panel = p
        } catch {
            log("não consegui abrir o painel: \(error)")
        }
    }
}
