import AppKit

/// The keyboard shortcut table (DESIGN §9), read from the menu bar that
/// ``MainMenu`` builds, so Settings › Shortcuts always shows the bindings
/// that are actually in effect.
@MainActor
enum ShortcutTable {
    struct Row: Identifiable, Hashable, Sendable {
        let id: Int
        /// Top-level menu, e.g. "File".
        let menu: String
        /// Command, e.g. "Show Tab 1–8".
        let command: String
        /// Shortcut, e.g. "⌘1…⌘8" or "⇧⌘], ⌃⇥".
        let shortcut: String
    }

    /// Every menu item Armadale created (``MainMenu/isOwnItem(_:)``) with a
    /// key equivalent, by menu; items AppKit adds (Services, window tiling)
    /// are not Armadale's shortcuts and are left out. A hidden alternate
    /// (``NSMenuItem/allowsKeyEquivalentWhenHidden``) is listed with the
    /// visible item of the same action; numbered runs (⌘1…⌘8, ⇧⌘1…⇧⌘9) are
    /// collapsed into one row.
    static func rows(from mainMenu: NSMenu) -> [Row] {
        var entries: [Entry] = []
        for top in mainMenu.items {
            guard let submenu = top.submenu, MainMenu.isOwnItem(top) else { continue }
            collect(submenu, menu: top.title.isEmpty ? submenu.title : top.title, into: &entries)
        }
        return collapse(entries).enumerated().map { index, entry in
            Row(id: index, menu: entry.menu, command: entry.command, shortcut: entry.shortcuts.joined(separator: ", "))
        }
    }

    /// One command while the table is being built.
    private struct Entry {
        var menu: String
        var command: String
        var action: Selector?
        var shortcuts: [String]
        /// For collapsing numbered runs: the key digit and the shortcut
        /// without it.
        var digit: Int?
        var modifiers: String
    }

    private static func collect(_ menu: NSMenu, menu name: String, into entries: inout [Entry]) {
        for item in menu.items {
            if let submenu = item.submenu {
                // The Services menu is filled in by the system.
                guard submenu !== NSApp?.servicesMenu, MainMenu.isOwnItem(item) else { continue }
                collect(submenu, menu: name, into: &entries)
                continue
            }
            guard MainMenu.isOwnItem(item), !item.keyEquivalent.isEmpty, !item.isSeparatorItem else { continue }
            let shortcut = display(key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask)
            if item.isHidden {
                // An alternate binding of the command just listed.
                if let index = entries.lastIndex(where: { $0.menu == name && $0.action == item.action }) {
                    entries[index].shortcuts.append(shortcut)
                }
                continue
            }
            entries.append(Entry(
                menu: name, command: item.title, action: item.action, shortcuts: [shortcut],
                digit: Int(item.keyEquivalent), modifiers: modifierSymbols(item.keyEquivalentModifierMask)))
        }
    }

    /// "Show Tab 1" … "Show Tab 8" (⌘1…⌘8) becomes "Show Tab 1–8" (⌘1…⌘8).
    private static func collapse(_ entries: [Entry]) -> [Entry] {
        var result: [Entry] = []
        var index = 0
        while index < entries.count {
            let first = entries[index]
            guard let firstDigit = first.digit, let base = numberedBase(first.command, digit: firstDigit) else {
                result.append(first)
                index += 1
                continue
            }
            var end = index
            while end + 1 < entries.count, let next = entries[end + 1].digit, next == firstDigit + (end + 1 - index),
                  entries[end + 1].action == first.action, entries[end + 1].modifiers == first.modifiers,
                  numberedBase(entries[end + 1].command, digit: next) == base {
                end += 1
            }
            guard end > index, let lastDigit = entries[end].digit else {
                result.append(first)
                index += 1
                continue
            }
            var merged = first
            merged.command = "\(base) \(firstDigit)–\(lastDigit)"
            merged.shortcuts = ["\(first.modifiers)\(firstDigit)…\(first.modifiers)\(lastDigit)"]
            result.append(merged)
            index = end + 1
        }
        return result
    }

    /// "Show Tab 3" with digit 3 → "Show Tab".
    private static func numberedBase(_ title: String, digit: Int) -> String? {
        let suffix = " \(digit)"
        guard title.hasSuffix(suffix) else { return nil }
        return String(title.dropLast(suffix.count))
    }

    /// The shortcut as menus show it: modifiers in the order 🌐⌃⌥⇧⌘, then the key.
    static func display(key: String, modifiers: NSEvent.ModifierFlags) -> String {
        var flags = modifiers
        // An upper-case letter as key equivalent implies Shift.
        if key.count == 1, let scalar = key.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(scalar) {
            flags.insert(.shift)
        }
        return modifierSymbols(flags) + keySymbol(key)
    }

    /// ⌃⌥⇧⌘, preceded by 🌐 for the Globe (fn) key.
    private static func modifierSymbols(_ flags: NSEvent.ModifierFlags) -> String {
        var result = ""
        if flags.contains(.function) { result += "🌐" }
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        return result
    }

    private static func keySymbol(_ key: String) -> String {
        guard let scalar = key.unicodeScalars.first, key.unicodeScalars.count == 1 else { return key.uppercased() }
        switch Int(scalar.value) {
        case NSLeftArrowFunctionKey: return "←"
        case NSRightArrowFunctionKey: return "→"
        case NSUpArrowFunctionKey: return "↑"
        case NSDownArrowFunctionKey: return "↓"
        case 0x0D, 0x03: return "↩"
        case 0x09: return "⇥"
        case 0x1B: return "⎋"
        case 0x08, 0x7F: return "⌫"
        case 0x20: return "Space"
        default: return key.uppercased()
        }
    }
}
