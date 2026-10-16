import AppKit
import Carbon.HIToolbox
import NiriCore
import SwiftUI

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
        wm.apply(Config.load())
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

    @objc private func openPanel() {
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

// MARK: - O painel (processo `niri-os --settings`)

enum SettingsPanel {
    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)  // sem Dock, e o niri-os não põe na fita (só apps normais)
        // Sem barra de menu própria, mas os atalhos do menu principal valem com o painel na frente.
        let edit = NSMenu()
        edit.addItem(withTitle: "Fechar", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        edit.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        app.mainMenu = NSMenu()
        app.mainMenu!.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = edit
        let panel = PanelController()
        panel.show()
        app.run()
        exit(0)
    }
}

final class PanelController: NSObject, NSWindowDelegate {
    let model = SettingsModel()
    private var window: NSWindow?
    private var keyMonitor: Any?
    private var pendingSave: DispatchWorkItem?

    func show() {
        model.load(Config.load())
        refreshPreview()
        let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(panel: self)))
        w.styleMask = [.titled, .closable]
        w.title = "NiriOS"
        w.delegate = self
        w.setContentSize(SettingsView.size)  // o SwiftUI só dá o tamanho depois: centralizada antes, ficava à direita
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        send("front \(w.windowNumber)")  // o niri-os traz pra frente (ver `Settings.frontPanel`)
    }

    /// Pedido pro niri-os, pelo pipe (ver `Settings.command`).
    func send(_ line: String) {
        print(line)
        fflush(stdout)
    }

    func windowDidResignKey(_ notification: Notification) { record(nil) }

    func windowWillClose(_ notification: Notification) {
        pendingSave?.perform()
        record(nil)
        DispatchQueue.main.async { exit(0) }
    }

    /// Grava 150 ms depois da última mudança: arrastando a cor ou a espessura, uma gravação só no fim.
    func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Só o que difere do padrão vai pro arquivo, e o resto do arquivo fica como estava. O niri-os vê o
    /// arquivo mudar e aplica.
    private func save() {
        pendingSave = nil
        let m = model
        var overridden: [String: [String]] = [:]
        for a in Action.allCases where m.shortcuts[a] != Config.defaultShortcuts[a] {
            overridden[a.rawValue] = m.shortcuts[a, default: []].map(\.description)
        }
        guard Config.save(["shortcuts": overridden.isEmpty ? nil : overridden,
                           "ghostBorderColor": m.accent ? nil : m.color.hex,
                           "ghostBorderWidth": m.width == 3 ? nil : m.width,
                           "wallpaper": m.wallpaper.map { ($0.path as NSString).abbreviatingWithTildeInPath },
                           "wallpaperEffect": m.effect == .none ? nil : m.effect.rawValue]) else {
            m.status = "Não salvei: o config.json atual não é um JSON válido. Corrija ou apague o arquivo."
            return
        }
        m.warnings = Config.load().warnings
        m.status = "Salvo às \(Date().formatted(date: .omitted, time: .standard))"
    }

    func chooseWallpaper() {
        guard let window else { return }
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image, .movie]
        p.message = "Imagem (com efeito, se quiser) ou vídeo (toca só com a mesa à mostra)"
        p.directoryURL = model.wallpaper?.deletingLastPathComponent()
        p.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let url = p.url, let self else { return }
            model.wallpaper = url
            if WallpaperArt.isVideo(url) { model.effect = .none }
            wallpaperChanged()
        }
    }

    func wallpaperChanged() {
        scheduleSave()
        refreshPreview()
    }

    private func refreshPreview() {
        let m = model, url = m.wallpaper, effect = m.effect, screen = NSScreen.screens[0]
        let box = m.previewBox, size = screen.frame.size, scale = screen.backingScaleFactor
        guard let url else { m.preview = nil; return }
        DispatchQueue.global(qos: .userInitiated).async {
            let img = WallpaperArt.preview(url, effect: effect, screen: size, scale: scale, box: box)
            DispatchQueue.main.async {
                guard m.wallpaper == url, m.effect == effect else { return }  // já trocou de novo
                m.preview = img
            }
        }
    }

    func add(_ k: Shortcut, to a: Action) {
        for b in Action.allCases { model.shortcuts[b]?.removeAll { $0 == k } }  // sai de onde estava
        model.shortcuts[a, default: []].append(k)
        scheduleSave()
    }

    func remove(_ k: Shortcut, from a: Action) {
        model.shortcuts[a]?.removeAll { $0 == k }
        scheduleSave()
    }

    func reset(_ a: Action) {
        let defaults = Config.defaultShortcuts[a] ?? []
        for b in Action.allCases { model.shortcuts[b]?.removeAll(where: defaults.contains) }
        model.shortcuts[a] = defaults
        scheduleSave()
    }

    /// Grava a próxima combinação apertada. O niri-os pausa os atalhos enquanto isso (linha no pipe): o tap
    /// dele pega a tecla no nível HID, antes do painel.
    func record(_ a: Action?) {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        if (keyMonitor != nil) != (a != nil) { send(a != nil ? "pause" : "resume") }
        keyMonitor = nil
        model.recording = a
        model.heldModifiers = ""
        guard let a else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] e in
            guard let self, let flags = e.cgEvent?.flags else { return e }
            let k = Shortcut(key: Int64(e.keyCode), mods: flags)
            if e.type == .flagsChanged {
                model.heldModifiers = Shortcut.display(k.mods)
                return e
            }
            if e.keyCode == kVK_Escape && k.mods.isEmpty {
                record(nil)
            } else if k.mods.subtracting(.maskShift).isEmpty {
                NSSound.beep()  // sem ⌃ ⌥ ⌘ viraria atalho de letra comum
            } else {
                add(k, to: a)
                record(nil)
            }
            return nil
        }
    }
}

@Observable final class SettingsModel {
    var shortcuts: [Action: [Shortcut]] = [:]
    var workspaces: [WorkspaceRule] = []
    /// Borda na cor de destaque do sistema; senão, `color`.
    var accent = true
    var color = NSColor.systemOrange
    var width = 3.0
    var recording: Action?
    /// Modificadores apertados enquanto grava, pra pessoa ver que a tecla chegou.
    var heldModifiers = ""
    var status = ""
    var warnings: [String] = []
    var wallpaper: URL?
    var effect = WallpaperEffect.none
    var preview: CGImage?
    var isVideo: Bool { wallpaper.map(WallpaperArt.isVideo) ?? false }
    /// Com efeito, a prévia é um recorte do centro em tamanho real; sem efeito, a tela inteira reduzida.
    var cropped: Bool { effect != .none && !isVideo }
    /// No formato da tela e um pouco mais larga que a linha do painel (~500 pt): cobre o quadro sem faixa preta.
    var previewBox: CGSize {
        let s = NSScreen.screens[0].frame.size
        return CGSize(width: 560, height: (560 * s.height / s.width).rounded())
    }

    func load(_ c: Config) {
        shortcuts = c.shortcuts
        workspaces = c.workspaces
        accent = c.ghostBorderColor == nil
        if let col = c.ghostBorderColor { color = col }
        width = c.ghostBorderWidth
        warnings = c.warnings
        wallpaper = c.wallpaper
        effect = c.wallpaperEffect
    }
}

extension Action {
    var title: String {
        switch self {
        case .grow: "Aumentar largura"
        case .shrink: "Diminuir largura"
        case .focusLeft: "Foco à esquerda"
        case .focusRight: "Foco à direita"
        case .toggleFullWidth: "Largura total"
        case .toggleDesktop: "Mostrar a mesa"
        case .workspace(let n): "Workspace \(n)"
        case .moveToWorkspace(let n): "Mandar a janela pro \(n)"
        }
    }
}

extension WallpaperEffect {
    /// Os nomes e as dicas do Kinggie.
    var title: String {
        switch self {
        case .none: "Nenhum"
        case .dither: "Dither"
        case .halftone: "Meio-tom"
        case .scanlines: "Scanlines"
        case .ascii: "ASCII"
        }
    }

    var hint: String {
        switch self {
        case .none: "Mostra a imagem original."
        case .dither: "Poucas cores, em pontilhado."
        case .halftone: "Pontos do tamanho do brilho."
        case .scanlines: "Linhas de tela antiga."
        case .ascii: "A imagem escrita em letras."
        }
    }
}

// MARK: - SwiftUI

private struct SettingsView: View {
    let panel: PanelController
    private var model: SettingsModel { panel.model }

    /// Muda o modelo e grava.
    private func bind<T>(_ path: ReferenceWritableKeyPath<SettingsModel, T>) -> Binding<T> {
        Binding(get: { panel.model[keyPath: path] }, set: { panel.model[keyPath: path] = $0; panel.scheduleSave() })
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "rectangle.split.3x1.fill")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing),
                                    in: .rect(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("NiriOS").font(.title2.weight(.semibold))
                        Text("Tudo aqui vai pro config.json e vale na hora.").foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                ForEach(Action.allCases, id: \.self) { ShortcutRow(panel: panel, action: $0) }
            } header: {
                Text("Atalhos")
            } footer: {
                Text("+ grava um atalho novo (Esc cancela). Precisa de ⌃, ⌥ ou ⌘. A tecla vale pela posição: igual em US e ABNT2.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(model.workspaces, id: \.name) { WorkspaceRow(workspace: $0, model: model) }
            } header: {
                Text("Workspaces")
            } footer: {
                Text("Lado a lado, nessa ordem. A lista, os atalhos e os apps de cada um ficam na chave workspaces do config.json.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Vidro do resize") {
                GlassPreview(color: model.accent ? nil : model.color, width: model.width)
                    .frame(height: 170)
                    .clipShape(.rect(cornerRadius: 8))
                Toggle("Cor de destaque do sistema", isOn: bind(\.accent))
                ColorPicker("Cor da borda", selection: Binding(get: { Color(nsColor: model.color) },
                                                               set: { model.color = NSColor($0); panel.scheduleSave() }))
                    .disabled(model.accent)
                LabeledContent("Espessura") {
                    HStack {
                        Slider(value: bind(\.width), in: 0...8, step: 0.5).frame(width: 180)
                        Text(String(format: "%.1f pt", model.width)).monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                }
            }

            Section {
                WallpaperPreview(image: model.preview, cropped: model.cropped, box: model.previewBox)
                LabeledContent("Arquivo") {
                    HStack {
                        Text(model.wallpaper?.lastPathComponent ?? "O do macOS")
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Escolher…") { panel.chooseWallpaper() }
                        if model.wallpaper != nil {
                            Button("Remover") {
                                model.wallpaper = nil
                                model.effect = .none
                                panel.wallpaperChanged()
                            }
                        }
                    }
                }
                Picker("Efeito", selection: Binding(get: { model.effect }, set: { model.effect = $0; panel.wallpaperChanged() })) {
                    ForEach(WallpaperEffect.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .disabled(model.wallpaper == nil || model.isVideo)
            } header: {
                Text("Papel de parede")
            } footer: {
                Group {
                    if model.isVideo {
                        Text("Vídeo: toca só com a mesa à mostra (⌥D ou sem janelas) e para no quadro onde estava quando as janelas voltam.")
                    } else if model.wallpaper != nil {
                        Text("\(model.effect.hint) A imagem vira o papel de parede do macOS, sem custo com o niri-os rodando. Remover devolve o de antes.")
                    } else {
                        Text("Imagem com efeito (dither, meio-tom, scanlines, ASCII) ou vídeo em loop. ⌥D mostra a mesa sem os ícones.")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Arquivo") {
                    Text(Config.path.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.callout.monospaced()).textSelection(.enabled)
                }
                HStack {
                    Button("Abrir no editor") { Settings.openFile() }
                    Button("Mostrar no Finder") { Settings.openFile(reveal: true) }
                    Button("Recarregar") { panel.send("reload") }
                    Spacer()
                    Text(model.status).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.warnings, id: \.self) {
                    Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                }
            } header: {
                Text("Config")
            } footer: {
                Text("Salvar o arquivo à mão também aplica na hora. Gap, margens e mola animam as janelas pro lugar novo; resizeStyle só muda ao reiniciar.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent {
                    Button("Sair do NiriOS", role: .destructive) { panel.send("quit") }
                } label: {
                    Text("Sair")
                    Text("Devolve todas as janelas pra dentro da tela e fecha o gerenciador.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: Self.size.width, height: Self.size.height)
    }

    static let size = CGSize(width: 560, height: 720)
}

private struct ShortcutRow: View {
    let panel: PanelController
    let action: Action

    var body: some View {
        let model = panel.model
        let keys = model.shortcuts[action] ?? []
        let recording = model.recording == action
        LabeledContent(action.title) {
            HStack(spacing: 6) {
                if keys.isEmpty && !recording { Text("Desligado").foregroundStyle(.tertiary) }
                ForEach(keys, id: \.self) { k in KeyCap(text: k.display) { panel.remove(k, from: action) } }
                if recording { KeyCap(text: model.heldModifiers.isEmpty ? "Aperte o atalho…" : "\(model.heldModifiers) …", active: true) }
                Button { panel.record(recording ? nil : action) } label: {
                    Image(systemName: recording ? "xmark.circle.fill" : "plus.circle.fill")
                }
                .buttonStyle(.borderless)
                .help(recording ? "Cancelar" : "Gravar um atalho novo")
                if keys != Config.defaultShortcuts[action] {
                    Button { panel.reset(action) } label: { Image(systemName: "arrow.uturn.backward.circle") }
                        .buttonStyle(.borderless)
                        .help("Voltar ao padrão: " + (Config.defaultShortcuts[action] ?? []).map(\.display).joined(separator: ", "))
                }
            }
            .foregroundStyle(.secondary)
        }
    }
}

/// Um workspace: atalho pra ir e pra mandar a janela, e os apps que abrem nele. Só mostra: editar é no arquivo.
private struct WorkspaceRow: View {
    let workspace: WorkspaceRule
    let model: SettingsModel

    var body: some View {
        let go = model.shortcuts[.workspace(workspace.name)] ?? [], move = model.shortcuts[.moveToWorkspace(workspace.name)] ?? []
        LabeledContent {
            HStack(spacing: 6) {
                if go.isEmpty && move.isEmpty { Text("Sem atalho").foregroundStyle(.tertiary) }
                ForEach(go, id: \.self) { KeyCap(text: $0.display) }
                ForEach(move, id: \.self) { KeyCap(text: $0.display).help("Manda a janela focada pra cá") }
            }
        } label: {
            Text(workspace.name).font(.body.weight(.semibold))
            let apps = workspace.apps + (workspace.open.map { ["abre \($0) se vazio"] } ?? [])
            if !apps.isEmpty { Text(apps.joined(separator: ", ")) }
        }
    }
}

/// Uma tecla desenhada. Com o mouse em cima, aparece o x pra remover (no canto, sem empurrar as outras).
private struct KeyCap: View {
    let text: String
    var active = false
    var remove: (() -> Void)?
    @State private var hover = false

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(active ? .secondary : .primary)
            .padding(.horizontal, 8)
            .frame(minWidth: 30, minHeight: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.18), radius: 0.5, y: 1))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(active ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: active ? 1.5 : 0.5))
            .overlay(alignment: .topTrailing) {
                if hover, let remove {
                    Button(action: remove) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 13)).symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .gray)
                    }
                    .buttonStyle(.plain)
                    .offset(x: 6, y: -6)
                    .help("Remover")
                }
            }
            .onHover { hover = $0 }
    }
}

/// Prévia do papel de parede num quadro no formato da tela, na largura da linha. A tela inteira é reduzida
/// pra caber; o recorte com efeito fica em pixels reais (sem filtro: o dither tem que aparecer em blocos nítidos).
private struct WallpaperPreview: View {
    let image: CGImage?
    let cropped: Bool
    let box: CGSize

    var body: some View {
        Color.black
            .aspectRatio(box.width / box.height, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                if let image {
                    let img = Image(decorative: image, scale: NSScreen.screens[0].backingScaleFactor)
                    if cropped { img.interpolation(.none) } else { img.resizable().interpolation(.high).aspectRatio(contentMode: .fill) }
                } else {
                    Text("Papel de parede do macOS").foregroundStyle(.secondary)
                }
            }
            .clipShape(.rect(cornerRadius: 8))
        .overlay(alignment: .bottomTrailing) {
            if cropped && image != nil {
                Text("centro, em tamanho real").font(.caption2).foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 6).padding(.vertical, 2).background(.black.opacity(0.6), in: .capsule).padding(6)
            }
        }
    }
}

/// O vidro de verdade (o mesmo `NSVisualEffectView` do resize) sobre o papel de parede da tela.
private struct GlassPreview: NSViewRepresentable {
    let color: NSColor?
    let width: Double

    final class Backdrop: NSView {
        let glass: NSVisualEffectView

        init() {
            let icon = NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
            glass = GhostOverlay.glass(CGRect(x: 0, y: 0, width: 200, height: 120), icon: icon, iconSize: 56, border: (nil, 3))
            glass.blendingMode = .withinWindow  // desfoca o papel de parede desta janela, não a tela atrás
            super.init(frame: .zero)
            wantsLayer = true
            layer?.contentsGravity = .resizeAspectFill
            layer?.backgroundColor = NSColor.systemIndigo.cgColor
            layer?.contents = Self.wallpaper()
            addSubview(glass)
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            glass.frame = bounds.insetBy(dx: bounds.width * 0.2, dy: 24)
        }

        /// Miniatura de 1000 px: o papel de parede 4K decodificado inteiro teria 33 MB.
        private static func wallpaper() -> CGImage? {
            guard let screen = NSScreen.screens.first, let url = NSWorkspace.shared.desktopImageURL(for: screen),
                  let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                kCGImageSourceThumbnailMaxPixelSize: 1000] as CFDictionary)
        }
    }

    func makeNSView(context: Context) -> Backdrop { Backdrop() }

    func updateNSView(_ v: Backdrop, context: Context) {
        v.glass.layer?.borderWidth = width
        v.glass.layer?.borderColor = (color ?? .controlAccentColor).cgColor
    }
}
