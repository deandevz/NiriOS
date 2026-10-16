import AppKit
import NiriCore

/// Lido de ~/.config/niri-os/config.json. Toda chave é opcional; o que faltar usa o padrão.
/// Salvar o arquivo recarrega na hora (ver `Settings`).
///
///     { "gap": 12, "topPadding": 0, "defaultColumnWidth": 0.5, "widthStep": 0.1, "stiffness": 800,
///       "shortcuts": { "grow": ["option+=", "ctrl+option+up"] }, "ghostBorderColor": "#FF8800" }
enum ResizeStyle: String { case photos, ghost, live }

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
    /// O que estava errado no arquivo (aparece no log e no painel).
    var warnings: [String] = []

    /// Códigos de tecla são posicionais: valem pra US, US Internacional e ABNT2.
    /// Shift é aceito quando não tem atalho próprio, então Option+< e Option+> funcionam igual a Option+, e Option+.
    /// Option+setas também: no terminal e no editor elas deixam de pular palavra.
    static let defaultShortcuts: [Action: [Shortcut]] = [
        .grow: ["option+=", "option+keypadplus"], .shrink: ["option+-", "option+keypadminus"],
        .focusLeft: ["option+,", "option+left"], .focusRight: ["option+.", "option+right"],
        .toggleFullWidth: ["option+f"],
    ].mapValues { $0.map { Shortcut($0)! } }

    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/niri-os/config.json")

    static func load() -> Config {
        var c = Config()
        func warn(_ m: String) {
            log("config: \(m)")
            c.warnings.append(m)
        }
        guard let data = try? Data(contentsOf: path) else { return c }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            warn("o arquivo não é um JSON válido; usando os padrões")
            return c
        }
        func num(_ key: String) -> Double? { (obj[key] as? NSNumber)?.doubleValue }
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
        // O mesmo atalho em duas ações: vale a primeira, na ordem do painel.
        var seen: [Shortcut: Action] = [:]
        for a in Action.allCases {
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
        let known: Set = ["gap", "topPadding", "bottomPadding", "defaultColumnWidth", "widthStep", "widthPresets", "resizeStyle", "stiffness", "axTimeout",
                          "centerFocusedColumn", "shortcuts", "ghostBorderColor", "ghostBorderWidth"]
        for key in obj.keys where !known.contains(key) { warn("chave desconhecida '\(key)'") }
        log("config carregada de \(path.path)")
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
