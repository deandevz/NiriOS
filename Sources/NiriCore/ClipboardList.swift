import Foundation

/// A lista do histórico do Option+V: até 25 recentes, que rodam, e até 10 fixados, que não contam nos 25 e só saem
/// quando alguém desafixa ou apaga. Aqui só o que a lista precisa; os dados de cada cópia ficam em disco, com o
/// mesmo `id` (ver `Clipboard` no niri-os).
public struct ClipboardList: Codable, Equatable {
    public struct Item: Codable, Equatable {
        public let id: String
        /// O texto da cópia, cortado em `textLimit` (prévia e pesquisa); nil numa imagem.
        public var text: String?
        /// Igual = a mesma cópia (hash do texto, ou dos bytes da imagem).
        public let digest: String
        /// O app da frente na hora da cópia.
        public var app: String?
        public var date: Date
        public var pinned = false

        public init(id: String, text: String?, digest: String, app: String?, date: Date) {
            self.id = id
            self.text = text
            self.digest = digest
            self.app = app
            self.date = date
        }
    }

    public static let maxRecent = 25, maxPinned = 10, textLimit = 2000

    /// A mais nova primeiro. Fixar não muda a posição: a ordem vale dentro de cada grupo.
    public private(set) var items: [Item] = []

    public init() {}

    public var pinnedCount: Int { items.filter(\.pinned).count }

    public func item(digest: String) -> Item? { items.first { $0.digest == digest } }

    /// Cópia nova no topo. Devolve o id das que saíram (a 26ª recente), pra apagar do disco.
    public mutating func add(_ item: Item) -> [String] {
        items.insert(item, at: 0)
        return trim()
    }

    /// A cópia voltou pro clipboard (copiada de novo, ou colada pelo painel): a recente sobe pro topo. A fixada fica
    /// onde está, pra não trocar de lugar embaixo do dedo.
    public mutating func touch(_ id: String, at date: Date) {
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].pinned else { return }
        var item = items.remove(at: i)
        item.date = date
        items.insert(item, at: 0)
    }

    /// Fixar falha com 10 fixados. A desafixada vira a recente mais nova (antiga, sairia na hora) e empurra a 26ª.
    public mutating func setPinned(_ id: String, _ pinned: Bool) -> (ok: Bool, removed: [String]) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].pinned != pinned else { return (true, []) }
        if pinned {
            guard pinnedCount < Self.maxPinned else { return (false, []) }
            items[i].pinned = true
            return (true, [])
        }
        var item = items.remove(at: i)
        item.pinned = false
        items.insert(item, at: 0)
        return (true, trim())
    }

    public mutating func remove(_ id: String) { items.removeAll { $0.id == id } }

    /// O Mac reiniciou: só os fixados ficam, como no Windows. Devolve o id das que saíram.
    public mutating func dropRecent() -> [String] {
        let gone = items.filter { !$0.pinned }.map(\.id)
        items.removeAll { !$0.pinned }
        return gone
    }

    /// Pelo texto ou pelo nome do app, sem diferença de maiúscula nem de acento. Vazia: todas.
    public func search(_ query: String) -> [Item] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return items }
        return items.filter { item in
            [item.text, item.app].contains { $0?.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    private mutating func trim() -> [String] {
        var recent = 0, gone: [String] = []
        items.removeAll { item in
            guard !item.pinned else { return false }
            recent += 1
            guard recent > Self.maxRecent else { return false }
            gone.append(item.id)
            return true
        }
        return gone
    }
}
