import Foundation
import Testing

/// The website's changelog, docs/changelog.html (AGENTS.md, "The changelog
/// page"). The page is edited by hand in every change a user would notice,
/// so these hold its form: releases newest first, one entry per day and the
/// days newest first, dates that exist and are written out, one release
/// marked as the latest, and never the name of the persistence helper's
/// runtime on the site.
@Suite("Changelog page")
struct ChangelogPageTests {
    private static let docs = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs")

    private static func page(_ name: String) throws -> String {
        try String(contentsOf: docs.appendingPathComponent(name), encoding: .utf8)
    }

    /// A `<time>` as the page has it.
    private struct Day: Equatable {
        /// The `datetime` attribute, `2026-11-16`.
        var iso: String
        /// The text shown, "November 16, 2026".
        var shown: String
    }

    /// A `<section class="release">`.
    private struct Release {
        var id: String
        var heading: String
        var isLatest: Bool
        /// The `<time>`s of the heading: the release date, or none for "Next release".
        var released: [Day]
        /// The `<time>`s of the entries, in page order.
        var days: [Day]
        /// How many `<li>` the entries list has.
        var entryCount: Int

        var isNext: Bool { id == "next" }
    }

    private static func days(in html: Substring) throws -> [Day] {
        let time = try Regex(#"<time datetime="([^"]*)">([^<]*)</time>"#)
        return html.matches(of: time).compactMap { match in
            guard let iso = match.output[1].substring, let shown = match.output[2].substring else { return nil }
            return Day(iso: String(iso), shown: String(shown))
        }
    }

    /// The page's release sections in page order. Comments are dropped
    /// first: the one at the top of `<main>` holds markup to copy.
    private static func releases() throws -> [Release] {
        let html = try page("changelog.html").replacing(try Regex(#"<!--[\s\S]*?-->"#), with: "")
        let id = try Regex(#" id="([^"]*)""#)
        let heading = try Regex(#"<h2>([^<]*)</h2>"#)
        return try html.split(separator: "<section class=\"release\"", omittingEmptySubsequences: false)
            .dropFirst()
            .map { section in
                let parts = section.split(separator: "<ol class=\"entries\">", omittingEmptySubsequences: false)
                try #require(parts.count == 2, "a release has one <ol class=\"entries\">")
                let (head, entries) = (parts[0], parts[1])
                return Release(
                    id: String(try #require(head.firstMatch(of: id)?.output[1].substring, "a release has an id")),
                    heading: String(try #require(head.firstMatch(of: heading)?.output[1].substring, "a release has an <h2>")),
                    isLatest: head.contains("class=\"pill latest\""),
                    released: try days(in: head),
                    days: try days(in: entries),
                    entryCount: entries.split(separator: "<li>", omittingEmptySubsequences: false).count - 1)
            }
    }

    /// `0.1.2` as `[0, 1, 2]`; nil for anything else.
    private static func version(_ heading: String) -> [Int]? {
        let parts = heading.split(separator: "." as Character, omittingEmptySubsequences: false)
        let numbers = parts.compactMap { $0.allSatisfy(\.isASCII) ? UInt($0).map(Int.init) : nil }
        return parts.count == 3 && numbers.count == 3 ? numbers : nil
    }

    /// "November 16, 2026" for `2026-11-16`; nil when that is no date.
    private static func writtenOut(_ iso: String) -> String? {
        let parts = iso.split(separator: "-" as Character, omittingEmptySubsequences: false)
        guard iso.count == 10, parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let components = DateComponents(calendar: calendar, year: year, month: month, day: day)
        guard components.isValidDate, let date = components.date else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = .gmt
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter.string(from: date)
    }

    @Test func releasesAreNewestFirstWithNextReleaseOnTop() throws {
        let releases = try Self.releases()
        #expect(!releases.isEmpty)
        #expect(releases.dropFirst().allSatisfy { !$0.isNext }, "only the first section can be Next release")

        if let first = releases.first, first.isNext {
            #expect(first.heading == "Next release")
            #expect(first.released.isEmpty, "Next release has no date beside its heading")
            #expect(!first.isLatest)
        }

        let released = releases.filter { !$0.isNext }
        for release in released {
            #expect(Self.version(release.heading) != nil, "“\(release.heading)” is not a version")
            #expect(release.id == "v" + release.heading)
            #expect(release.released.count == 1, "\(release.heading) has its release date beside the heading")
        }
        let versions = released.compactMap { Self.version($0.heading) }
        for (newer, older) in zip(versions, versions.dropFirst()) {
            #expect(older.lexicographicallyPrecedes(newer), "\(older) is below \(newer)")
        }
        #expect(released.map(\.isLatest) == released.indices.map { $0 == 0 }, "the newest release, and no other, is the latest")
    }

    @Test func daysAreWrittenOutAndNewestFirst() throws {
        let releases = try Self.releases()
        for day in releases.flatMap({ $0.released + $0.days }) {
            #expect(Self.writtenOut(day.iso) == day.shown, "\(day.iso) is shown as “\(day.shown)”")
        }
        for release in releases {
            #expect(!release.days.isEmpty, "\(release.heading) has no entries")
            #expect(release.days.count == release.entryCount, "every entry of \(release.heading) has one <time>")
            for (newer, older) in zip(release.days, release.days.dropFirst()) {
                #expect(newer.iso > older.iso, "\(release.heading): one entry per day, newest first (\(older.iso) after \(newer.iso))")
            }
            if let date = release.released.first, let newest = release.days.first {
                #expect(newest.iso <= date.iso, "\(release.heading) was released \(date.iso), before its entry of \(newest.iso)")
            }
        }
        // What a section holds was finished after the release below it.
        for (newer, older) in zip(releases, releases.dropFirst()) {
            if let oldest = newer.days.last, let date = older.released.first {
                #expect(oldest.iso >= date.iso, "\(newer.heading) holds \(oldest.iso), from before \(older.heading) of \(date.iso)")
            }
        }
    }

    @Test func theSiteNeverNamesThePersistenceRuntime() throws {
        for name in ["index.html", "changelog.html"] {
            let text = try Self.page(name).lowercased()
            #expect(!text.contains("zmx"), "\(name) names the runtime")
        }
    }

    @Test func thePagesLinkToEachOther() throws {
        let home = try Self.page("index.html")
        let changelog = try Self.page("changelog.html")
        #expect(home.contains("href=\"changelog.html\""))
        #expect(changelog.contains("href=\"./\""))
    }
}
