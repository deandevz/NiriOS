/// A versão do NiriOS.app ("0.1.0", o `CFBundleShortVersionString`) e a da release, sem o "v" da tag.
public enum Version {
    /// `a` depois de `b`, parte por parte em número: 0.10.0 vem depois de 0.9.1 (comparando texto, viria antes). Parte que
    /// falta conta 0, e parte que não é número também.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}
