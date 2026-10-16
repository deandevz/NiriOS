import AppKit
import NiriCore

let usage = """
niri-os: tiling em fita horizontal (estilo niri) pro macOS

  niri-os          roda o gerenciador (Ctrl+C devolve as janelas pra tela e sai)
  niri-os -v       idem, e mostra quantos frames cada app aplicou por animação
  niri-os --list   lista as janelas que entrariam na fita, sem mexer em nada
  niri-os --workspace <nome>   pede pro niri-os rodando ir pra esse workspace (ex.: clique na SketchyBar)

Atalhos: Option + / Option -   largura da coluna focada
         Option , / Option .   foco pra coluna da esquerda / direita (também Option ← →)
         Option Shift , / .   troca a coluna focada de lugar com a vizinha
         Option Cmd , / .     empilha a focada na coluna vizinha; empilhada, separa pra uma coluna só dela
         Option Cmd + / -     altura da focada numa coluna empilhada
         Option ↑ / ↓         foco na janela de cima / de baixo da coluna
         Option F             coluna em largura total (de novo: volta)
         Option D             mostra a mesa: as janelas saem pelas bordas (de novo: voltam)
         Option V             histórico do que foi copiado: clique cola, o alfinete fixa
         Option 1 a 4         vai pro workspace; com Shift, manda a janela focada pra ele
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
if let name = value("--workspace") {
    DistributedNotificationCenter.default().postNotificationName(WindowManager.workspaceRequest, object: name,
                                                                 userInfo: nil, deliverImmediately: true)
    exit(0)
}
// O painel de configurações, aberto pelo ícone na barra de menu (ver `Settings`).
if args.contains("--settings") { SettingsPanel.run() }
// O histórico do Option+V (ver `Clipboard`): o painel, aberto no canto do mouse, e a leitura de cada cópia nova.
if let x = value("--clipboard").flatMap(Double.init), let y = argv.last.flatMap(Double.init) {
    ClipboardPanel.run(at: NSPoint(x: x, y: y))
}
if let id = value("--clipboard-read"), let count = argv.last.flatMap(Int.init) {
    Clipboard.readProcess(id, expecting: count)
}
// O papel de parede, aberto pelo niri-os quando o config muda (ver `WallpaperArt`).
if let path = value("--wallpaper") {
    WallpaperProcess.run(path, effect: argv.last.flatMap(WallpaperEffect.init) ?? .none)
}

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
let names: [String: Action] = ["left": .focusLeft, "right": .focusRight, "grow": .grow, "shrink": .shrink,
                               "move-left": .moveColumnLeft, "move-right": .moveColumnRight,
                               "stack-left": .consumeOrExpelLeft, "stack-right": .consumeOrExpelRight,
                               "taller": .growHeight, "shorter": .shrinkHeight, "up": .focusUp, "down": .focusDown,
                               "full": .toggleFullWidth, "desktop": .toggleDesktop, "clipboard": .clipboard]
// Workspaces: ws:<nome> vai pra ele, move:<nome> manda a janela focada.
// `wait`: um passo sem ação (ex.: o painel do Option+V aberto, que qualquer outro atalho fecha).
dev.script = (value("--script") ?? "").split(separator: ",").compactMap { (s: Substring) -> Action?? in
    if s == "wait" { return .some(nil) }
    if s.hasPrefix("ws:") { return .workspace(String(s.dropFirst(3))) }
    if s.hasPrefix("move:") { return .moveToWorkspace(String(s.dropFirst(5))) }
    guard let a = names[String(s)] else { return nil }
    return a
}

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

// O processo do papel de parede caído: escrever no stdin dele vira erro, não queda do niri-os.
signal(SIGPIPE, SIG_IGN)
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
// No teste, só com outra pasta (`NIRI_CLIPBOARD`): o `clipboard` do --script abre e fecha o painel.
if settings != nil || ProcessInfo.processInfo.environment["NIRI_CLIPBOARD"] != nil { wm.clipboard = Clipboard() }
app.run()
