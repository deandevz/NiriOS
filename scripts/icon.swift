// Desenha o ícone do NiriOS.app: a fita do ícone da barra de menu (a coluna focada no meio, as vizinhas cortadas pela
// borda). Uso: swift scripts/icon.swift <saída.png>, 1024 px. O scripts/app.sh transforma no .icns.
import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    // A grade dos ícones do macOS: o corpo tem 824 px, com 100 de margem.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGradient(starting: NSColor(srgbRed: 0.16, green: 0.13, blue: 0.24, alpha: 1),
               ending: NSColor(srgbRed: 0.07, green: 0.06, blue: 0.11, alpha: 1))!.draw(in: shape, angle: -90)
    shape.addClip()
    let h = 430.0, y = body.midY - h / 2, gap = 34.0
    let focused = NSRect(x: body.midX - 170, y: y, width: 340, height: h)
    let columns = [NSRect(x: focused.minX - gap - 230, y: y, width: 230, height: h),
                   NSRect(x: focused.maxX + gap, y: y, width: 230, height: h)]
    NSColor(white: 1, alpha: 0.28).setFill()
    for c in columns { NSBezierPath(roundedRect: c, xRadius: 36, yRadius: 36).fill() }
    let accent = NSColor(srgbRed: 0.75, green: 0.35, blue: 1, alpha: 1)
    NSColor(srgbRed: 0.75, green: 0.35, blue: 1, alpha: 0.22).setFill()
    NSBezierPath(roundedRect: focused, xRadius: 36, yRadius: 36).fill()
    let border = NSBezierPath(roundedRect: focused.insetBy(dx: 9, dy: 9), xRadius: 28, yRadius: 28)
    border.lineWidth = 18
    accent.setStroke()
    border.stroke()
    return true
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
