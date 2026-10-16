import Carbon.HIToolbox
import Testing
@testable import NiriCore

@Test func shortcutTextRoundTrips() {
    // Os padrões primeiro: o Config lê eles com `!`.
    for text in ["option+=", "option+keypadplus", "option+-", "option+keypadminus", "option+,", "option+left",
                 "option+.", "option+right", "option+f", "ctrl+option+shift+cmd+space", "cmd+key105", "option+f12"] {
        #expect(Shortcut(text)?.description == text)
    }
    #expect(Shortcut("Alt+=") == Shortcut(key: Int64(kVK_ANSI_Equal), mods: .maskAlternate))
    #expect(Shortcut("option+=")?.display == "⌥ =")
    #expect(Shortcut("ctrl+option+left")?.display == "⌃⌥ ←")
    for bad in ["hyper+a", "option+", "option+banana", ""] { #expect(Shortcut(bad) == nil) }
}
