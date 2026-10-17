import AppKit

/// O print do Option+S. A foto da tela sai daqui, na hora da tecla; quem mostra e edita é outro processo
/// (`niri-os --screenshot`, ver `ScreenshotEditor`), que recebe a foto pelo stdin e sai ao copiar, salvar ou cancelar.
///
/// A foto não é tirada no editor porque um processo novo leva 45 a 85 ms só pra se conectar ao WindowServer: o frame
/// congelado seria o de 60 a 110 ms depois da tecla. Daqui sai 12 a 29 ms depois. Os pixels (31 MB numa tela Retina) vão
/// da memória da foto direto pro pipe e chegam no editor 54 a 63 ms depois da tecla, enquanto ele abre; a janela entra
/// aos 120 a 132 ms. Nada fica no niri-os: passando por `Data`, ficavam 30 MB presos (medido).
final class Screenshot {
    /// Aberto ou fechado: com o editor na tela, só o atalho do print é do niri-os (ver `HotkeyTap.solo`).
    var onOpen: ((Bool) -> Void)?
    var folder: URL
    private let verbose: Bool
    private var editor: Process?
    private let queue = DispatchQueue(label: "niri.screenshot", qos: .userInteractive, autoreleaseFrequency: .workItem)

    init(folder: URL, verbose: Bool) {
        self.folder = folder
        self.verbose = verbose
    }

    /// Recurso desligado com o editor aberto.
    deinit { editor?.terminate() }

    func toggle() { editor == nil ? open() : close() }

    func close() {
        guard let editor else { return }
        editor.terminate()
        self.editor = nil
        onOpen?(false)
    }

    private func open() {
        guard CGPreflightScreenCaptureAccess() else {
            log("print: sem a permissão de Gravação de Tela (Ajustes do Sistema > Privacidade e Segurança)")
            CGRequestScreenCaptureAccess()
            return
        }
        let t0 = CACurrentMediaTime()
        // A tela do mouse, em coordenadas do CG (origem no canto de cima da tela principal).
        var display: CGDirectDisplayID = 0, count: UInt32 = 0
        guard let mouse = CGEvent(source: nil)?.location, CGGetDisplaysWithPoint(mouse, 1, &display, &count) == .success, count == 1
        else { return }
        let bounds = CGDisplayBounds(display)
        let p = Process(), input = Pipe(), output = Pipe()
        p.executableURL = Bundle.main.executableURL
        p.arguments = ["--screenshot", "\(display)", folder.path] + (verbose ? ["-v", "\(t0)"] : [])
        p.standardInput = input
        p.standardOutput = output
        // A linha "done" chega quando a foto sai da tela; o processo pode ficar mais um pouco com o aviso de salvo.
        output.fileHandleForReading.readabilityHandler = { [weak self] h in
            if h.availableData.isEmpty { h.readabilityHandler = nil }
            DispatchQueue.main.async { self?.closed(p) }
        }
        p.terminationHandler = { [weak self] p in
            if p.terminationReason == .uncaughtSignal && p.terminationStatus != SIGTERM || p.terminationReason == .exit && p.terminationStatus != 0 {
                log("print: o editor caiu (\(p.terminationReason == .uncaughtSignal ? "sinal" : "código") \(p.terminationStatus))")
            }
            DispatchQueue.main.async { self?.closed(p) }
        }
        // Abre enquanto a foto sai: o processo se conecta ao WindowServer ao mesmo tempo. Começar a foto antes de criar o
        // processo não adianta: os dois disputam e a foto sai em 28 a 53 ms em vez de 12 a 29 (medido).
        do {
            try p.run()
        } catch {
            return log("print: não consegui abrir o editor: \(error)")
        }
        editor = p
        onOpen?(true)
        let fd = input.fileHandleForWriting
        queue.async { [verbose] in
            defer { try? fd.close() }  // sem a foto, o editor sai ao ver o fim do stdin
            guard let img = Private.captureScreen(bounds) else { return log("print: a foto da tela falhou") }
            let shot = CACurrentMediaTime()
            guard let data = img.dataProvider?.data else { return log("print: a foto da tela veio sem pixels") }
            // O formato numa linha, os pixels em seguida. Escrita falhando é o editor que já fechou (SIGPIPE ignorado).
            let header = Array("\(img.width) \(img.height) \(img.bitsPerComponent) \(img.bitsPerPixel) \(img.bytesPerRow) \(img.bitmapInfo.rawValue)\n".utf8)
            guard Self.write(fd.fileDescriptor, header, header.count),
                  Self.write(fd.fileDescriptor, CFDataGetBytePtr(data), CFDataGetLength(data)) else { return }
            if verbose {
                log(String(format: "print: foto aos %.0f ms da tecla, no editor aos %.0f", (shot - t0) * 1000, (CACurrentMediaTime() - t0) * 1000))
            }
        }
    }

    private func closed(_ p: Process) {
        guard editor === p else { return }
        editor = nil
        onOpen?(false)
    }

    private static func write(_ fd: Int32, _ bytes: UnsafePointer<UInt8>, _ n: Int) -> Bool {
        var done = 0
        while done < n {
            let w = Darwin.write(fd, bytes + done, n - done)
            if w < 0 && errno == EINTR { continue }
            guard w > 0 else { return false }
            done += w
        }
        return true
    }
}
