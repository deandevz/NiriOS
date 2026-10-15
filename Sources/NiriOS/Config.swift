import Foundation
import NiriCore

/// Lido de ~/.config/niri-os/config.json. Toda chave é opcional; o que faltar usa o padrão.
///
///     { "gap": 12, "topPadding": 0, "defaultColumnWidth": 0.5, "widthStep": 0.1, "stiffness": 800 }
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
    /// Rigidez da mola. Maior = animação mais rápida. 800 é o padrão do niri.
    var stiffness: Double = 800
    /// Tempo máximo esperando um app responder uma chamada de Acessibilidade (s).
    var axTimeout: Double = 0.2
    /// "always" (janela focada sempre no centro), "never" (rola o mínimo) ou "on-overflow".
    var centerFocusedColumn: CenterMode = .always

    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/niri-os/config.json")

    static func load() -> Config {
        var c = Config()
        guard let data = try? Data(contentsOf: path) else { return c }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            log("config inválida em \(path.path), usando padrões")
            return c
        }
        func num(_ key: String) -> Double? { (obj[key] as? NSNumber)?.doubleValue }
        if let v = num("gap") { c.gap = v }
        if let v = num("topPadding") { c.topPadding = v }
        if let v = num("bottomPadding") { c.bottomPadding = v }
        if let v = num("defaultColumnWidth") { c.defaultColumnWidth = v }
        if let v = num("widthStep") { c.widthStep = v }
        if let v = num("stiffness") { c.stiffness = v }
        if let v = num("axTimeout") { c.axTimeout = v }
        if let s = obj["centerFocusedColumn"] as? String {
            if let m = CenterMode(rawValue: s) { c.centerFocusedColumn = m } else { log("config: centerFocusedColumn '\(s)' inválido") }
        }
        let known: Set = ["gap", "topPadding", "bottomPadding", "defaultColumnWidth", "widthStep", "stiffness", "axTimeout",
                          "centerFocusedColumn"]
        for key in obj.keys where !known.contains(key) { log("config: chave desconhecida '\(key)'") }
        log("config carregada de \(path.path)")
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
