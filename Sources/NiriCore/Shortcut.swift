import Carbon.HIToolbox
import CoreGraphics

/// Uma combinação de teclas, como no config.json: `"option+="`, `"ctrl+option+left"`, `"cmd+shift+f"`.
/// A tecla é pelo código, que é posicional: `option+=` é a mesma tecla em US, US Internacional e ABNT2.
public struct Shortcut: Hashable, CustomStringConvertible {
    public let key: Int64
    public let mods: CGEventFlags

    /// Os modificadores que contam; Caps Lock, Fn e teclado numérico (que vêm junto das setas) não.
    public static let modifierMask: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
    /// Na ordem da Apple (⌃⌥⇧⌘). Os nomes depois do primeiro também valem na leitura.
    private static let modifierNames: [(flag: CGEventFlags, names: [String], symbol: String)] = [
        (.maskControl, ["ctrl", "control"], "⌃"), (.maskAlternate, ["option", "alt", "opt"], "⌥"),
        (.maskShift, ["shift"], "⇧"), (.maskCommand, ["cmd", "command"], "⌘"),
    ]
    /// Códigos 0 a 50 do teclado ANSI, na ordem (kVK_ANSI_A = 0 ... kVK_ANSI_Grave = 50). "" é a tecla ISO § (10).
    private static let ansi = ["a", "s", "d", "f", "h", "g", "z", "x", "c", "v", "", "b", "q", "w", "e", "r", "y", "t",
                               "1", "2", "3", "4", "6", "5", "=", "9", "7", "-", "8", "0", "]", "o", "u", "[", "i", "p",
                               "return", "l", "j", "'", "k", ";", "\\", ",", "/", "n", "m", ".", "tab", "space", "`"]
    private static let named: [String: Int] = [
        "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow,
        "escape": kVK_Escape, "delete": kVK_Delete, "forwarddelete": kVK_ForwardDelete,
        "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
        "keypadplus": kVK_ANSI_KeypadPlus, "keypadminus": kVK_ANSI_KeypadMinus,
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6, "f7": kVK_F7,
        "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
    ]
    private static let symbols = ["left": "←", "right": "→", "up": "↑", "down": "↓", "return": "↩", "tab": "⇥",
                                  "space": "Espaço", "escape": "Esc", "delete": "⌫", "forwarddelete": "⌦",
                                  "pageup": "⇞", "pagedown": "⇟", "keypadplus": "+ (num.)", "keypadminus": "− (num.)"]

    public init(key: Int64, mods: CGEventFlags) {
        self.key = key
        self.mods = mods.intersection(Self.modifierMask)
    }

    /// `nil` se algum pedaço não é modificador ou tecla conhecida. Tecla sem nome: `key<código>`.
    public init?(_ text: String) {
        var parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // "option++" não tem como dividir; o + do teclado numérico se chama keypadplus.
        guard let last = parts.popLast(), let key = Self.code(last) else { return nil }
        var mods: CGEventFlags = []
        for p in parts {
            guard let m = Self.modifierNames.first(where: { $0.names.contains(p) }) else { return nil }
            mods.insert(m.flag)
        }
        self.init(key: Int64(key), mods: mods)
    }

    private static func code(_ name: String) -> Int? {
        if let i = ansi.firstIndex(of: name), !name.isEmpty { return i }
        if let k = named[name] { return k }
        return name.hasPrefix("key") ? Int(name.dropFirst(3)) : nil
    }

    private var keyName: String {
        if key >= 0, key < Self.ansi.count, !Self.ansi[Int(key)].isEmpty { return Self.ansi[Int(key)] }
        return Self.named.first { Int64($0.value) == key }?.key ?? "key\(key)"
    }

    /// Como vai no config.json.
    public var description: String {
        (Self.modifierNames.filter { mods.contains($0.flag) }.map(\.names[0]) + [keyName]).joined(separator: "+")
    }

    /// Como aparece no painel: `⌥ =`, `⌃⌥ ←`.
    public var display: String {
        let m = Self.display(mods), k = Self.symbols[keyName] ?? keyName.uppercased()
        return m.isEmpty ? k : "\(m) \(k)"
    }

    /// Só os modificadores: `⌃⌥`.
    public static func display(_ mods: CGEventFlags) -> String {
        modifierNames.filter { mods.contains($0.flag) }.map(\.symbol).joined()
    }

    public func hash(into h: inout Hasher) {
        h.combine(key)
        h.combine(mods.rawValue)
    }
}
