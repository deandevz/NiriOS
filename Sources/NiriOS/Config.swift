import AppKit
import NiriCore

/// Lido de ~/.config/niri-os/config.json. Toda chave é opcional; o que faltar usa o padrão.
/// Salvar o arquivo recarrega na hora (ver `Settings`).
///
///     { "gap": 12, "topPadding": 0, "defaultColumnWidth": 0.5, "widthStep": 0.1, "stiffness": 800,
///       "shortcuts": { "grow": ["option+=", "ctrl+option+up"] }, "borderColor": "#FF8800",
///       "workspaces": ["1", "2", { "name": "T", "apps": ["WezTerm"] }],
///       "tiling": ["Steam", "com.adobe.PremierePro*"], "floating": ["Calculadora"] }
enum ResizeStyle: String { case photos, ghost, live }

/// Regra de app: o nome como no Dock ou o bundle id, sem diferença de maiúscula. Terminando em * vale como começo do nome
/// ("Adobe Premiere*" pega todas as versões).
func appMatches(_ rules: [String], name: String, bundleID: String?) -> Bool {
    rules.contains { rule in
        [name, bundleID].compactMap { $0 }.contains {
            rule.hasSuffix("*") ? $0.lowercased().hasPrefix(rule.dropLast().lowercased()) : $0.caseInsensitiveCompare(rule) == .orderedSame
        }
    }
}

/// Onde as janelas novas de um app vão por regra do config (`tiling` e `floating`).
enum WindowRule { case tile, float }

/// Um workspace do config. Os atalhos dele ficam em `Config.shortcuts`, como `.workspace(name)` e
/// `.moveToWorkspace(name)`.
struct WorkspaceRule: Equatable {
    var name: String
    /// Apps cujas janelas novas abrem aqui (ver `appMatches`).
    var apps: [String] = []
    /// App aberto (`open -a`) quando o atalho traz pra cá e não tem janela, como o
    /// `alt-t = ['workspace T', 'exec-and-forget open -a WezTerm']` do AeroSpace.
    var open: String?

    func matches(app name: String, bundleID: String?) -> Bool { appMatches(apps, name: name, bundleID: bundleID) }
}

struct Config {
    /// Espaço entre janelas e entre janela e borda da tela (pt).
    var gap: Double = 12
    /// Espaço extra no topo e embaixo, além da barra de menu e do Dock (ex.: SketchyBar).
    var topPadding: Double = 0
    var bottomPadding: Double = 0
    /// Largura de janela nova, como fração da área útil.
    var defaultColumnWidth: Double = 0.5
    /// Quanto Option+ e Option- mudam a largura, como fração da área útil.
    var widthStep: Double = 0.1
    /// Larguras do Option+/- (como no niri). Lista vazia = passo de `widthStep`. Passos maiores são
    /// menos transições, e cada uma é onde um app pode mostrar defeito.
    var widthPresets: [Double] = [1.0 / 3, 0.5, 2.0 / 3, 1]
    /// Alturas do Option+Cmd+/- numa coluna com mais de uma janela, como fração da altura da coluna.
    var heightPresets: [Double] = [1.0 / 3, 0.5, 2.0 / 3]
    /// Como o Option+/- anima. "ghost": vidro fosco no lugar da janela, que volta pronta no fim (ver
    /// GhostOverlay). "photos": fotos das janelas (ver TransitionOverlay; precisa de Gravação de Tela).
    /// "live": as janelas reais, frame a frame.
    var resizeStyle: ResizeStyle = .ghost
    /// Rigidez da mola. Maior = animação mais rápida. 800 é o padrão do niri.
    var stiffness: Double = 800
    /// Tempo máximo esperando um app responder uma chamada de Acessibilidade (s).
    var axTimeout: Double = 0.2
    /// "always" (janela focada sempre no centro), "never" (rola o mínimo) ou "on-overflow".
    var centerFocusedColumn: CenterMode = .always
    /// Atalhos por ação. Uma ação no config troca a lista inteira dela; lista vazia desliga.
    var shortcuts = Config.defaultShortcuts
    /// Borda da janela focada (ver `FocusBorder`), também em volta do vidro do resize. nil = cor de destaque do
    /// sistema. Espessura em pt; 0 tira a borda.
    var borderColor: NSColor?
    var borderWidth: Double = 3
    /// Papel de parede (ver `WallpaperArt`): imagem, que vira o do macOS com `wallpaperEffect` aplicado, ou
    /// vídeo, que toca só com a mesa à mostra. nil = não mexe no do macOS (e devolve o de antes, se era nosso).
    var wallpaper: URL?
    var wallpaperEffect = WallpaperEffect.none
    /// Na ordem em que ficam lado a lado. Sem a chave no arquivo: 1 a 4.
    var workspaces: [WorkspaceRule] = []
    /// Apps que vão pra fita mesmo com a janela principal fora do padrão (o Premiere) ou sendo de um processo auxiliar (a
    /// do Steam é do Steam Helper), e apps cujas janelas abrem soltas. Só as janelas novas; diálogo continua de fora.
    var tiling: [String] = []
    var floating: [String] = []
    /// Comando (sh) rodado a cada troca de workspace e ao abrir, com o nome em NIRI_WORKSPACE. Pra SketchyBar:
    /// `sketchybar --trigger niri_workspace_change FOCUSED_WORKSPACE=$NIRI_WORKSPACE`.
    var onWorkspaceChange: String?
    /// Onde o ⌘S do print salva (ver `ScreenshotEditor`). nil = a pasta do print do macOS.
    var screenshotFolder: URL?
    /// Os recursos desligados (ver `Feature`): `"features": { "clipboard": false }`.
    var disabled: Set<Feature> = []
    /// O que estava errado no arquivo (aparece no log e no painel).
    var warnings: [String] = []
    /// O arquivo existe mas não é JSON válido (ver `Settings.reload`).
    var invalid = false

    /// Códigos de tecla são posicionais: valem pra US, US Internacional e ABNT2.
    /// Shift é aceito quando não tem atalho próprio (Option+Shift+= é o Option+=).
    /// Option+setas também: no terminal e no editor elas deixam de pular palavra.
    /// Mover coluna é o foco com Shift. Shift+seta sozinho não dá: é selecionar texto em todo app.
    /// Empilhar janelas é com Cmd: só Cmd+= e Cmd+- seria o zoom de todo app, e Option+Cmd+← → troca de aba no navegador.
    static let defaultShortcuts: [Action: [Shortcut]] = [
        .grow: ["option+=", "option+keypadplus"], .shrink: ["option+-", "option+keypadminus"],
        .growHeight: ["option+cmd+=", "option+cmd+keypadplus"], .shrinkHeight: ["option+cmd+-", "option+cmd+keypadminus"],
        .focusLeft: ["option+,", "option+left"], .focusRight: ["option+.", "option+right"],
        .focusUp: ["option+up"], .focusDown: ["option+down"],
        .moveColumnLeft: ["option+shift+,", "option+shift+left"], .moveColumnRight: ["option+shift+.", "option+shift+right"],
        .consumeOrExpelLeft: ["option+cmd+,"], .consumeOrExpelRight: ["option+cmd+."],
        .toggleFullWidth: ["option+f"], .toggleDesktop: ["option+d"], .clipboard: ["option+v"], .screenshot: ["option+s"],
        .toggleFloating: ["option+shift+f"], .switchWindows: ["option+tab"], .pinFloating: ["option+shift+p"],
    ].mapValues { $0.map { Shortcut($0)! } }

    /// O padrão de uma ação. Workspace: Option+<nome> pra ir e Option+Shift+<nome> pra mandar a janela, se o
    /// nome for uma tecla (um workspace "Web" fica sem).
    static func defaults(for a: Action) -> [Shortcut] {
        switch a {
        case .workspace(let n): Shortcut("option+" + n.lowercased()).map { [$0] } ?? []
        case .moveToWorkspace(let n): Shortcut("option+shift+" + n.lowercased()).map { [$0] } ?? []
        default: defaultShortcuts[a] ?? []
        }
    }

    /// `NIRI_CONFIG=<arquivo>` usa outro (pra testar uma config sem mexer na de uso).
    static let path = ProcessInfo.processInfo.environment["NIRI_CONFIG"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/niri-os/config.json")

    static func load() -> Config {
        var c = Config()
        func warn(_ m: String) {
            log("config: \(m)")
            c.warnings.append(m)
        }
        // Sem arquivo ou com JSON inválido, tudo segue com os padrões (inclusive os workspaces).
        var obj: [String: Any] = [:]
        let data = try? Data(contentsOf: path)
        if let data {
            if let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { obj = o }
            else {
                warn("o arquivo não é um JSON válido; usando os padrões")
                c.invalid = true
            }
        }
        func num(_ key: String) -> Double? { (obj[key] as? NSNumber)?.doubleValue }
        func text(_ v: Any?) -> String? { v as? String ?? (v as? NSNumber)?.stringValue }
        if let v = num("gap") { c.gap = v }
        if let v = num("topPadding") { c.topPadding = v }
        if let v = num("bottomPadding") { c.bottomPadding = v }
        if let v = num("defaultColumnWidth") { c.defaultColumnWidth = v }
        if let v = num("widthStep") { c.widthStep = v }
        if let v = obj["widthPresets"] as? [NSNumber] { c.widthPresets = v.map(\.doubleValue) }
        if let v = obj["heightPresets"] as? [NSNumber] {
            let p = v.map(\.doubleValue).filter { $0 > 0 && $0 < 1 }
            if p.isEmpty { warn("heightPresets precisa de frações entre 0 e 1; usando 1/3, 1/2 e 2/3") } else { c.heightPresets = p }
        }
        if let s = obj["resizeStyle"] as? String {
            if let m = ResizeStyle(rawValue: s) { c.resizeStyle = m } else { warn("resizeStyle '\(s)' inválido") }
        }
        if let v = num("stiffness") { c.stiffness = v }
        if let v = num("axTimeout") { c.axTimeout = v }
        if let s = obj["centerFocusedColumn"] as? String {
            if let m = CenterMode(rawValue: s) { c.centerFocusedColumn = m } else { warn("centerFocusedColumn '\(s)' inválido") }
        }
        for (name, list) in obj["shortcuts"] as? [String: Any] ?? [:] {
            guard let action = Action(rawValue: name) else { warn("ação desconhecida em shortcuts: '\(name)'"); continue }
            c.shortcuts[action] = (list as? [String] ?? []).compactMap {
                if let k = Shortcut($0) { return k }
                warn("atalho inválido em \(name): '\($0)'")
                return nil
            }
        }
        // Workspaces: nome sozinho ou {name, apps, open, key, moveKey}. Sem key/moveKey, o padrão; "" ou [] desliga.
        for item in obj["workspaces"] as? [Any] ?? ["1", "2", "3", "4"] {
            let o = item as? [String: Any] ?? [:]
            guard let name = text(item) ?? text(o["name"]), !name.isEmpty else { warn("workspace sem nome"); continue }
            guard !c.workspaces.contains(where: { $0.name == name }) else { warn("workspace '\(name)' repetido"); continue }
            c.workspaces.append(WorkspaceRule(name: name, apps: o["apps"] as? [String] ?? [], open: text(o["open"])))
            for (field, action) in [("key", Action.workspace(name)), ("moveKey", .moveToWorkspace(name))] {
                guard let v = o[field] else { c.shortcuts[action] = defaults(for: action); continue }
                c.shortcuts[action] = ((v as? String).map { [$0] } ?? v as? [String] ?? []).filter { !$0.isEmpty }.compactMap {
                    if let k = Shortcut($0) { return k }
                    warn("atalho inválido em \(field) do workspace \(name): '\($0)'")
                    return nil
                }
            }
        }
        if c.workspaces.isEmpty { c.workspaces = [WorkspaceRule(name: "1")] }  // "workspaces": [] = um só, sem atalho
        c.onWorkspaceChange = (obj["onWorkspaceChange"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        for key in ["tiling", "floating"] where obj[key] != nil && !(obj[key] is [String]) {
            warn("\(key) precisa ser uma lista de apps, como [\"Steam\"]")
        }
        c.tiling = obj["tiling"] as? [String] ?? []
        let floating = obj["floating"] as? [String] ?? []
        for r in floating where c.tiling.contains(r) { warn("'\(r)' está em tiling e em floating; vale tiling") }
        c.floating = floating.filter { !c.tiling.contains($0) }
        // O mesmo atalho em duas ações: vale a primeira, na ordem do painel (os workspaces por último).
        var seen: [Shortcut: Action] = [:]
        for a in Action.allCases + c.workspaces.flatMap({ [Action.workspace($0.name), .moveToWorkspace($0.name)] }) {
            c.shortcuts[a] = c.shortcuts[a, default: []].filter { k in
                if let other = seen[k] { warn("\(k) está em \(other.rawValue) e \(a.rawValue); vale \(other.rawValue)"); return false }
                seen[k] = a
                return true
            }
        }
        // Antes de 2026-10-16 a borda era só do vidro do resize, com `ghostBorder*`: vale se a chave nova não está lá.
        if let s = (obj["borderColor"] ?? obj["ghostBorderColor"]) as? String, s != "accent" {
            if let color = NSColor(hex: s) { c.borderColor = color } else { warn("borderColor '\(s)' inválida (use #RRGGBB, #RRGGBBAA ou accent)") }
        }
        if let v = num("borderWidth") ?? num("ghostBorderWidth") { c.borderWidth = max(0, v) }
        if let s = obj["wallpaper"] as? String, !s.isEmpty {
            // Arquivo que sumiu (disco externo, por exemplo) fica no config: o processo avisa e não mexe em nada.
            let url = URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
            if !FileManager.default.fileExists(atPath: url.path) { warn("wallpaper: arquivo não encontrado: \(s)") }
            c.wallpaper = url
        }
        if let s = obj["wallpaperEffect"] as? String {
            if let e = WallpaperEffect(rawValue: s) { c.wallpaperEffect = e } else { warn("wallpaperEffect '\(s)' inválido (use none, dither, halftone, scanlines ou ascii)") }
        }
        if let w = c.wallpaper, WallpaperArt.isVideo(w), c.wallpaperEffect != .none {
            warn("wallpaperEffect vale só pra imagem; o vídeo toca sem efeito")
            c.wallpaperEffect = .none
        }
        if let s = obj["screenshotFolder"] as? String, !s.isEmpty {
            c.screenshotFolder = URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
        }
        for (name, on) in obj["features"] as? [String: Any] ?? [:] {
            guard let f = Feature(rawValue: name) else { warn("recurso desconhecido em features: '\(name)'"); continue }
            guard let on = on as? Bool else { warn("features.\(name) precisa ser true ou false"); continue }
            if !on { c.disabled.insert(f) }
        }
        let known: Set = ["gap", "topPadding", "bottomPadding", "defaultColumnWidth", "widthStep", "widthPresets", "heightPresets", "resizeStyle", "stiffness", "axTimeout",
                          "centerFocusedColumn", "shortcuts", "borderColor", "borderWidth", "ghostBorderColor", "ghostBorderWidth", "wallpaper", "wallpaperEffect", "workspaces", "onWorkspaceChange",
                          "screenshotFolder", "features", "tiling", "floating"]
        for key in obj.keys where !known.contains(key) { warn("chave desconhecida '\(key)'") }
        if data != nil { log("config carregada de \(path.path)") }
        return c
    }

    /// Grava as chaves dadas e mantém as outras como estão (nil apaga a chave). Não grava se o arquivo
    /// atual não é JSON válido: perderia o que a pessoa escreveu à mão.
    static func save(_ changes: [String: Any?]) -> Bool {
        var obj: [String: Any] = [:]
        if let data = try? Data(contentsOf: path) {
            guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
            obj = o
        }
        for (k, v) in changes { obj[k] = v }
        guard let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return false }
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? out.write(to: path.resolvingSymlinksInPath(), options: .atomic)) != nil
    }

    func has(_ f: Feature) -> Bool { f.isOn(disabled) }

    func windowRule(app name: String, bundleID: String?) -> WindowRule? {
        appMatches(tiling, name: name, bundleID: bundleID) ? .tile : appMatches(floating, name: name, bundleID: bundleID) ? .float : nil
    }

    /// A pasta do print: a do config, ou a do print do macOS (`defaults write com.apple.screencapture location`), ou a Mesa.
    var screenshots: URL {
        screenshotFolder ?? URL(fileURLWithPath: ((UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
            ?? "~/Desktop") as NSString).expandingTildeInPath)
    }

    /// O que o niri-os usa: sem a borda (nem no vidro do resize), o papel de parede e o atalho de recurso desligado. O
    /// painel fica com o config inteiro, pra religar voltar como estava.
    var active: Config {
        var c = self
        c.shortcuts = c.shortcuts.filter { has($0.key.feature) }
        if !has(.border) { c.borderWidth = 0 }
        if !has(.wallpaper) { (c.wallpaper, c.wallpaperEffect) = (nil, .none) }  // o processo devolve o do macOS
        return c
    }

    var layout: LayoutConfig {
        var l = LayoutConfig()
        l.gap = gap
        l.defaultProportion = defaultColumnWidth
        l.stiffness = stiffness
        l.centerFocusedColumn = centerFocusedColumn
        return l
    }
}

extension NSColor {
    /// "#RRGGBB" ou "#RRGGBBAA", em sRGB.
    convenience init?(hex: String) {
        let h = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard h.count == 6 || h.count == 8, let v = UInt64(h, radix: 16) else { return nil }
        let rgba = h.count == 6 ? v << 8 | 0xFF : v
        func c(_ shift: UInt64) -> Double { Double(rgba >> shift & 0xFF) / 255 }
        self.init(srgbRed: c(24), green: c(16), blue: c(8), alpha: c(0))
    }

    var hex: String {
        let c = usingColorSpace(.sRGB) ?? self
        let parts = [c.redComponent, c.greenComponent, c.blueComponent] + (c.alphaComponent < 1 ? [c.alphaComponent] : [])
        return "#" + parts.map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
    }
}
