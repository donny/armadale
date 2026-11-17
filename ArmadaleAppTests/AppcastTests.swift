import Foundation
import Testing

/// The update feed, docs/appcast.xml (docs/DESIGN.md section 8, "Updates";
/// README, "Releasing"). Every build that ships reads it, and
/// scripts/appcast.sh adds an item per release, so these hold its form:
/// well-formed RSS with Sparkle's namespace, items newest first, each with
/// a version and build, a minimum macOS, embedded release notes without
/// script or external resources, the changelog as the full notes, and an
/// https enclosure on the GitHub release asset with its length and EdDSA
/// signature; never the persistence helper's runtime name. The feed with
/// no item at all passes.
@Suite("Update feed")
struct AppcastTests {
    private static let feedURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/appcast.xml")

    private static let sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"

    struct Item: Equatable {
        var version: String
        var build: Int
    }

    struct Problem: Error, CustomStringConvertible {
        var description: String
    }

    /// Checks a feed's text and returns its items in order; throws the
    /// first problem.
    static func validate(_ text: String) throws -> [Item] {
        if text.lowercased().contains("zmx") { throw Problem(description: "names the runtime") }
        let document = try XMLDocument(xmlString: text, options: [])
        guard let rss = document.rootElement(), rss.name == "rss",
              rss.attribute(forName: "version")?.stringValue == "2.0"
        else { throw Problem(description: "not RSS 2.0") }
        guard rss.namespace(forPrefix: "sparkle")?.stringValue == sparkle else {
            throw Problem(description: "no sparkle namespace")
        }
        let channels = rss.elements(forName: "channel")
        guard channels.count == 1, let channel = channels.first else { throw Problem(description: "one channel") }
        var items: [Item] = []
        for element in channel.elements(forName: "item") {
            func text(_ name: String) -> String? {
                element.elements(forLocalName: name, uri: sparkle).first?.stringValue
            }
            guard let version = text("shortVersionString"),
                  version.wholeMatch(of: /\d+\.\d+\.\d+/) != nil
            else { throw Problem(description: "an item without X.Y.Z shortVersionString") }
            guard let build = text("version").flatMap(Int.init) else {
                throw Problem(description: "\(version): no numeric sparkle:version")
            }
            guard let minimum = text("minimumSystemVersion"), minimum.wholeMatch(of: /\d+(\.\d+)*/) != nil else {
                throw Problem(description: "\(version): no minimumSystemVersion")
            }
            guard text("fullReleaseNotesLink") == "https://armadale.dev/changelog.html" else {
                throw Problem(description: "\(version): fullReleaseNotesLink")
            }
            guard element.elements(forName: "title").first?.stringValue == "Armadale \(version)" else {
                throw Problem(description: "\(version): title")
            }
            guard let date = element.elements(forName: "pubDate").first?.stringValue, rfc822(date) != nil else {
                throw Problem(description: "\(version): pubDate")
            }
            guard let notes = element.elements(forName: "description").first?.stringValue,
                  notes.contains("<h3>")
            else { throw Problem(description: "\(version): no embedded release notes") }
            let lowered = notes.lowercased()
            for banned in ["<script", "<style", "<img", "<link", "<iframe", "<object", "<embed", "src=", "url("]
            where lowered.contains(banned) {
                throw Problem(description: "\(version): release notes contain \(banned)")
            }
            let enclosures = element.elements(forName: "enclosure")
            guard enclosures.count == 1, let enclosure = enclosures.first else {
                throw Problem(description: "\(version): one enclosure")
            }
            let expected = "https://github.com/donny/armadale/releases/download/v\(version)/Armadale-\(version).dmg"
            guard enclosure.attribute(forName: "url")?.stringValue == expected else {
                throw Problem(description: "\(version): enclosure URL")
            }
            guard let length = enclosure.attribute(forName: "length")?.stringValue.flatMap(Int.init), length > 0 else {
                throw Problem(description: "\(version): enclosure length")
            }
            guard let signature = enclosure.attribute(forLocalName: "edSignature", uri: sparkle)?.stringValue,
                  Data(base64Encoded: signature)?.count == 64
            else { throw Problem(description: "\(version): edSignature") }
            if let last = items.last, build >= last.build {
                throw Problem(description: "\(version): not newest first (build \(build) after \(last.build))")
            }
            items.append(Item(version: version, build: build))
        }
        return items
    }

    static func rfc822(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.date(from: text)
    }

    @Test func theFeedHasItsForm() throws {
        let text = try String(contentsOf: Self.feedURL, encoding: .utf8)
        let items = try Self.validate(text)
        // scripts/appcast.py inserts after this line.
        #expect(text.contains("<!-- Items, newest first. -->"))
        // The served file names no internals.
        for name in ["scripts/", "Tests", "DESIGN", "Sparkle"] {
            #expect(!text.replacingOccurrences(of: "xml-namespaces/sparkle", with: "").contains(name), "\(name)")
        }
        #expect(Set(items.map(\.version)).count == items.count, "one item per version")
    }

    // MARK: The rule itself

    private static func feed(_ items: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <title>Armadale</title>
            \(items)
          </channel>
        </rss>
        """
    }

    private static let signature = Data(repeating: 7, count: 64).base64EncodedString()

    /// An item as scripts/appcast.py writes it, with notes.
    private static func item(
        version: String = "0.1.2", build: Int = 30, notes: String = "<h3>Updates</h3><p>Armadale updates itself.</p>",
        url: String? = nil, signature: String = AppcastTests.signature, length: String = "16246208"
    ) -> String {
        """
        <item>
          <title>Armadale \(version)</title>
          <pubDate>Mon, 16 Nov 2026 12:00:00 +0000</pubDate>
          <sparkle:version>\(build)</sparkle:version>
          <sparkle:shortVersionString>\(version)</sparkle:shortVersionString>
          <sparkle:minimumSystemVersion>27.0</sparkle:minimumSystemVersion>
          <description><![CDATA[\(notes)]]></description>
          <sparkle:fullReleaseNotesLink>https://armadale.dev/changelog.html</sparkle:fullReleaseNotesLink>
          <enclosure url="\(url ?? "https://github.com/donny/armadale/releases/download/v\(version)/Armadale-\(version).dmg")" length="\(length)" type="application/octet-stream" sparkle:edSignature="\(signature)"/>
        </item>
        """
    }

    @Test func theRuleAcceptsAnEmptyFeedAndGoodItems() throws {
        #expect(try Self.validate(Self.feed("")) == [])
        let two = Self.feed(Self.item(version: "0.1.3", build: 31) + Self.item())
        #expect(try Self.validate(two) == [Item(version: "0.1.3", build: 31), Item(version: "0.1.2", build: 30)])
    }

    /// scripts/appcast.py, as scripts/release.sh and scripts/appcast.sh
    /// run it (`item`, then `insert` into the feed), checked by the same
    /// rule, so the script and the rule cannot drift. The feed it inserts
    /// into is the real one as it was before its first item, so the test
    /// does not depend on which releases the real feed holds.
    @Test func theScriptWritesItemsTheRuleAccepts() throws {
        let root = Self.feedURL.deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("armadale-appcast-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let feed = directory.appendingPathComponent("appcast.xml")
        let real = try String(contentsOf: Self.feedURL, encoding: .utf8)
        let marker = try #require(real.range(of: "<!-- Items, newest first. -->"))
        try (String(real[..<marker.upperBound]) + "\n  </channel>\n</rss>\n")
            .write(to: feed, atomically: true, encoding: .utf8)
        let notes = directory.appendingPathComponent("notes.html")
        try "<p><strong>November 16, 2026</strong></p>\n<h3>Updates</h3>\n<p>Armadale updates itself.</p>"
            .write(to: notes, atomically: true, encoding: .utf8)

        func run(_ arguments: [String]) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-I", root.appendingPathComponent("scripts/appcast.py").path] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        func item(_ version: String, _ build: String) throws -> URL {
            let url = directory.appendingPathComponent("item-\(build).xml")
            let status = try run([
                "item", "--version", version, "--build", build, "--length", "16246208",
                "--signature", Self.signature, "--minimum-system", "27.0",
                "--date", "Mon, 16 Nov 2026 12:00:00 +0000", "--out", url.path,
            ])
            #expect(status == 0)
            return url
        }
        func insert(_ item: URL) throws -> Int32 {
            try run(["insert", "--feed", feed.path, "--item", item.path, "--notes", notes.path])
        }

        #expect(try insert(item("0.1.2", "30")) == 0)
        #expect(try insert(item("0.1.3", "31")) == 0)
        #expect(try insert(item("0.1.1", "29")) != 0, "an older build is refused")
        let text = try String(contentsOf: feed, encoding: .utf8)
        #expect(try Self.validate(text) == [Item(version: "0.1.3", build: 31), Item(version: "0.1.2", build: 30)])
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".appcast-") }
        #expect(left.isEmpty, "no temporary file left beside the feed")
    }

    @Test func theRuleRefusesBadItems() {
        let bad: [String] = [
            Self.feed(Self.item() + Self.item(version: "0.1.3", build: 31)),  // oldest first
            Self.feed(Self.item(url: "http://github.com/donny/armadale/releases/download/v0.1.2/Armadale-0.1.2.dmg")),
            Self.feed(Self.item(url: "https://example.com/Armadale-0.1.2.dmg")),
            Self.feed(Self.item(url: "https://github.com/donny/armadale/releases/download/v0.1.1/Armadale-0.1.2.dmg")),
            Self.feed(Self.item(signature: "")),
            Self.feed(Self.item(signature: Data(repeating: 1, count: 32).base64EncodedString())),
            Self.feed(Self.item(length: "0")),
            Self.feed(Self.item(notes: "")),
            Self.feed(Self.item(notes: "<h3>x</h3><script>alert(1)</script>")),
            Self.feed(Self.item(notes: "<h3>x</h3><img src=\"https://example.com/x.png\">")),
            Self.feed(Self.item(notes: "<h3>The zmx helper</h3>")),
            Self.feed(Self.item().replacingOccurrences(of: "<sparkle:minimumSystemVersion>27.0</sparkle:minimumSystemVersion>", with: "")),
            Self.feed(Self.item().replacingOccurrences(of: "https://armadale.dev/changelog.html", with: "https://example.com")),
            Self.feed("<item>"),
        ]
        for text in bad {
            #expect(throws: (any Error).self) { try Self.validate(text) }
        }
    }
}
