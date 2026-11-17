import AppKit
import Testing

/// Help › Acknowledgements: the third-party notices bundled in the app
/// (`Contents/Resources/Acknowledgements.txt`), which must carry everything
/// THIRD_PARTY_LICENSES.md reproduces and never name the persistence
/// helper's runtime.
@Suite("Acknowledgements")
@MainActor
struct AcknowledgementsTests {
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()

    private func thirdPartyLicenses() throws -> String {
        try String(contentsOf: Self.repositoryRoot.appendingPathComponent("THIRD_PARTY_LICENSES.md"), encoding: .utf8)
    }

    /// The text as the app reads it, from a bundle (the test bundle holds
    /// the same resource, see project.yml).
    private func bundled() throws -> String {
        try #require(AcknowledgementsWindowController.bundledText())
    }

    @Test func helpHasTheItemWithoutAShortcut() throws {
        _ = NSApplication.shared
        let menu = MainMenu.make(installsSpecialMenus: false)
        let help = try #require(menu.items.last?.submenu)
        #expect(help.title == "Help")
        let item = try #require(help.items.first { $0.title == "Acknowledgements" })
        #expect(item.action == #selector(AppDelegate.showAcknowledgements(_:)))
        #expect(item.target == nil, "nil-targeted, so it reaches the app delegate")
        #expect(item.keyEquivalent.isEmpty)
        #expect(MainMenu.isOwnItem(item))
        #expect(help.items.map(\.title).suffix(2) == ["Keyboard Shortcuts", "Acknowledgements"])
        #expect(!ShortcutTable.rows(from: menu).contains { $0.command == "Acknowledgements" })
    }

    @Test func theResourceLoadsFromTheBundle() throws {
        let text = try bundled()
        #expect(text.hasPrefix("Acknowledgements\n"))
        let source = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("Armadale/Resources/Acknowledgements.txt"),
            encoding: .utf8)
        #expect(text == source, "the bundled copy is the file in Armadale/Resources")
    }

    /// Every copyright line, every license text (the fenced blocks, verbatim)
    /// and every colour-scheme credit of THIRD_PARTY_LICENSES.md, so the two
    /// cannot drift.
    @Test func carriesEveryNoticeOfThirdPartyLicenses() throws {
        let text = try bundled()
        let licenses = try thirdPartyLicenses()
        let copyrights = licenses.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("Copyright (c)") }
        // SwiftTerm 4, the persistence helper 1, Sparkle 7 and three of the
        // licenses it carries (sais-lite, Ed25519, SUSignatureVerifier).
        #expect(copyrights.count == 15)
        for line in copyrights {
            #expect(text.contains(line), "missing: \(line)")
        }
        let fences = licenses.components(separatedBy: "```")
        let blocks = stride(from: 1, to: fences.count, by: 2).map { fences[$0].drop { $0 == "\n" } }
        #expect(blocks.count == 3, "SwiftTerm, the persistence helper and Sparkle")
        for block in blocks {
            #expect(text.contains(String(block)), "license text not verbatim: \(block.prefix(60))")
        }
        // SwiftTerm, the persistence helper, Sparkle and sais-lite.
        #expect(text.components(separatedBy: "Permission is hereby granted").count - 1 == 4)
        let schemesSection = try #require(licenses.components(separatedBy: "## Colour schemes").last)
        let credits = schemesSection.split(separator: "\n")
            .filter { $0.hasPrefix("- ") }
            .map { $0.replacingOccurrences(of: "**", with: "") }
        #expect(credits.count == 6)
        for credit in credits {
            #expect(text.contains(credit), "missing: \(credit)")
        }
    }

    /// Sparkle's LICENSE at the pinned tag, verbatim with the external
    /// licenses it carries (bsdiff, sais-lite, Ed25519, SUSignatureVerifier).
    @Test func carriesSparklesLicenseWithItsExternalLicenses() throws {
        let text = try bundled()
        let licenses = try thirdPartyLicenses()
        for source in [text, licenses] {
            #expect(source.contains("Sparkle update framework"))
            #expect(source.contains("Copyright (c) 2006-2013 Andy Matuschak."))
            #expect(source.contains("EXTERNAL LICENSES"))
            #expect(source.contains("Copyright 2003-2005 Colin Percival"))
            #expect(source.contains("Copyright (c) 2008-2010 Yuta Mori All Rights Reserved."))
            #expect(source.contains("Copyright (c) 2015 Orson Peters <orsonpeters@gmail.com>"))
            #expect(source.contains("Copyright (c) 2011 Mark Hamlin."))
        }
        // The order of the sections: Sparkle after the persistence helper,
        // before the colour schemes.
        let helper = try #require(text.range(of: "\nThe persistence helper\n"))
        let sparkle = try #require(text.range(of: "\nSparkle\n"))
        let schemes = try #require(text.range(of: "\nColour schemes\n"))
        #expect(helper.upperBound <= sparkle.lowerBound && sparkle.upperBound <= schemes.lowerBound)
    }

    /// Product rule (AGENTS.md): the runtime's name is never user-visible.
    @Test func neverNamesTheRuntime() throws {
        let text = try bundled()
        #expect(!text.lowercased().contains("zmx"))
        #expect(text.contains("persistence helper"))
        #expect(text.contains("Copyright (c) 2025 Eric Bower"))
        #expect(!AcknowledgementsWindowController.title.lowercased().contains("zmx"))
    }

    /// One shared window: asking again reuses the controller and its window.
    @Test func openingTwiceKeepsOneWindow() throws {
        _ = NSApplication.shared
        func count() -> Int { NSApp.windows.filter { $0.identifier?.rawValue == "acknowledgements" }.count }
        let before = count()
        let first = AcknowledgementsWindowController.reusing(nil)
        let second = AcknowledgementsWindowController.reusing(first)
        #expect(first === second)
        #expect(first.window === second.window)
        let window = try #require(first.window)
        defer { window.close() }
        #expect(count() == before + 1)

        #expect(window.title == "Acknowledgements")
        #expect(window.styleMask.contains(.closable))
        #expect(window.styleMask.contains(.resizable))
        #expect(window.contentRect(forFrameRect: window.frame).size == AcknowledgementsWindowController.contentSize)
        #expect(!window.isReleasedWhenClosed)
        #expect(first.document == nil)

        let textView = first.textView
        #expect(!textView.isEditable)
        #expect(textView.isSelectable)
        #expect(!textView.isRichText)
        #expect(textView.string == (try bundled()))
        #expect(textView.enclosingScrollView === window.contentView)
        #expect(textView.enclosingScrollView?.hasVerticalScroller == true)

        let close = NSMenuItem(
            title: "Close Pane", action: #selector(AcknowledgementsWindowController.closePane(_:)),
            keyEquivalent: "w")
        #expect(first.validateMenuItem(close))
        #expect(close.title == "Close Acknowledgements")
    }

    /// ⌘W (File › Close Pane) closes the window and reports it.
    @Test func closePaneClosesTheWindow() throws {
        _ = NSApplication.shared
        let controller = AcknowledgementsWindowController(text: "text")
        var closed = false
        controller.onClose = { closed = true }
        controller.closePane(nil)
        #expect(closed)
    }
}
