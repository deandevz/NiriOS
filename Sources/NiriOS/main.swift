import AppKit

let usage = """
niri-os: tiling em fita horizontal (estilo niri) pro macOS

  niri-os          roda o gerenciador (Ctrl+C devolve as janelas pra tela e sai)
  niri-os -v       idem, e mostra quantos frames cada app aplicou por animação
  niri-os --list   lista as janelas que entrariam na fita, sem mexer em nada

Atalhos: Option + / Option -   largura da coluna focada
         Option , / Option .   foco pra coluna da esquerda / direita (também Option < > e Option ← →)
         Option F             coluna em largura total (de novo: volta)
Config:  ~/.config/niri-os/config.json, ou pelo ícone na barra de menu. Salvar aplica na hora.
"""

let argv = Array(CommandLine.arguments.dropFirst())
let args = Set(argv)
func value(_ flag: String) -> String? {
    argv.firstIndex(of: flag).flatMap { $0 + 1 < argv.count ? argv[$0 + 1] : nil }
}
if args.contains("-h") || args.contains("--help") {
    print(usage)
    exit(0)
}
// O painel de configurações, aberto pelo ícone na barra de menu (ver `Settings`).
if args.contains("--settings") { SettingsPanel.run() }

let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
guard AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary) else {
    log("""
    sem permissão de Acessibilidade. Libere o app que está rodando o niri-os (o terminal, ex.: WezTerm) \
    em Ajustes do Sistema > Privacidade e Segurança > Acessibilidade, feche e abra o terminal e rode de novo.
    """)
    exit(1)
}

let config = Config.load()

if args.contains("--list") {
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, Float(config.axTimeout))
        let r = AppWorker.readWindows(app: el, timeout: Float(config.axTimeout))
        guard let windows = r.windows, !windows.isEmpty else { continue }
        print("\(app.localizedName ?? "?") (pid \(app.processIdentifier))")
        for w in windows {
            let f = w.frame
            let status = w.uncertain ? "sem resposta" : w.skipReason.map { "fora: \($0)" } ?? "na fita"
            print(String(format: "  %6u  %5.0f,%5.0f  %5.0fx%-5.0f  %@  \"%@\"", w.id, f.minX, f.minY, f.width, f.height,
                         status, String(w.title.prefix(50))))
        }
    }
    exit(0)
}

var dev = DevOptions()
if let pid = value("--pid").flatMap(Int32.init) {
    dev.pid = pid
    if let a = value("--area")?.split(separator: ",").compactMap({ Double($0) }), a.count == 4 {
        dev.area = CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
    }
}
// Sem --pid, o script roda nas janelas de verdade, com foco: é o único jeito de medir a troca de foco.
let names: [String: Action] = ["left": .focusLeft, "right": .focusRight, "grow": .grow,
                               "shrink": .shrink, "full": .toggleFullWidth]
dev.script = (value("--script") ?? "").split(separator: ",").compactMap { names[String($0)] }

// Dois gerenciadores mexendo nas mesmas janelas = briga a cada frame.
let rivals = ["OmniWM", "AeroSpace", "Amethyst", "Paneru"]
let running = NSWorkspace.shared.runningApplications.compactMap(\.localizedName).filter(rivals.contains)
if !running.isEmpty && !args.contains("--force") && dev.pid == nil {
    log("feche antes: \(running.joined(separator: ", ")). (Ou rode com --force.)")
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let wm = WindowManager(config: config, verbose: args.contains("-v") || args.contains("--verbose"), dev: dev)

var signalSources: [DispatchSourceSignal] = []
// SIGUSR1: sai sem mexer nas janelas (pra reiniciar uma versão nova sem bagunçar a tela).
signal(SIGUSR1, SIG_IGN)
let handoff = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
handoff.setEventHandler {
    wm.saveState()
    log("saindo sem mexer nas janelas (estado salvo)")
    exit(0)
}
handoff.resume()
signalSources.append(handoff)
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        log("saindo: devolvendo as janelas pra dentro da tela")
        wm.shutdown()
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

wm.start()
// Teste (--pid, --script) não ganha ícone nem recarga: roda ao lado da instância de verdade.
let settings = dev.pid == nil && dev.script.isEmpty ? Settings(wm: wm) : nil
app.run()
