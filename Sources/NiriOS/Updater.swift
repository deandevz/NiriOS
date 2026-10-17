import AppKit
import NiriCore
import SwiftUI

/// O update (processo `niri-os --update`, aberto pelo niri-os uma vez por dia e pelo "Procurar atualização" do painel;
/// ver `Settings.checkUpdate`). Lê a última release do repo público, baixa o zip, confere e pergunta. A troca do app é
/// do niri-os (`Settings.install`): se ela falhar, ele continua aberto na versão de antes.
///
/// Num processo à parte porque o URLSession e o SwiftUI deixariam memória presa no niri-os (como o painel, ver `Settings`).
/// Conferido antes de perguntar: mesmo bundle id, a versão da tag e a assinatura com o mesmo certificado deste app (a
/// mesma regra que o macOS usa pra manter a Acessibilidade e a Gravação de Tela). App sem certificado não atualiza.
enum Updater {
    /// `NIRI_UPDATE_URL` troca a release (pra testar com um JSON local, no mesmo formato).
    static let feed = URL(string: ProcessInfo.processInfo.environment["NIRI_UPDATE_URL"]
        ?? "https://api.github.com/repos/deandevz/niri-os-releases/releases/latest")!

    struct Release {
        let version: String
        let notes: String
        let zip: URL
    }

    enum Failure: LocalizedError {
        case feed(String), check(String)
        var errorDescription: String? {
            switch self {
            case .feed(let m): "a release não veio como esperado: \(m)"
            case .check(let m): "o app baixado não passou na conferência: \(m)"
            }
        }
    }

    /// `manual`: a janela abre na hora e mostra também "nenhuma versão nova" e erro. Na conferência diária só abre com
    /// versão nova pronta pra instalar.
    @MainActor static func run(manual: Bool) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let ui = UpdateWindow()
        if manual { ui.show(.checking) }
        Task { @MainActor in
            do {
                let current = AppBundle.version ?? "0"
                let r = try await latest()
                guard Version.isNewer(r.version, than: current) else {
                    log("update: \(current) é a última")
                    if manual { return ui.show(.upToDate(current)) }
                    exit(0)
                }
                log("update: baixando a \(r.version)")
                let staged = try await download(r)
                log("update: \(r.version) conferida, perguntando")
                ui.show(.ready(r, current: current, staged: staged))
            } catch {
                log("update: \(error.localizedDescription)")
                if manual { ui.show(.failed(error.localizedDescription)) } else { exit(0) }
            }
        }
        app.run()
        exit(0)
    }

    static func latest() async throws -> Release {
        var req = URLRequest(url: feed, timeoutInterval: 20)
        req.setValue("NiriOS/\(AppBundle.version ?? "dev")", forHTTPHeaderField: "User-Agent")  // o GitHub exige
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw Failure.feed("HTTP \(http.statusCode)") }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else { throw Failure.feed("sem tag_name") }
        let assets = obj["assets"] as? [[String: Any]] ?? []
        guard let zip = assets.lazy.compactMap({ a in (a["name"] as? String)?.hasSuffix(".zip") == true ? a["browser_download_url"] as? String : nil })
            .first.flatMap(URL.init(string:)) else { throw Failure.feed("sem o zip do app") }
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, notes: obj["body"] as? String ?? "", zip: zip)
    }

    /// Baixa e abre o zip numa pasta da mesma partição do app, pra a troca ser um rename, e confere.
    static func download(_ r: Release) async throws -> URL {
        let (zip, response) = try await URLSession.shared.download(for: URLRequest(url: r.zip, timeoutInterval: 120))
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw Failure.feed("zip: HTTP \(http.statusCode)") }
        let dir = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                              appropriateFor: Bundle.main.bundleURL, create: true)
        defer { try? FileManager.default.removeItem(at: zip) }
        do {
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", zip.path, dir.path]
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else { throw Failure.check("o zip não abriu") }
            let new = dir.appendingPathComponent(Bundle.main.bundleURL.lastPathComponent)
            guard let info = Bundle(url: new)?.infoDictionary else { throw Failure.check("sem \(new.lastPathComponent) no zip") }
            guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else { throw Failure.check("outro bundle id") }
            guard info["CFBundleShortVersionString"] as? String == r.version else { throw Failure.check("a versão não é a da tag") }
            try checkSignature(new)
            return new
        } catch {
            try? FileManager.default.removeItem(at: dir)  // o recusado não fica no disco
            throw error
        }
    }

    /// O app novo satisfaz a regra de assinatura deste: o mesmo certificado e o mesmo identificador.
    static func checkSignature(_ app: URL) throws {
        var me: SecCode?, mine: SecStaticCode?, rule: SecRequirement?, new: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me, SecCodeCopyStaticCode(me, [], &mine) == errSecSuccess, let mine,
              SecCodeCopyDesignatedRequirement(mine, [], &rule) == errSecSuccess, let rule else {
            throw Failure.check("este app não tem assinatura")
        }
        var text: CFString?
        SecRequirementCopyString(rule, [], &text)
        // Sem certificado (assinatura ad-hoc) a regra é o hash do próprio binário: nenhuma versão nova passaria.
        guard (text as String?)?.contains("certificate") == true else { throw Failure.check("este app foi assinado sem certificado") }
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &new) == errSecSuccess, let new else { throw Failure.check("sem assinatura") }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(new, flags, rule)
        guard status == errSecSuccess else { throw Failure.check("assinatura de outro certificado ou alterada (\(status))") }
    }
}

/// A janela do update. Fechar é o "Depois": amanhã ele pergunta de novo.
@MainActor final class UpdateWindow: NSObject, NSWindowDelegate {
    enum State {
        case checking, upToDate(String), failed(String)
        case ready(Updater.Release, current: String, staged: URL)
    }

    private var window: NSWindow?
    private let model = Model()
    private var installing = false

    @Observable final class Model { var state = State.checking }

    func show(_ s: State) {
        model.state = s
        guard window == nil else { return }
        let host = NSHostingController(rootView: UpdateView(model: model, window: self))
        host.sizingOptions = .preferredContentSize
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable]
        w.title = "Atualização do NiriOS"
        w.delegate = self
        w.layoutIfNeeded()
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        send("front \(w.windowNumber)")  // o niri-os traz pra frente, como o painel (ver `Settings.front`)
    }

    func install(_ staged: URL) {
        installing = true
        send("install \(staged.path)")
        exit(0)
    }

    func close() { window?.close() }

    /// "Depois": o baixado sai do disco, e amanhã baixa de novo (o zip tem ~1 MB).
    func windowWillClose(_ notification: Notification) {
        if case .ready(_, _, let staged) = model.state, !installing {
            try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
        }
        DispatchQueue.main.async { exit(0) }
    }

    private func send(_ line: String) {
        print(line)
        fflush(stdout)
    }
}

private struct UpdateView: View {
    let model: UpdateWindow.Model
    let window: UpdateWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.state {
            case .checking:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Procurando atualização…")
                }
            case .upToDate(let v):
                Text("Você está na versão mais recente").font(.headline)
                Text("NiriOS \(v).").foregroundStyle(.secondary)
                buttons { Button("OK") { window.close() }.keyboardShortcut(.defaultAction) }
            case .failed(let error):
                Text("Não consegui procurar atualização").font(.headline)
                Text(error).foregroundStyle(.secondary).textSelection(.enabled)
                buttons { Button("OK") { window.close() }.keyboardShortcut(.defaultAction) }
            case .ready(let r, let current, let staged):
                Text("NiriOS \(r.version) está pronto pra instalar").font(.headline)
                Text("Você tem a \(current). As janelas ficam onde estão e o NiriOS reabre em menos de um segundo.")
                    .foregroundStyle(.secondary)
                if !r.notes.isEmpty {
                    ScrollView {
                        Text((try? AttributedString(markdown: r.notes, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                             ?? AttributedString(r.notes))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .frame(maxHeight: 180)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                }
                buttons {
                    Button("Depois") { window.close() }.keyboardShortcut(.cancelAction)
                    Button("Atualizar agora") { window.install(staged) }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(width: 400, alignment: .leading)
        .padding(20)
    }

    private func buttons(@ViewBuilder _ content: () -> some View) -> some View {
        HStack {
            Spacer()
            content()
        }
    }
}
