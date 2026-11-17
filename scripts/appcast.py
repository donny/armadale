#!/usr/bin/python3 -I
"""The update feed's items (docs/DESIGN.md section 11, "Release pipeline").

Shared by scripts/release.sh and scripts/appcast.sh; run with
`/usr/bin/python3 -I scripts/appcast.py <command> ...`. Standard library only.

  item    --version V --build N --length BYTES --signature SIG
          --minimum-system M --date RFC822 --out FILE
          Writes one <item> for docs/appcast.xml, without release notes.
  read    FILE
          Prints the item's fields as shell assignments (version, build,
          length, signature, minimum_system, url).
  notes   --changelog FILE --version V
          Prints the embedded release notes: the entries of that version's
          section of docs/changelog.html, as plain HTML (no style, no
          script, no external resource).
  insert  --feed FILE --item FILE --notes FILE
          Puts the item, with the notes as its <description>, at the top
          of the feed's items. Refuses a build number already in the feed
          or not higher than the newest one.
"""
import argparse
import html
import os
import re
import sys
import tempfile
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
RELEASES = "https://github.com/donny/armadale/releases/download"
CHANGELOG = "https://armadale.dev/changelog.html"
MARKER = "<!-- Items, newest first. -->"
# What a day of the changelog page holds (an allowlist): the date, a
# wrapper, the items' titles and paragraphs, and code in them. Only
# <time> has an attribute, its datetime.
ALLOWED_TAGS = {"time", "div", "h3", "p", "code"}


def fail(message):
    print(f"appcast: {message}", file=sys.stderr)
    sys.exit(1)


def dmg_url(version):
    return f"{RELEASES}/v{version}/Armadale-{version}.dmg"


def item_xml(a):
    if not re.fullmatch(r"\d+\.\d+\.\d+", a.version):
        fail(f"version {a.version!r} is not X.Y.Z")
    if not re.fullmatch(r"\d+", a.build):
        fail(f"build {a.build!r} is not a number")
    if not re.fullmatch(r"\d+", a.length) or int(a.length) <= 0:
        fail(f"length {a.length!r} is not a positive number")
    if not re.fullmatch(r"[A-Za-z0-9+/]{86}==", a.signature):
        fail("the signature is not 64 bytes of base64")
    e = html.escape
    return (
        "    <item>\n"
        f"      <title>Armadale {e(a.version)}</title>\n"
        f"      <pubDate>{e(a.date)}</pubDate>\n"
        f"      <sparkle:version>{e(a.build)}</sparkle:version>\n"
        f"      <sparkle:shortVersionString>{e(a.version)}</sparkle:shortVersionString>\n"
        f"      <sparkle:minimumSystemVersion>{e(a.minimum_system)}</sparkle:minimumSystemVersion>\n"
        f"      <sparkle:fullReleaseNotesLink>{CHANGELOG}</sparkle:fullReleaseNotesLink>\n"
        f'      <enclosure url="{e(dmg_url(a.version))}" length="{e(a.length)}" '
        f'type="application/octet-stream" sparkle:edSignature="{e(a.signature)}"/>\n'
        "    </item>\n"
    )


def parse_item(text):
    try:
        root = ET.fromstring(f'<rss xmlns:sparkle="{SPARKLE}">{text}</rss>')
    except ET.ParseError as error:
        fail(f"the item is not well-formed XML: {error}")
    item = root.find("item")
    if item is None:
        fail("no <item>")
    enclosure = item.find("enclosure")
    if enclosure is None:
        fail("the item has no <enclosure>")
    return {
        "version": item.findtext(f"{{{SPARKLE}}}shortVersionString", ""),
        "build": item.findtext(f"{{{SPARKLE}}}version", ""),
        "minimum_system": item.findtext(f"{{{SPARKLE}}}minimumSystemVersion", ""),
        "length": enclosure.get("length", ""),
        "signature": enclosure.get(f"{{{SPARKLE}}}edSignature", ""),
        "url": enclosure.get("url", ""),
    }


def notes(changelog, version):
    page = re.sub(r"<!--.*?-->", "", open(changelog, encoding="utf-8").read(), flags=re.S)
    section = re.search(
        r'<section class="release" id="v' + re.escape(version) + r'">(.*?)</section>', page, flags=re.S)
    if section is None:
        fail(f'{changelog} has no section id="v{version}" (turn "Next release" into it first)')
    entries = re.search(r'<ol class="entries">(.*?)</ol>', section.group(1), flags=re.S)
    if entries is None or "<li>" not in entries.group(1):
        fail(f"the section of {version} in {changelog} has no entries")
    out = []
    for day in re.findall(r"<li>(.*?)</li>", entries.group(1), flags=re.S):
        for name, attributes in re.findall(r"</?([A-Za-z][A-Za-z0-9]*)([^>]*)>", day):
            if name.lower() not in ALLOWED_TAGS:
                fail(f"the changelog's section of {version} has a <{name}> tag, which the feed's notes do not allow")
            attributes = attributes.strip()
            if attributes and not (name == "time" and re.fullmatch(r'datetime="\d{4}-\d{2}-\d{2}"', attributes)):
                fail(f"the changelog's section of {version} has a <{name}> tag with attributes ({attributes}), "
                     "which the feed's notes do not allow")
        shown = re.search(r"<time[^>]*>(.*?)</time>", day, flags=re.S)
        if shown:
            out.append(f"<p><strong>{shown.group(1).strip()}</strong></p>")
        for tag, body in re.findall(r"<(h3|p)>(.*?)</\1>", day, flags=re.S):
            body = " ".join(body.split())
            out.append(f"<h3>{body}</h3>" if tag == "h3" else f"<p>{body}</p>")
    text = "\n".join(out)
    if "zmx" in text.lower():
        fail("the release notes name the persistence helper's runtime")
    if "]]>" in text:
        fail("the release notes contain ]]>")
    return text


def insert(feed_path, item_text, notes_text):
    feed = open(feed_path, encoding="utf-8").read()
    if MARKER not in feed:
        fail(f"{feed_path} has no marker line: {MARKER}")
    new = parse_item(item_text)
    builds = [int(b) for b in re.findall(r"<sparkle:version>(\d+)</sparkle:version>", feed)]
    if builds and int(new["build"]) <= max(builds):
        fail(f"build {new['build']} is not newer than the feed's newest, {max(builds)}")
    description = f"      <description><![CDATA[\n{notes_text}\n      ]]></description>\n"
    marker = "      <sparkle:fullReleaseNotesLink>"
    if marker not in item_text:
        fail("the item has no fullReleaseNotesLink line")
    item_text = item_text.replace(marker, description + marker, 1)
    feed = feed.replace(MARKER, MARKER + "\n" + item_text.rstrip("\n"), 1)
    try:
        ET.fromstring(feed)
    except ET.ParseError as error:
        fail(f"the feed would not be well-formed: {error}")
    # A temporary file beside the feed, then an atomic rename over it.
    directory = os.path.dirname(os.path.abspath(feed_path))
    descriptor, temporary = tempfile.mkstemp(prefix=".appcast-", suffix=".xml", dir=directory)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(feed)
        os.chmod(temporary, 0o644)
        os.replace(temporary, feed_path)
    except BaseException:
        if os.path.exists(temporary):
            os.unlink(temporary)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    p = commands.add_parser("item")
    for name in ("version", "build", "length", "signature", "minimum-system", "date", "out"):
        p.add_argument(f"--{name}", required=True)
    p = commands.add_parser("read")
    p.add_argument("file")
    p = commands.add_parser("notes")
    p.add_argument("--changelog", required=True)
    p.add_argument("--version", required=True)
    p = commands.add_parser("insert")
    for name in ("feed", "item", "notes"):
        p.add_argument(f"--{name}", required=True)
    a = parser.parse_args()

    if a.command == "item":
        text = item_xml(a)
        parse_item(text)
        open(a.out, "w", encoding="utf-8").write(text)
    elif a.command == "read":
        for key, value in parse_item(open(a.file, encoding="utf-8").read()).items():
            if not re.fullmatch(r"[A-Za-z0-9+/=.:_-]*", value.replace("https://", "").replace("/", "")):
                fail(f"unexpected characters in {key}")
            print(f"{key}='{value}'")
    elif a.command == "notes":
        print(notes(a.changelog, a.version))
    elif a.command == "insert":
        insert(a.feed, open(a.item, encoding="utf-8").read(), open(a.notes, encoding="utf-8").read().strip("\n"))


if __name__ == "__main__":
    main()
