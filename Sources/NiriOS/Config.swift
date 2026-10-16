import AppKit
import NiriCore

/// Lido de ~/.config/niri-os/config.json. Toda chave é opcional; o que faltar usa o padrão.
/// Salvar o arquivo recarrega na hora (ver `Settings`).
///
///     { "gap": 12, "topPadding": 0, "defaultColumnWidth": 0.5, "widthStep": 0.1, "stiffness": 800,
///       "shortcuts": { "grow": ["option+=", "ctrl+option+up"] }, "ghostBorderColor": "#FF8800",
///       "workspaces": ["1", "2", { "name": "T", "apps": ["WezTerm"] }] }
enum ResizeStyle: String { case photos, ghost, live }

/// Um workspace do config. Os atalhos dele ficam em `Config.shortcuts`, como `.workspace(name)` e
/// `.moveToWorkspace(name)`.
struct WorkspaceRule: Equatable {
    var name: String
    /// Apps cujas janelas novas abrem aqui: o nome como no Dock ou o bundle id, sem diferença de maiúscula.
    /// Terminando em * vale como começo do nome ("Adobe Premiere*" pega todas as versões).
    var apps: [String] = []
    /// App aberto (`open -a`) quando o atalho traz pra cá e não tem janela, como o
    /// `alt-t = ['workspace T', 'exec-and-forget open -a WezTerm']` do AeroSpace.
    var open: String?

    func matches(app name: String, bundleID: String?) -> Bool {
        apps.contains { rule in
            [name, bundleID].compactMap { $0 }.contains {
                rule.hasSuffix("*") ? $0.lowercased().hasPrefix(rule.dropLast().lowercased()) : $0.caseInsensitiveCompare(rule) == .orderedSame
            }
        }
    }
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
    /// Borda do vidro do resize fantasma. nil = cor de destaque do sistema.
    var ghostBorderColor: NSColor?
    var ghostBorderWidth: Double = 3
    /// Papel de parede (ver `WallpaperArt`): imagem, que vira o do macOS com `wallpaperEffect` aplicado, ou
    /// vídeo, que toca só com a mesa à mostra. nil = não mexe no do macOS (e devolve o de antes, se era nosso).
    var wallpaper: URL?
    var wallpaperEffect = WallpaperEffect.none
    /// Na ordem em que ficam lado a lado. Sem a chave no arquivo: 1 a 4.
    var workspaces: [WorkspaceRule] = []
    /// Comando (sh) rodado a cada troca de workspace e ao abrir, com o nome em NIRI_WORKSPACE. Pra SketchyBar:
    /// `sketchybar --trigger niri_workspace_change FOCUSED_WORKSPACE=$NIRI_WORKSPACE`.
    var onWorkspaceChange: String?
    /// O que estava errado no arquivo (aparece no log e no painel).
    var warnings: [String] = []

    /// Códigos de tecla são posicionais: valem pra US, US Internacional e ABNT2.
    /// Shift é aceito quando não tem atalho próprio, então Option+< e Option+> funcionam igual a Option+, e Option+.
    /// Option+setas também: no terminal e no editor elas deixam de pular palavra.
    static let defaultShortcuts: [Action: [Shortcut]] = [
        .grow: ["option+=", "option+keypadplus"], .shrink: ["option+-", "option+keypadminus"],
        .focusLeft: ["option+,", "option+left"], .focusRight: ["option+.", "option+right"],
        .toggleFullWidth: ["option+f"], .toggleDesktop: ["option+d"],
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
            else { warn("o arquivo não é um JSON válido; usando os padrões") }
        }
        func num(_ key: String) -> Double? { (obj[key] as? NSNumber)?.doubleValue }
        func text(_ v: Any?) -> String? { v as? String ?? (v as? NSNumber)?.stringValue }
        if let v = num("gap") { c.gap = v }
        if let v = num("topPadding") { c.topPadding = v }
        if let v = num("bottomPadding") { c.bottomPadding = v }
        if let v = num("defaultColumnWidth") { c.defaultColumnWidth = v }
        if let v = num("widthStep") { c.widthStep = v }
        if let v = obj["widthPresets"] as? [NSNumber] { c.widthPresets = v.map(\.doubleValue) }
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
        // O mesmo atalho em duas ações: vale a primeira, na ordem do painel (os workspaces por último).
        var seen: [Shortcut: Action] = [:]
        for a in Action.allCases + c.workspaces.flatMap({ [Action.workspace($0.name), .moveToWorkspace($0.name)] }) {
            c.shortcuts[a] = c.shortcuts[a, default: []].filter { k in
                if let other = seen[k] { warn("\(k) está em \(other.rawValue) e \(a.rawValue); vale \(other.rawValue)"); return false }
                seen[k] = a
                return true
            }
        }
        if let s = obj["ghostBorderColor"] as? String, s != "accent" {
            if let color = NSColor(hex: s) { c.ghostBorderColor = color } else { warn("ghostBorderColor '\(s)' inválida (use #RRGGBB, #RRGGBBAA ou accent)") }
        }
        if let v = num("ghostBorderWidth") { c.ghostBorderWidth = max(0, v) }
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
        let known: Set = ["gap", "topPadding", "bottomPadding", "defaultColumnWidth", "widthStep", "widthPresets", "resizeStyle", "stiffness", "axTimeout",
                          "centerFocusedColumn", "shortcuts", "ghostBorderColor", "ghostBorderWidth", "wallpaper", "wallpaperEffect", "workspaces", "onWorkspaceChange"]
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
