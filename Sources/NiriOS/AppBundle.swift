import AppKit
import ServiceManagement

/// O que muda quando o niri-os roda como NiriOS.app (ver README, "Distribuição"). De `.build/release/niri-os`
/// (desenvolvimento) não tem versão: sem update, sem abrir ao iniciar, sem tour, e o log fica no terminal.
enum AppBundle {
    static let isApp = Bundle.main.bundleURL.pathExtension == "app"
    static let version = isApp ? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String : nil
    static let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/niri-os.log")

    /// Aberto pelo Finder ou no login, o stderr vai pro nada: no app o log vai pro arquivo, menos rodando do terminal.
    /// Passou de 5 MB, o de antes vira `niri-os.old.log`. Os processos filhos herdam o arquivo.
    static func redirectLog() {
        guard isApp, isatty(STDERR_FILENO) == 0 else { return }
        if let size = try? logURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 5_000_000 {
            let old = logURL.deletingPathExtension().appendingPathExtension("old.log")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: logURL, to: old)
        }
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = freopen(logURL.path, "a", stderr)
        log("NiriOS \(version ?? "?") (pid \(getpid()))")
    }

    /// Um gerenciador por vez: dois mexendo nas mesmas janelas brigam a cada frame. O macOS não abre o app duas vezes, mas
    /// o `.build/release/niri-os` e o NiriOS.app abririam. O lock solta quando o processo sai, até caindo. Espera até 3 s:
    /// no `relaunch` o processo de antes ainda está saindo.
    static func lock() -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/niri-os/niri-os.lock")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return true }  // sem como conferir, não impede de abrir
        for _ in 0..<60 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return true }  // o descritor fica aberto até o processo sair
            usleep(50_000)
        }
        close(fd)
        return false
    }

    /// Erro que impede de abrir. No app aparece numa janela, porque o log ninguém vê.
    static func fail(_ message: String) -> Never {
        log(message)
        if isApp {
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "O NiriOS não abriu"
            alert.informativeText = message
            alert.runModal()
        }
        exit(1)
    }

    /// Abre outro niri-os com os mesmos argumentos e sai (fita ligada ou desligada, update, fim do tour). No app, pelo
    /// LaunchServices, como aberto pelo Finder: filho deste, a Acessibilidade e a Gravação de Tela seriam conferidas no
    /// processo que abriu, que vai sair. Ele recebe só as variáveis `NIRI_*` daqui (as de teste) e as de `environment`.
    static func relaunch(environment extra: [String: String] = [:]) -> Never {
        let args = Array(CommandLine.arguments.dropFirst())
        let env = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("NIRI_") }.merging(extra) { $1 }
        if isApp {
            let c = NSWorkspace.OpenConfiguration()
            c.createsNewApplicationInstance = true  // este ainda está aberto
            c.activates = false
            c.arguments = args
            c.environment = env
            LSRegisterURL(Bundle.main.bundleURL as CFURL, true)  // depois do update, a versão nova no mesmo lugar
            let done = DispatchSemaphore(value: 0)
            var failure: Error?
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: c) { _, e in
                failure = e
                done.signal()
            }
            if done.wait(timeout: .now() + 5) == .success, failure == nil { exit(0) }
            log("o macOS não reabriu o app (\(failure.map { "\($0)" } ?? "sem resposta em 5 s")): abrindo direto")
        }
        let p = Process()  // herda o stdout e o stderr (o log); os outros descritores ficam fechados no filho
        p.executableURL = Bundle.main.executableURL
        p.arguments = args
        p.environment = ProcessInfo.processInfo.environment.merging(extra) { $1 }
        do {
            try p.run()
        } catch {
            log("não consegui reiniciar (\(error)): abra o niri-os de novo")
            exit(1)
        }
        exit(0)  // o pipe do papel de parede fecha: ele vê o fim do stdin e sai, e o processo novo abre outro
    }

    /// Abrir ao iniciar o Mac. O estado fica no macOS (Ajustes > Geral > Itens de início), não no config: a pessoa
    /// pode desligar por lá. `.requiresApproval`: ela precisa ligar por lá.
    static var loginItem: SMAppService.Status { SMAppService.mainApp.status }

    static func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log("abrir ao iniciar: \(error.localizedDescription)")
        }
    }
}
