import Foundation

/// Efeitos do papel de parede, portados do Kinggie (King Bot v2, `src/kinggie/web/backdrop/treat.ts`):
/// mesmas contas e mesmos números. Mexem nos pixels da própria imagem, uma vez, quando o config muda;
/// nada roda por frame. Conta pura sobre RGBA de 8 bits: quem lê, reduz e amplia a imagem é o `Wallpaper`.
public enum WallpaperEffect: String, CaseIterable {
    case none, dither, halftone, scanlines, ascii

    /// Pontos da tela por pixel tratado. O dither é graúdo de propósito; meio-tom e scanlines trabalham
    /// em 1 pt; o ASCII é uma célula de texto (um glifo).
    public var cell: (w: Int, h: Int) {
        switch self {
        case .dither: (3, 3)
        case .ascii: (7, 12)
        case .none, .halftone, .scanlines: (1, 1)
        }
    }

    /// O ASCII desenha texto (ver `glyph`) e por isso não passa por aqui.
    public func apply(_ px: inout [UInt8], width: Int, height: Int) {
        switch self {
        case .dither: Self.dither(&px, width, height)
        case .halftone: Self.halftone(&px, width, height)
        case .scanlines: Self.scanlines(&px, width, height)
        case .none, .ascii: break
        }
    }

    public static func luma(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Double {
        (0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)) / 255
    }

    /// Como o `Uint8ClampedArray` do JS grava: corta em 0...255 e arredonda meio pro par.
    private static func byte(_ v: Double) -> UInt8 { UInt8(min(255, max(0, v)).rounded(.toNearestOrEven)) }

    private static let bayer: [Double] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]

    /// Dither ordenado de Bayer 4×4: cada canal cai num de 4 tons (0, 85, 170, 255) e a matriz decide o
    /// arredondamento. Sem paleta fixa: a cor da imagem fica.
    static func dither(_ p: inout [UInt8], _ w: Int, _ h: Int) {
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4, t = (bayer[(y & 3) * 4 + (x & 3)] + 0.5) / 16 - 0.5
                for k in 0..<3 {
                    // Math.round do JS: meio pra cima.
                    let q = min(3, max(0, (Double(p[i + k]) / 255 * 3 + t + 0.5).rounded(.down)))
                    p[i + k] = byte(q / 3 * 255)
                }
            }
        }
    }

    /// Meio-tom: um ponto por célula de 6 px, do tamanho do brilho do centro dela e na cor dele, sobre preto.
    /// O ponto mais claro passa um pouco da célula; a borda é suavizada em 1 px.
    static func halftone(_ p: inout [UInt8], _ w: Int, _ h: Int) {
        let src = p, dot = 6
        for y in 0..<h {
            let cy = min(h - 1, y / dot * dot + dot / 2)
            for x in 0..<w {
                let cx = min(w - 1, x / dot * dot + dot / 2)
                let c = (cy * w + cx) * 4, i = (y * w + x) * 4
                let light = luma(src[c], src[c + 1], src[c + 2])
                let radius = light.squareRoot() * Double(dot) * 0.66
                let dist = hypot(Double(x) + 0.5 - Double(cx), Double(y) + 0.5 - Double(cy))
                let cover = min(1, max(0, radius - dist + 0.5))
                // A cor vai pra um brilho quase constante: o tamanho do ponto é que conta o claro e o escuro.
                let gain = cover * (0.5 + 0.5 * light) / max(light, 0.04)
                for k in 0..<3 { p[i + k] = byte(Double(src[c + k]) * gain) }
            }
        }
    }

    /// De três em três linhas uma apaga, e as outras ganham brilho pra imagem não escurecer.
    static func scanlines(_ p: inout [UInt8], _ w: Int, _ h: Int) {
        for y in 0..<h {
            let gain = y % 3 == 2 ? 0.38 : 1.1
            for i in stride(from: y * w * 4, to: (y + 1) * w * 4, by: 4) {
                for k in 0..<3 { p[i + k] = byte(Double(p[i + k]) * gain) }
            }
        }
    }

    /// Os glifos do ASCII, do mais vazio ao mais cheio.
    public static let glyphs = Array(" .:-=+*#%@")

    /// Glifo de uma célula (0 = vazio, não desenha) e a cor dele: a da célula, clareada, porque o peso
    /// do glifo já conta o claro e o escuro.
    public static func glyph(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> (index: Int, rgb: [UInt8]) {
        let index = min(glyphs.count - 1, Int(luma(r, g, b) * Double(glyphs.count)))
        let gain = 1.5 + 90 / Double(max(r, g, b, 1))
        return (index, [r, g, b].map { byte(min(255, Double($0) * gain)) })
    }
}
