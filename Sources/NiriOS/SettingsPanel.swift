import AppKit
import Carbon.HIToolbox
import NiriCore
import ServiceManagement
import SwiftUI

/// O painel de configurações (processo `niri-os --settings`, aberto pelo ícone na barra; ver `Settings`).
enum SettingsPanel {
    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)  // sem Dock, e o niri-os não põe na fita (só apps normais)
        // Sem barra de menu própria, mas os atalhos do menu principal valem com o painel na frente.
        let edit = NSMenu()
        edit.addItem(withTitle: "Fechar", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        edit.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Colar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Selecionar tudo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
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
    private let tabs = NSTabViewController()
    private var keyMonitor: Any?
    private var pendingSave: DispatchWorkItem?
    /// Nome e ícone de cada regra de app: o LaunchServices não é consultado a cada desenho.
    private var apps: [String: AppRef] = [:]

    func show() {
        model.load(Config.load())
        refreshPreview()
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(tab("Recursos", "switch.2", height: 340, FeaturesTab(panel: self)))
        tabs.addTabViewItem(tab("Atalhos", "keyboard", height: 290, ShortcutsTab(panel: self)))
        tabs.addTabViewItem(tab("Workspaces", "rectangle.split.3x1", height: 470, WorkspacesTab(panel: self)))
        tabs.addTabViewItem(tab("Papel de parede", "photo", height: 520, WallpaperTab(panel: self)))
        tabs.addTabViewItem(tab("Borda", "square.dashed", height: 360, BorderTab(panel: self)))
        tabs.addTabViewItem(tab("Geral", "gearshape", height: 400, GeneralTab(panel: self)))
        // Abre na última aba usada (`-settingsTab <n>` na linha de comando também vale).
        tabs.selectedTabViewItemIndex = min(UserDefaults.standard.integer(forKey: "settingsTab"), tabs.tabViewItems.count - 1)
        let w = NSWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable]
        w.toolbarStyle = .preference
        w.delegate = self
        w.layoutIfNeeded()  // o tamanho da aba antes de centralizar: sem isso ficava à direita
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        send("front \(w.windowNumber)")  // o niri-os traz pra frente (ver `Settings.front`)
    }

    private func tab(_ title: String, _ icon: String, height: CGFloat, _ view: some View) -> NSTabViewItem {
        let host = NSHostingController(rootView: Page(model: model, content: view).frame(width: 620, height: height))
        host.sizingOptions = .preferredContentSize  // a janela muda de altura com a aba
        host.title = title  // vira o título da janela
        let item = NSTabViewItem(viewController: host)
        item.label = title
        item.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)
        return item
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
        UserDefaults.standard.set(tabs.selectedTabViewItemIndex, forKey: "settingsTab")
        DispatchQueue.main.async { exit(0) }
    }

    /// Muda o modelo e grava.
    func bind<T>(_ path: ReferenceWritableKeyPath<SettingsModel, T>) -> Binding<T> {
        Binding(get: { self.model[keyPath: path] }, set: { self.model[keyPath: path] = $0; self.scheduleSave() })
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
        for a in Action.allCases where m.shortcuts[a] != Config.defaults(for: a) {
            overridden[a.rawValue] = m.shortcuts[a, default: []].map(\.description)
        }
        // Workspace sem nada além do padrão vai só com o nome, como "Y".
        let workspaces: [Any] = m.workspaces.map { w in
            var o: [String: Any] = [:]
            if !w.apps.isEmpty { o["apps"] = w.apps }
            if let open = w.open { o["open"] = open }
            for (field, a) in [("key", Action.workspace(w.name)), ("moveKey", .moveToWorkspace(w.name))]
            where m.shortcuts[a, default: []] != Config.defaults(for: a) {
                o[field] = m.shortcuts[a, default: []].map(\.description)  // [] desliga
            }
            if o.isEmpty { return w.name }
            o["name"] = w.name
            return o
        }
        guard Config.save(["shortcuts": overridden.isEmpty ? nil : overridden,
                           "workspaces": workspaces as? [String] == ["1", "2", "3", "4"] ? nil : workspaces,
                           "borderColor": m.accent ? nil : m.color.hex,
                           "borderWidth": m.width == 3 ? nil : m.width,
                           "ghostBorderColor": nil, "ghostBorderWidth": nil,  // os nomes de antes
                           "wallpaper": m.wallpaper.map { ($0.path as NSString).abbreviatingWithTildeInPath },
                           "wallpaperEffect": m.effect == .none ? nil : m.effect.rawValue,
                           "features": m.disabled.isEmpty ? nil : Dictionary(uniqueKeysWithValues: m.disabled.map { ($0.rawValue, false) })]) else {
            m.saveError = "Não salvei: o config.json não é um JSON válido. Corrija ou apague o arquivo."
            return
        }
        m.saveError = nil
        m.warnings = Config.load().warnings
    }

    // MARK: Atalhos

    func add(_ k: Shortcut, to a: Action) {
        for b in model.shortcuts.keys { model.shortcuts[b]?.removeAll { $0 == k } }  // sai de onde estava
        model.shortcuts[a, default: []].append(k)
        scheduleSave()
    }

    func remove(_ k: Shortcut, from a: Action) {
        model.shortcuts[a]?.removeAll { $0 == k }
        scheduleSave()
    }

    func reset(_ a: Action) {
        let defaults = Config.defaults(for: a)
        for b in model.shortcuts.keys { model.shortcuts[b]?.removeAll(where: defaults.contains) }
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
        model.needsModifier = false
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
                model.needsModifier = true
            } else {
                add(k, to: a)
                record(nil)
            }
            return nil
        }
    }

    // MARK: Workspaces

    /// Os atalhos padrão do workspace, menos os que já são de outra ação.
    private func freeDefaults(_ a: Action) -> [Shortcut] {
        let taken = Set(model.shortcuts.filter { $0.key != a }.values.joined())
        return Config.defaults(for: a).filter { !taken.contains($0) }
    }

    func addWorkspace() {
        let name = (1...).lazy.map(String.init).first { n in !model.workspaces.contains { $0.name == n } }!
        model.workspaces.append(WorkspaceRule(name: name))
        for a in [Action.workspace(name), .moveToWorkspace(name)] { model.shortcuts[a] = freeDefaults(a) }
        model.selected = name
        scheduleSave()
    }

    /// As janelas dele vão pro workspace da tela (ver `Workspaces.setNames`).
    func removeWorkspace(_ name: String) {
        guard model.workspaces.count > 1, let i = model.index(name) else { return }
        record(nil)
        model.workspaces.remove(at: i)
        model.shortcuts[.workspace(name)] = nil
        model.shortcuts[.moveToWorkspace(name)] = nil
        model.selected = model.workspaces[min(i, model.workspaces.count - 1)].name
        scheduleSave()
    }

    /// No mesmo lugar da lista: o niri-os leva as janelas pro nome novo. Atalho que estava no padrão vai pro
    /// padrão do nome novo (o 5 virando W: ⌥5 vira ⌥W).
    func renameWorkspace(_ old: String, to new: String) -> Bool {
        let new = new.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, model.index(new) == nil, let i = model.index(old) else { return false }
        record(nil)
        model.workspaces[i].name = new
        for (from, to) in [(Action.workspace(old), Action.workspace(new)), (.moveToWorkspace(old), .moveToWorkspace(new))] {
            let keys = model.shortcuts.removeValue(forKey: from) ?? []
            model.shortcuts[to] = keys == Config.defaults(for: from) ? freeDefaults(to) : keys
        }
        model.selected = new
        scheduleSave()
        return true
    }

    func moveWorkspaces(_ from: IndexSet, to: Int) {
        model.workspaces.move(fromOffsets: from, toOffset: to)
        scheduleSave()
    }

    /// Vai pelo bundle id. Um app abre num workspace só: sai de onde estava, menos de um padrão com *, que
    /// pega outros apps também.
    func addApp(bundleID: String?, name app: String, to name: String) {
        for i in model.workspaces.indices where model.workspaces[i].apps.contains(where: { Self.isRule($0, of: app, bundleID: bundleID) }) {
            model.workspaces[i].apps.removeAll { Self.isRule($0, of: app, bundleID: bundleID) }
            if model.workspaces[i].open == self.app(bundleID ?? app).name { model.workspaces[i].open = nil }
        }
        guard let i = model.index(name) else { return }
        model.workspaces[i].apps.append(bundleID ?? app)
        scheduleSave()
    }

    private static func isRule(_ rule: String, of app: String, bundleID: String?) -> Bool {
        !rule.hasSuffix("*") && WorkspaceRule(name: "", apps: [rule]).matches(app: app, bundleID: bundleID)
    }

    func removeApp(_ rule: String, from name: String) {
        guard let i = model.index(name) else { return }
        model.workspaces[i].apps.removeAll { $0 == rule }
        if model.workspaces[i].open == app(rule).name { model.workspaces[i].open = nil }
        scheduleSave()
    }

    func setOpen(_ app: String?, for name: String) {
        guard let i = model.index(name) else { return }
        model.workspaces[i].open = app
        scheduleSave()
    }

    func chooseApp(for name: String) {
        guard let window else { return }
        let p = NSOpenPanel()
        p.allowedContentTypes = [.application]
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let url = p.url else { return }
            self?.addApp(bundleID: Bundle(url: url)?.bundleIdentifier, name: url.deletingPathExtension().lastPathComponent, to: name)
        }
    }

    /// Uma regra de `apps` (bundle id, nome ou começo do nome com *) e o app dela.
    func app(_ rule: String) -> AppRef {
        if let a = apps[rule] { return a }
        let ws = NSWorkspace.shared, pattern = rule.hasSuffix("*")
        let url = pattern ? Self.firstApp(prefix: rule.dropLast().lowercased()) : ws.urlForApplication(withBundleIdentifier: rule)
            ?? ws.runningApplications.first { $0.localizedName?.caseInsensitiveCompare(rule) == .orderedSame }?.bundleURL
            ?? ["/Applications", "/System/Applications", "/System/Applications/Utilities"]
                .map { URL(fileURLWithPath: "\($0)/\(rule).app") }.first { FileManager.default.fileExists(atPath: $0.path) }
        let icon = url.map { ws.icon(forFile: $0.path) } ?? ws.icon(for: .applicationBundle)
        icon.size = NSSize(width: 16, height: 16)  // no tamanho do menu; nas linhas, redimensionado
        // O padrão aparece como foi escrito, e não é um app só pra abrir.
        let a = AppRef(name: pattern ? rule : url?.deletingPathExtension().lastPathComponent ?? rule, icon: icon,
                       url: pattern ? nil : url)
        apps[rule] = a
        return a
    }

    /// O 1º app em /Applications com esse começo de nome, solto ou numa pasta ("Adobe Premiere Pro 2025/").
    private static func firstApp(prefix: String) -> URL? {
        let fm = FileManager.default, root = URL(fileURLWithPath: "/Applications")
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where name.lowercased().hasPrefix(prefix) {
            let u = root.appendingPathComponent(name)
            if u.pathExtension == "app" { return u }
            if let inner = try? fm.contentsOfDirectory(atPath: u.path).first(where: { $0.hasSuffix(".app") && $0.lowercased().hasPrefix(prefix) }) {
                return u.appendingPathComponent(inner)
            }
        }
        return nil
    }

    /// Os apps abertos que esse workspace ainda não pega, pra escolher num clique, e o workspace de cada um.
    func runningApps(for w: WorkspaceRule) -> [(bundleID: String?, name: String, ref: AppRef, current: String?)] {
        NSWorkspace.shared.runningApplications.compactMap { a in
            guard a.activationPolicy == .regular, a.processIdentifier != getpid(), let name = a.localizedName,
                  !w.matches(app: name, bundleID: a.bundleIdentifier) else { return nil }
            let current = model.workspaces.first { $0.apps.contains { Self.isRule($0, of: name, bundleID: a.bundleIdentifier) } }
            return (a.bundleIdentifier, name, app(a.bundleIdentifier ?? name), current?.name)
        }
        .sorted { $0.ref.name.localizedStandardCompare($1.ref.name) == .orderedAscending }
    }

    // MARK: Papel de parede

    func chooseWallpaper() {
        guard let window else { return }
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image, .movie]
        p.directoryURL = model.wallpaper?.deletingLastPathComponent()
        p.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let url = p.url, let self else { return }
            model.wallpaper = url
            if WallpaperArt.isVideo(url) { model.effect = .none }
            wallpaperChanged()
        }
    }

    func setFeature(_ f: Feature, on: Bool) {
        if on { model.disabled.remove(f) } else { model.disabled.insert(f) }
        record(nil)  // gravando o atalho de um recurso que acabou de desligar
        // A fita reinicia o niri-os, que fecha este painel e abre outro: na mesma aba.
        if f == .tiling { UserDefaults.standard.set(tabs.selectedTabViewItemIndex, forKey: "settingsTab") }
        scheduleSave()
    }

    func setOpensAtLogin(_ on: Bool) {
        AppBundle.setOpensAtLogin(on)
        model.loginItem = AppBundle.loginItem
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
}

struct AppRef {
    let name: String
    let icon: NSImage
    /// nil: padrão com *, ou app não instalado. Só app com url entra no "Abrir quando vazio".
    let url: URL?
}

@Observable final class SettingsModel {
    var shortcuts: [Action: [Shortcut]] = [:]
    var workspaces: [WorkspaceRule] = []
    /// O workspace aberto na aba Workspaces.
    var selected: String?
    /// Borda na cor de destaque do sistema; senão, `color`.
    var accent = true
    var color = NSColor.systemOrange
    var width = 3.0
    var recording: Action?
    /// Modificadores apertados enquanto grava, pra pessoa ver que a tecla chegou.
    var heldModifiers = ""
    /// Apertou uma tecla sem ⌃ ⌥ ⌘ gravando.
    var needsModifier = false
    var saveError: String?
    var warnings: [String] = []
    var wallpaper: URL?
    var effect = WallpaperEffect.none
    var preview: CGImage?
    var disabled: Set<Feature> = []
    /// Abrir ao iniciar o Mac: o estado é do macOS (ver `AppBundle.loginItem`).
    var loginItem = AppBundle.isApp ? AppBundle.loginItem : .notRegistered
    func has(_ f: Feature) -> Bool { f.isOn(disabled) }
    var isVideo: Bool { wallpaper.map(WallpaperArt.isVideo) ?? false }
    /// Com efeito, a prévia é um recorte do centro em tamanho real; sem efeito, a tela inteira reduzida.
    var cropped: Bool { effect != .none && !isVideo }
    /// No formato da tela e um pouco mais larga que a linha do painel: cobre o quadro sem faixa preta.
    var previewBox: CGSize {
        let s = NSScreen.screens[0].frame.size
        return CGSize(width: 580, height: (580 * s.height / s.width).rounded())
    }

    func index(_ workspace: String) -> Int? { workspaces.firstIndex { $0.name == workspace } }

    func load(_ c: Config) {
        shortcuts = c.shortcuts
        workspaces = c.workspaces
        selected = c.workspaces.first?.name
        accent = c.borderColor == nil
        if let col = c.borderColor { color = col }
        width = c.borderWidth
        warnings = c.warnings
        wallpaper = c.wallpaper
        effect = c.wallpaperEffect
        disabled = c.disabled
    }
}

extension Action {
    var title: String {
        switch self {
        case .grow: "Aumentar largura"
        case .shrink: "Diminuir largura"
        case .growHeight: "Aumentar altura (janelas empilhadas)"
        case .shrinkHeight: "Diminuir altura (janelas empilhadas)"
        case .focusLeft: "Foco à esquerda"
        case .focusRight: "Foco à direita"
        case .focusUp: "Foco na janela de cima"
        case .focusDown: "Foco na janela de baixo"
        case .moveColumnLeft: "Mover coluna pra esquerda"
        case .moveColumnRight: "Mover coluna pra direita"
        case .consumeOrExpelLeft: "Empilhar à esquerda / separar"
        case .consumeOrExpelRight: "Empilhar à direita / separar"
        case .toggleFullWidth: "Largura total"
        case .toggleDesktop: "Mostrar a mesa"
        case .clipboard: "Histórico do que foi copiado"
        case .workspace: "Ir pro workspace"
        case .moveToWorkspace: "Mandar a janela focada"
        }
    }
}

extension Feature {
    var title: String {
        switch self {
        case .tiling: "Fita de janelas"
        case .border: "Borda da janela focada"
        case .clipboard: "Histórico do clipboard"
        case .wallpaper: "Papel de parede do NiriOS"
        }
    }

    var detail: String {
        switch self {
        case .tiling: "As janelas em colunas lado a lado, com os workspaces e os atalhos de foco, largura e mesa. Mudar reinicia o NiriOS; desligada, as janelas voltam pra tela em cascata."
        case .border: "Contorno na janela com o teclado e no vidro do resize. Precisa da fita."
        case .clipboard: "O atalho mostra o que foi copiado. Desligado, o atalho volta pro app e o histórico fica guardado."
        case .wallpaper: "Imagem com efeito ou vídeo. Desligado, volta o papel de parede do macOS e o arquivo fica guardado."
        }
    }
}

extension WallpaperEffect {
    /// Os nomes do Kinggie.
    var title: String {
        switch self {
        case .none: "Nenhum"
        case .dither: "Dither"
        case .halftone: "Meio-tom"
        case .scanlines: "Scanlines"
        case .ascii: "ASCII"
        }
    }
}

// MARK: - SwiftUI

/// Uma aba. Problema no config (JSON inválido, atalho repetido) aparece embaixo, em qualquer aba.
private struct Page<Content: View>: View {
    let model: SettingsModel
    let content: Content

    var body: some View {
        content
            .formStyle(.grouped)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                let problems = (model.saveError.map { [$0] } ?? []) + model.warnings
                if !problems.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill") }
                    }
                    .font(.callout).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(.bar)
                }
            }
    }
}

/// Um botão por recurso. Desligado, ele não existe no niri-os: não gasta memória nem CPU.
private struct FeaturesTab: View {
    let panel: PanelController

    var body: some View {
        Form {
            Section {
                ForEach(Feature.allCases, id: \.self) { f in
                    Toggle(isOn: Binding(get: { panel.model.has(f) }, set: { panel.setFeature(f, on: $0) })) {
                        Text(f.title)
                        Text(f.detail)
                    }
                    .accessibilityLabel(f.title)  // sem isso o botão não tem nome (o texto fica num elemento ao lado)
                    .disabled(f.requires.map { !panel.model.has($0) } ?? false)  // a borda sem a fita
                }
            } footer: {
                Text("Desligado não roda nada nem gasta memória.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ShortcutsTab: View {
    let panel: PanelController

    var body: some View {
        Form {
            Section { ForEach(Action.allCases, id: \.self) { ShortcutRow(panel: panel, action: $0) } }
        }
    }
}

/// A lista na ordem em que ficam lado a lado (arrastar muda), e o escolhido à direita.
private struct WorkspacesTab: View {
    let panel: PanelController

    var body: some View {
        let model = panel.model
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: Binding(get: { model.selected }, set: { model.selected = $0 })) {
                    ForEach(model.workspaces, id: \.name) { w in
                        HStack(spacing: 4) {
                            Text(w.name).fontWeight(.medium).lineLimit(1)
                            Spacer()
                            ForEach(w.apps.prefix(3), id: \.self) { AppIcon(app: panel.app($0), size: 16) }
                        }
                        .listRowSeparator(.hidden)
                    }
                    .onMove { panel.moveWorkspaces($0, to: $1) }
                }
                Divider()
                HStack(spacing: 0) {
                    Button { panel.addWorkspace() } label: { Image(systemName: "plus").frame(width: 28, height: 24) }
                        .help("Novo workspace")
                    Divider().frame(height: 14)
                    Button { model.selected.map(panel.removeWorkspace) } label: { Image(systemName: "minus").frame(width: 28, height: 24) }
                        .disabled(model.workspaces.count < 2)
                        .help("Apagar: as janelas dele vão pro workspace da tela")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 4)
            }
            .frame(width: 180)
            Divider()
            if let name = model.selected, model.index(name) != nil {
                WorkspaceDetail(panel: panel, name: name).id(name)
            } else {
                Spacer()
            }
        }
        .disabledFeature(.tiling, model)
    }
}

private struct WorkspaceDetail: View {
    let panel: PanelController
    let name: String
    /// O nome só vale ao apertar Enter ou sair do campo: cada letra seria um workspace novo no niri-os.
    @State private var draft: String
    @FocusState private var editing: Bool

    init(panel: PanelController, name: String) {
        self.panel = panel
        self.name = name
        _draft = State(initialValue: name)
    }

    var body: some View {
        let w = panel.model.workspaces.first { $0.name == name } ?? WorkspaceRule(name: name)
        let openable = w.apps.map(panel.app).filter { $0.url != nil }.map(\.name)
        Form {
            Section {
                TextField("Nome", text: $draft)
                    .focused($editing)
                    .onSubmit(commit)
                    .onChange(of: editing) { if !editing { commit() } }
            }
            Section("Atalhos") {
                ShortcutRow(panel: panel, action: .workspace(name))
                ShortcutRow(panel: panel, action: .moveToWorkspace(name))
            }
            Section("Apps que abrem aqui") {
                ForEach(w.apps, id: \.self) { rule in
                    let app = panel.app(rule)
                    HStack {
                        AppIcon(app: app, size: 20)
                        Text(app.name)
                        Spacer()
                        Button { panel.removeApp(rule, from: name) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.tertiary).help("Tirar")
                    }
                }
                Menu {
                    // Escolher tira de onde estava: o menu mostra de onde.
                    ForEach(panel.runningApps(for: w), id: \.name) { r in
                        Button { panel.addApp(bundleID: r.bundleID, name: r.name, to: name) } label: {
                            Label { Text(r.ref.name + (r.current.map { " (no \($0))" } ?? "")) } icon: { Image(nsImage: r.ref.icon) }
                        }
                    }
                    Divider()
                    Button("Outro…") { panel.chooseApp(for: name) }
                } label: {
                    Label("Adicionar app", systemImage: "plus")
                }
                .menuStyle(.button).buttonStyle(.borderless).fixedSize()
                if !openable.isEmpty || w.open != nil {
                    Picker("Abrir quando vazio", selection: Binding(get: { w.open }, set: { panel.setOpen($0, for: name) })) {
                        Text("Nenhum").tag(String?.none)
                        ForEach(openable + (w.open.map { openable.contains($0) ? [] : [$0] } ?? []), id: \.self) {
                            Text($0).tag(String?.some($0))
                        }
                    }
                }
            }
        }
    }

    private func commit() {
        guard draft != name, panel.model.index(name) != nil else { return }  // já renomeado
        if !panel.renameWorkspace(name, to: draft) {
            NSSound.beep()  // vazio ou repetido
            draft = name
        }
    }
}

private struct WallpaperTab: View {
    let panel: PanelController

    var body: some View {
        let model = panel.model
        Form {
            Section {
                WallpaperPreview(image: model.preview, cropped: model.cropped, box: model.previewBox)
            }
            Section {
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
                if !model.isVideo {
                    Picker("Efeito", selection: Binding(get: { model.effect }, set: { model.effect = $0; panel.wallpaperChanged() })) {
                        ForEach(WallpaperEffect.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .disabled(model.wallpaper == nil)
                }
            } footer: {
                if model.isVideo { Text("O vídeo toca só com a mesa à mostra.").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .disabledFeature(.wallpaper, model)
    }
}

/// A borda da janela focada, que também contorna o vidro do resize.
private struct BorderTab: View {
    let panel: PanelController

    var body: some View {
        let model = panel.model
        Form {
            Section {
                GlassPreview(color: model.accent ? nil : model.color, width: model.has(.border) ? model.width : 0)
                    .frame(height: 170)
                    .clipShape(.rect(cornerRadius: 8))
            }
            Section {
                Toggle("Cor de destaque do sistema", isOn: panel.bind(\.accent))
                if !model.accent {
                    ColorPicker("Cor", selection: Binding(get: { Color(nsColor: model.color) },
                                                          set: { model.color = NSColor($0); panel.scheduleSave() }))
                }
                LabeledContent("Espessura") {
                    HStack {
                        Slider(value: panel.bind(\.width), in: 0...8, step: 0.5).frame(width: 180)
                        Text(String(format: "%.1f pt", model.width)).monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                }
            } footer: {
                Text("Em volta da janela focada e do vidro do resize, com o canto de cada app. 0 tira a borda.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabledFeature(.border, model)
    }
}

extension View {
    /// A aba de um recurso desligado fica cinza, com o aviso em cima.
    func disabledFeature(_ f: Feature, _ model: SettingsModel) -> some View {
        disabled(!model.has(f)).safeAreaInset(edge: .top, spacing: 0) {
            if !model.has(f) {
                let off = f.requires.flatMap { model.has($0) ? nil : $0 } ?? f
                Label("\(off.title): desligado na aba Recursos.", systemImage: "power")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.top, 12)
            }
        }
    }
}

private struct GeneralTab: View {
    let panel: PanelController

    var body: some View {
        Form {
            Section {
                LabeledContent("Arquivo") {
                    Text(Config.path.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.callout.monospaced()).textSelection(.enabled)
                }
                HStack {
                    Button("Abrir no editor") { Settings.openFile() }
                    Button("Mostrar no Finder") { Settings.openFile(reveal: true) }
                    Spacer()
                    Button("Recarregar") { panel.send("reload") }
                }
            }
            Section {
                Toggle("Abrir ao iniciar o Mac", isOn: Binding(get: { panel.model.loginItem == .enabled },
                                                               set: { panel.setOpensAtLogin($0) }))
                    .accessibilityLabel("Abrir ao iniciar o Mac")  // sem isso a chave fica sem nome, como as dos recursos
                if panel.model.loginItem == .requiresApproval {
                    HStack {
                        Text("Falta ligar o NiriOS nos Ajustes do Sistema, em Itens de início.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Abrir os Ajustes") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
            }
            .disabled(!AppBundle.isApp)
            Section {
                LabeledContent("Versão", value: AppBundle.version ?? "desenvolvimento (.build)")
                HStack {
                    Button("Procurar atualização") { panel.send("update") }.disabled(AppBundle.version == nil)
                    Spacer()
                    Button("Mostrar o log") { NSWorkspace.shared.activateFileViewerSelecting([AppBundle.logURL]) }
                        .disabled(!AppBundle.isApp)  // rodando do .build, o log fica no terminal
                }
            } footer: {
                Text("O NiriOS procura atualização uma vez por dia e pergunta antes de instalar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Sair do NiriOS", role: .destructive) { panel.send("quit") }
            }
        }
    }
}

private struct ShortcutRow: View {
    let panel: PanelController
    let action: Action

    var body: some View {
        let model = panel.model
        let keys = model.shortcuts[action] ?? [], defaults = Config.defaults(for: action)
        let recording = model.recording == action
        LabeledContent(action.title) {
            HStack(spacing: 6) {
                if keys.isEmpty && !recording { Text("Desligado").foregroundStyle(.tertiary) }
                ForEach(keys, id: \.self) { k in KeyCap(text: k.display) { panel.remove(k, from: action) } }
                if recording {
                    KeyCap(text: !model.heldModifiers.isEmpty ? "\(model.heldModifiers) …"
                           : model.needsModifier ? "Use ⌃, ⌥ ou ⌘" : "Aperte o atalho…", active: true)
                }
                Button { panel.record(recording ? nil : action) } label: {
                    Image(systemName: recording ? "xmark.circle.fill" : "plus.circle.fill")
                }
                .buttonStyle(.borderless)
                .help(recording ? "Cancelar" : "Gravar um atalho novo")
                if keys != defaults {
                    Button { panel.reset(action) } label: { Image(systemName: "arrow.uturn.backward.circle") }
                        .buttonStyle(.borderless)
                        .help("Voltar ao padrão" + (defaults.isEmpty ? " (desligado)" : ": " + defaults.map(\.display).joined(separator: ", ")))
                }
            }
            .foregroundStyle(.secondary)
        }
        .disabled(!model.has(action == .clipboard ? .clipboard : .tiling))
        .onDisappear { if recording { panel.record(nil) } }  // trocou de aba ou de workspace gravando
    }
}

private struct AppIcon: View {
    let app: AppRef
    let size: CGFloat

    var body: some View {
        Image(nsImage: app.icon).resizable().interpolation(.high).frame(width: size, height: size).help(app.name)
    }
}

/// Uma tecla desenhada. Com o mouse em cima, aparece o x pra remover (no canto, sem empurrar as outras).
struct KeyCap: View {
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

/// O vidro de verdade (o mesmo do resize, com a borda da janela focada) sobre o papel de parede da tela.
private struct GlassPreview: NSViewRepresentable {
    let color: NSColor?
    let width: Double

    final class Backdrop: NSView {
        let glass: Glass

        init() {
            let icon = NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
            glass = Glass(CGRect(x: 0, y: 0, width: 200, height: 120), icon: icon, iconSize: 56, radius: 16, border: (nil, 3))
            glass.effect.blendingMode = .withinWindow  // desfoca o papel de parede desta janela, não a tela atrás
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
            glass.windowFrame = bounds.insetBy(dx: bounds.width * 0.2, dy: 24)
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
        v.glass.border = (color, width)
    }
}
