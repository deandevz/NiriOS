import Foundation
import Testing
@testable import NiriCore

private func item(_ n: Int, _ text: String? = nil, app: String? = nil) -> ClipboardList.Item {
    ClipboardList.Item(id: "\(n)", text: text ?? "texto \(n)", digest: "d\(n)", app: app, date: Date(timeIntervalSince1970: Double(n)))
}

@Test func recentRotatesAt25AndPinnedDoNotCount() {
    var l = ClipboardList()
    for n in 0..<10 { _ = l.add(item(n)) }
    for n in 0..<10 { #expect(l.setPinned("\(n)", true).ok) }
    var gone: [String] = []
    for n in 10..<40 { gone += l.add(item(n)) }
    // 30 recentes entraram, cabem 25: saíram as 5 mais velhas, e nenhum fixado.
    #expect(gone == ["10", "11", "12", "13", "14"])
    #expect(l.items.count == 35)
    #expect(l.pinnedCount == 10)
    #expect(l.items.first?.id == "39")
}

@Test func pinLimitIs10() {
    var l = ClipboardList()
    for n in 0..<12 { _ = l.add(item(n)) }
    for n in 0..<10 { #expect(l.setPinned("\(n)", true).ok) }
    #expect(!l.setPinned("10", true).ok)
    #expect(l.pinnedCount == 10)
    #expect(l.setPinned("3", false).ok)
    #expect(l.setPinned("10", true).ok)
}

@Test func unpinnedBecomesNewestRecentAndPushesTheOldest() {
    var l = ClipboardList()
    _ = l.add(item(0))
    _ = l.setPinned("0", true)
    for n in 1...25 { _ = l.add(item(n)) }
    let r = l.setPinned("0", false)
    #expect(r.ok)
    #expect(r.removed == ["1"])  // a mais velha das recentes, não a que acabou de desafixar
    #expect(l.items.first?.id == "0")
    #expect(l.items.filter { !$0.pinned }.count == 25)
}

@Test func touchMovesRecentToTopButKeepsPinnedInPlace() {
    var l = ClipboardList()
    for n in 0..<4 { _ = l.add(item(n)) }  // 3 2 1 0
    l.touch("1", at: Date(timeIntervalSince1970: 100))
    #expect(l.items.map(\.id) == ["1", "3", "2", "0"])
    #expect(l.items[0].date == Date(timeIntervalSince1970: 100))
    _ = l.setPinned("2", true)
    l.touch("2", at: Date(timeIntervalSince1970: 200))
    #expect(l.items.map(\.id) == ["1", "3", "2", "0"])
    #expect(l.item(digest: "d0")?.id == "0")
}

@Test func rebootKeepsOnlyPinned() {
    var l = ClipboardList()
    for n in 0..<5 { _ = l.add(item(n)) }
    _ = l.setPinned("2", true)
    #expect(Set(l.dropRecent()) == ["0", "1", "3", "4"])
    #expect(l.items.map(\.id) == ["2"])
}

@Test func searchIgnoresCaseAndAccentsAndMatchesApp() {
    var l = ClipboardList()
    _ = l.add(item(0, "Configuração do WezTerm"))
    _ = l.add(item(1, nil, app: "Safari"))
    _ = l.add(ClipboardList.Item(id: "img", text: nil, digest: "i", app: "Preview", date: .now))
    #expect(l.search("CONFIGURACAO").map(\.id) == ["0"])
    #expect(l.search("preview").map(\.id) == ["img"])
    #expect(l.search("  ").count == 3)
    #expect(l.search("nada disso").isEmpty)
}

@Test func listRoundTripsThroughJSON() throws {
    var l = ClipboardList()
    for n in 0..<3 { _ = l.add(item(n, app: "App")) }
    _ = l.setPinned("1", true)
    let back = try JSONDecoder().decode(ClipboardList.self, from: JSONEncoder().encode(l))
    #expect(back == l)
}
