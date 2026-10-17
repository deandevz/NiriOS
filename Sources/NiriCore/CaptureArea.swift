import CoreGraphics

/// A área escolhida no print do Option+S (ver `ScreenshotEditor`), em pontos com y pra baixo a partir do canto de cima
/// da tela. Fica sempre dentro da tela e com as bordas em pixel inteiro: o que aparece na tela é o que sai no arquivo.
public struct CaptureArea: Equatable, Sendable {
    /// Os cantos e o meio de cada lado.
    public enum Handle: CaseIterable, Sendable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        /// As bordas que a alça mexe: x -1 a esquerda, 1 a direita, 0 nenhuma; y -1 a de cima, 1 a de baixo.
        public var edges: (x: Int, y: Int) {
            switch self {
            case .topLeft: (-1, -1)
            case .top: (0, -1)
            case .topRight: (1, -1)
            case .right: (1, 0)
            case .bottomRight: (1, 1)
            case .bottom: (0, 1)
            case .bottomLeft: (-1, 1)
            case .left: (-1, 0)
            }
        }

        public func point(in r: CGRect) -> CGPoint {
            let e = edges
            return CGPoint(x: e.x < 0 ? r.minX : e.x > 0 ? r.maxX : r.midX, y: e.y < 0 ? r.minY : e.y > 0 ? r.maxY : r.midY)
        }
    }

    /// O que o clique pegou: uma alça ou o meio da área.
    public enum Grab: Equatable, Sendable {
        case handle(Handle), inside
    }

    public private(set) var rect = CGRect.zero
    public let bounds: CGRect
    public let scale: CGFloat

    public init(bounds: CGRect, scale: CGFloat) {
        self.bounds = bounds
        self.scale = scale
    }

    /// Menos de 4 pt num dos lados é um clique, não uma área.
    public var isEmpty: Bool { rect.width < 4 || rect.height < 4 }

    /// A área em pixels da foto da tela.
    public var pixels: CGRect {
        CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral
    }

    /// De um canto ao outro do arrasto, em qualquer direção.
    public mutating func select(from a: CGPoint, to b: CGPoint) {
        set(a.x, a.y, b.x, b.y)
    }

    public mutating func selectAll() {
        set(bounds.minX, bounds.minY, bounds.maxX, bounds.maxY)
    }

    /// Mexe a área `start` (a do começo do arrasto) pelo quanto o mouse andou desde lá. No meio, move inteira, parando
    /// na borda da tela sem mudar de tamanho. Numa alça, só as bordas dela; passar da borda oposta vira a área.
    public mutating func drag(_ grab: Grab, from start: CGRect, by d: CGVector) {
        switch grab {
        case .inside:
            let x = min(max(start.minX + d.dx, bounds.minX), bounds.maxX - start.width)
            let y = min(max(start.minY + d.dy, bounds.minY), bounds.maxY - start.height)
            set(x, y, x + start.width, y + start.height)
        case .handle(let h):
            var (x0, x1, y0, y1) = (start.minX, start.maxX, start.minY, start.maxY)
            let e = h.edges
            if e.x < 0 { x0 += d.dx } else if e.x > 0 { x1 += d.dx }
            if e.y < 0 { y0 += d.dy } else if e.y > 0 { y1 += d.dy }
            set(x0, y0, x1, y1)
        }
    }

    /// A alça mais perto do ponto, até `reach` pt dela; senão o meio da área; senão nada.
    public func grab(at p: CGPoint, reach: CGFloat) -> Grab? {
        guard !isEmpty else { return nil }
        let near = Handle.allCases.map { h in (h, hypot(h.point(in: rect).x - p.x, h.point(in: rect).y - p.y)) }
            .filter { $0.1 <= reach }.min { $0.1 < $1.1 }
        if let near { return .handle(near.0) }
        return rect.contains(p) ? .inside : nil
    }

    /// O canto de cima da barra de `size`: embaixo da área, alinhada à direita dela; sem espaço embaixo, em cima; sem
    /// espaço nos dois, dentro, no pé da área. Sempre `margin` pt dentro da tela.
    public func toolbarOrigin(_ size: CGSize, margin m: CGFloat) -> CGPoint {
        let x = min(max(rect.maxX - size.width, bounds.minX + m), bounds.maxX - size.width - m)
        let below = rect.maxY + m, above = rect.minY - m - size.height
        let y = below + size.height <= bounds.maxY - m ? below : above >= bounds.minY + m ? above : rect.maxY - m - size.height
        return CGPoint(x: x, y: min(max(y, bounds.minY + m), bounds.maxY - size.height - m))
    }

    /// Presa na tela, em ordem e com cada borda no pixel mais perto.
    private mutating func set(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) {
        func px(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { (min(max(v, lo), hi) * scale).rounded() / scale }
        let l = px(min(x0, x1), bounds.minX, bounds.maxX), r = px(max(x0, x1), bounds.minX, bounds.maxX)
        let t = px(min(y0, y1), bounds.minY, bounds.maxY), b = px(max(y0, y1), bounds.minY, bounds.maxY)
        rect = CGRect(x: l, y: t, width: r - l, height: b - t)
    }
}
