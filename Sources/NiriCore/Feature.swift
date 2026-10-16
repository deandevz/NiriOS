/// O que dá pra desligar, pela aba Recursos do painel ou por `"features": { "border": false }` no config. Desligado não
/// é criado (sem janela, sem aviso do sistema, sem memória), e o atalho dele passa pro app.
public enum Feature: String, CaseIterable, Sendable {
    /// A fita de janelas, com os workspaces. Ligar ou desligar reinicia o niri-os (ver `Settings.restart`).
    case tiling
    case border, clipboard, wallpaper

    /// O recurso que precisa estar ligado junto. A borda segue a janela focada que a fita informa, e sem a fita teria que
    /// descobrir o foco lendo os apps pela Acessibilidade.
    public var requires: Feature? { self == .border ? .tiling : nil }

    /// Ligado, com esses desligados.
    public func isOn(_ disabled: Set<Feature>) -> Bool {
        !disabled.contains(self) && requires.map { $0.isOn(disabled) } != false
    }
}
