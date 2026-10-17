import AppKit
import NiriCore
import SwiftUI

/// A primeira abertura do NiriOS.app, sem config.json: as permissões, o que ligar (vem tudo desligado), os atalhos e
/// abrir ao iniciar. Sem a Acessibilidade (tirada nos Ajustes, ou o app assinado por outro certificado), só a página das
/// permissões.
///
/// Roda antes da fita, no próprio processo, e no fim grava o config e reabre (`AppBundle.relaunch`): os ~40 MB do
/// SwiftUI que não voltam (ver `Settings`) saem junto com o processo. Liberar a Gravação de Tela faz o macOS pedir pra
/// reabrir o app; a página guardada (`welcomePage`) faz o tour voltar de onde parou.
enum Welcome {
    static func run(tour: Bool) -> Never {
        let app = NSApplication.shared
        // No Dock e no Cmd+Tab: a pessoa vai nos Ajustes do Sistema liberar as permissões e precisa achar a volta.
        app.setActivationPolicy(.regular)
        let menu = NSMenu()
        menu.addItem(withTitle: "Sair do NiriOS", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.mainMenu = NSMenu()
        app.mainMenu!.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = menu
        let controller = WelcomeController(tour: tour)
        controller.show()
        app.activate()
        app.run()
        exit(0)
    }
}

final class WelcomeController: NSObject, NSWindowDelegate {
    enum Page { case hello, permissions, features, shortcuts, done }

    @Observable final class Model {
        var pages: [Page] = []
        var page = 0
        var accessibility = AXIsProcessTrusted()
        var screen = CGPreflightScreenCaptureAccess()
        /// O que liga ao terminar. O config novo vem com tudo desligado.
        var on: Set<Feature> = []
        var atLogin = true
        var rivals: [String] = []
    }

    let model = Model()
    private let tour: Bool
    private var window: NSWindow?
    private var timer: Timer?
    private var askedAccessibility = false, askedScreen = false

    init(tour: Bool) {
        self.tour = tour
        model.pages = tour ? [.hello, .permissions, .features, .shortcuts, .done] : [.permissions]
        model.page = min(UserDefaults.standard.integer(forKey: "welcomePage"), model.pages.count - 1)
        model.rivals = WindowManager.runningRivals()
    }

    func show() {
        let host = NSHostingController(rootView: WelcomeView(c: self))
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable]
        w.title = tour ? "Bem-vindo ao NiriOS" : "NiriOS"
        w.delegate = self
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        // As permissões não avisam quando mudam: só enquanto esta janela está aberta, antes da fita existir.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    private func refresh() {
        let ax = AXIsProcessTrusted()
        if ax && !model.accessibility {  // liberou nos Ajustes: a janela volta pra frente
            NSApp.activate()
            window?.makeKeyAndOrderFront(nil)
        }
        model.accessibility = ax
        model.screen = CGPreflightScreenCaptureAccess()
        model.rivals = WindowManager.runningRivals()
    }

    /// Na primeira vez, o pedido do macOS (que leva aos Ajustes); depois, os Ajustes direto.
    func askAccessibility() {
        if askedAccessibility { return openSettings("Privacy_Accessibility") }
        askedAccessibility = true
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    func askScreen() {
        if askedScreen { return openSettings("Privacy_ScreenCapture") }
        askedScreen = true
        if !CGRequestScreenCaptureAccess() && !model.screen { openSettings("Privacy_ScreenCapture") }
    }

    private func openSettings(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    func go(_ page: Int) {
        model.page = page
        UserDefaults.standard.set(page, forKey: "welcomePage")
    }

    /// Grava o que foi escolhido e reabre como o gerenciador. Sem a Acessibilidade não tem o que abrir: sai, e a próxima
    /// abertura volta pra cá.
    func finish() {
        timer?.invalidate()
        guard model.accessibility else { exit(0) }
        if tour {
            let off = Feature.allCases.filter { !model.on.contains($0) }
            if !Config.save(["features": Dictionary(uniqueKeysWithValues: off.map { ($0.rawValue, false) })]) {
                log("tour: não consegui gravar \(Config.path.path)")
            }
            if model.atLogin { AppBundle.setOpensAtLogin(true) }
        }
        UserDefaults.standard.removeObject(forKey: "welcomePage")
        log("tour: \(tour ? "terminado" : "permissões liberadas"), reabrindo")
        AppBundle.relaunch()
    }

    /// Fechar a janela com a Acessibilidade liberada é terminar com o que foi escolhido até ali (o resto desligado): o
    /// NiriOS fica na barra de menu, e as configurações têm tudo.
    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { self.finish() }
    }
}

private struct WelcomeView: View {
    let c: WelcomeController

    var body: some View {
        let m = c.model, page = m.pages[m.page], last = m.page == m.pages.count - 1
        VStack(spacing: 0) {
            Group {
                switch page {
                case .hello: HelloPage()
                case .permissions: PermissionsPage(c: c, tour: m.pages.count > 1)
                case .features: FeaturesPage(m: m)
                case .shortcuts: ShortcutsPage()
                case .done: DonePage(m: m)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 32).padding(.top, 28)
            Divider()
            HStack(spacing: 8) {
                if m.pages.count > 1 {
                    ForEach(m.pages.indices, id: \.self) { i in
                        Circle().fill(i == m.page ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if m.page > 0 { Button("Voltar") { c.go(m.page - 1) } }
                Button(last ? (m.pages.count > 1 ? "Começar" : "Continuar") : "Continuar") {
                    if last { c.finish() } else { c.go(m.page + 1) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(page == .permissions && !m.accessibility)
            }
            .padding(16)
        }
        .frame(width: 600, height: 460)
    }
}

private struct Title: View {
    let text: String
    var body: some View { Text(text).font(.system(size: 26, weight: .bold)).padding(.bottom, 4) }
}

/// A fita: colunas lado a lado, a focada no meio, as das pontas cortadas pela borda.
private struct Ribbon: View {
    private static let columns = [(70.0, false), (110.0, false), (190.0, true), (110.0, false), (70.0, false)]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Self.columns.indices, id: \.self) { i in
                let (w, focused) = Self.columns[i]
                RoundedRectangle(cornerRadius: 8)
                    .fill(focused ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.15))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? Color.accentColor : .clear, lineWidth: 2.5))
                    .frame(width: w, height: 110)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 130)
        .clipped()
    }
}

private struct HelloPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Ribbon().padding(.horizontal, -32).padding(.bottom, 8)
            Title(text: "Bem-vindo ao NiriOS")
            Text("As janelas ficam em colunas lado a lado, numa fita que rola pra esquerda e pra direita. Janela nova entra ao lado da que está com o foco, e nenhuma outra encolhe.")
            Text("Vem tudo desligado. Nas próximas telas você libera as permissões e escolhe o que ligar.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct PermissionsPage: View {
    let c: WelcomeController
    let tour: Bool

    var body: some View {
        let m = c.model
        VStack(alignment: .leading, spacing: 18) {
            Title(text: tour ? "Permissões" : "Falta uma permissão")
            Permission(icon: "accessibility", title: "Acessibilidade", required: true, ok: m.accessibility,
                       detail: "É como o NiriOS move as janelas e recebe os atalhos. Sem ela, ele não abre.",
                       action: c.askAccessibility)
            Permission(icon: "rectangle.dashed.badge.record", title: "Gravação de Tela", required: false, ok: m.screen,
                       detail: "Pro print do ⌥ S, pra saber quando o app terminou de redesenhar depois do resize e pra medir o canto das janelas pra borda. Nada é gravado nem sai do Mac.",
                       action: c.askScreen)
            Text("Depois de liberar a Gravação de Tela, o macOS pede pra reabrir o NiriOS: pode aceitar, ele volta nesta tela. Se o NiriOS já aparece ligado na lista e continua pedindo, tire ele com o botão − e libere de novo.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct Permission: View {
    let icon: String
    let title: String
    let required: Bool
    let ok: Bool
    let detail: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 22)).foregroundStyle(Color.accentColor).frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    Text(required ? "obrigatória" : "recomendada").font(.caption).foregroundStyle(.secondary)
                }
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if ok {
                Label("Liberada", systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
            } else {
                Button("Liberar…", action: action)
            }
        }
    }
}

private struct FeaturesPage: View {
    let m: WelcomeController.Model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Title(text: "O que ligar")
            feature(.tiling, "As janelas em colunas, com os workspaces e os atalhos. Ao começar, as janelas abertas entram na fita.")
            if m.on.contains(.tiling), !m.rivals.isEmpty {
                Label("Feche o \(m.rivals.joined(separator: " e o ")) antes: dois gerenciadores mexendo nas mesmas janelas brigam.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
            feature(.border, "Contorno na janela com o teclado. Precisa da fita.")
                .disabled(!m.on.contains(.tiling))
            feature(.clipboard, "⌥ V mostra os últimos 25 textos e imagens copiados. Fica só no seu Mac.")
            feature(.screenshot, "⌥ S congela a tela: escolha a área, desenhe, escreva ou pixele, e copie (⌘C) ou salve (⌘S). Precisa da Gravação de Tela.")
            Text("Dá pra mudar depois, na aba Recursos das configurações. O papel de parede também fica lá.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func feature(_ f: Feature, _ detail: String) -> some View {
        Toggle(isOn: Binding(get: { m.on.contains(f) }, set: { if $0 { m.on.insert(f) } else { m.on.remove(f) } })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(f.title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)  // as chaves alinhadas na direita
        }
        .toggleStyle(.switch)
        .accessibilityLabel(f.title)
    }
}

private struct ShortcutsPage: View {
    /// O atalho padrão como aparece no painel; nas ações com seta, a seta.
    private func keys(_ a: Action) -> String {
        let d = Config.defaults(for: a)
        return (d.first { $0.display.contains("←") || $0.display.contains("→") } ?? d.first)?.display ?? ""
    }

    var body: some View {
        let rows: [(keys: [Action], between: String, text: String)] = [
            ([.focusLeft, .focusRight], "/", "foco na coluna da esquerda / da direita"),
            ([.moveColumnLeft, .moveColumnRight], "/", "troca a coluna de lugar com a vizinha"),
            ([.grow, .shrink], "/", "largura da coluna: 1/3, 1/2, 2/3 e a tela toda"),
            ([.toggleFullWidth], "", "largura total; de novo, volta"),
            ([.toggleDesktop], "", "mostra a mesa; de novo, as janelas voltam"),
            ([.workspace("1"), .workspace("4")], "…", "vai pro workspace 1 a 4; com ⇧, manda a janela focada"),
            ([.clipboard], "", "histórico do que foi copiado"),
            ([.screenshot], "", "print de uma área da tela, com caneta, seta, texto e pixelar"),
        ]
        VStack(alignment: .leading, spacing: 12) {
            Title(text: "Atalhos")
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 9) {
                ForEach(rows.indices, id: \.self) { i in
                    GridRow {
                        HStack(spacing: 4) {
                            ForEach(rows[i].keys.indices, id: \.self) { k in
                                if k > 0 { Text(rows[i].between).foregroundStyle(.secondary) }
                                KeyCap(text: keys(rows[i].keys[k]))
                            }
                        }
                        .fixedSize()
                        Text(rows[i].text)
                    }
                }
            }
            Text("Todos dá pra trocar na aba Atalhos das configurações.").font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct DonePage: View {
    let m: WelcomeController.Model
    private static let icon = [5.0, 10, 5]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Title(text: "Pronto")
            HStack(spacing: 14) {
                // O ícone da barra de menu, como em `Settings`.
                HStack(spacing: 2) {
                    ForEach(Self.icon.indices, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1.5).frame(width: Self.icon[i], height: 14)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                Text("O ícone na barra de menu abre as configurações: recursos, atalhos, workspaces, papel de parede e borda.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Abrir o NiriOS ao iniciar o Mac", isOn: Binding(get: { m.atLogin }, set: { m.atLogin = $0 }))
                .toggleStyle(.switch)
                .accessibilityLabel("Abrir o NiriOS ao iniciar o Mac")
            if m.on.contains(.tiling) {
                Text("Ao clicar em Começar, as janelas abertas entram na fita.").foregroundStyle(.secondary)
            }
        }
    }
}
