import AppKit
import ArmadaleCore
import QuartzCore
import SwiftUI
import TerminalSurface

/// What a pane card's header shows (DESIGN §8, "Pane cards"). The pane
/// view keeps it current from the model (``SessionRegistry/headerModel(for:)``)
/// and from its appearance (``foreground``).
struct PaneHeaderModel: Equatable, Sendable {
    /// The session's glyph (◐ while it needs attention); `nil` shows none
    /// (an empty pane).
    var status: SessionStatus?
    var title: String
    /// The working directory, `~`-abbreviated; `nil` or empty shows nothing.
    var directory: String?
    /// Tints the title with ``StatusGlyph/attentionColor``.
    var needsAttention: Bool = false
    /// The pane theme's foreground, which the header uses at reduced
    /// strengths so it suits any theme.
    var foreground = TerminalColor(hex: 0x808080)
    /// The pane is being recorded: a pulsing red dot and a stop button
    /// between the text and "…" (DESIGN §8, "Recording a pane").
    var isRecording = false

    /// The title of a session's pane: the program's title (OSC 0/2), else
    /// the profile's name. A tab's custom title is the tab's, never a pane's.
    static func title(sessionTitle: String, profileName: String?) -> String {
        if !sessionTitle.isEmpty { return sessionTitle }
        return profileName ?? "Shell"
    }

    /// The directory as shown: nothing when unknown, blank, or the same as
    /// the title (a shell that titles itself with its directory, as zsh
    /// and fish do, would otherwise read "~ ~").
    var shownDirectory: String? {
        guard let directory, !directory.isEmpty, directory != title else { return nil }
        return directory
    }

    /// An empty pane's header: no glyph, "New Session".
    static let newSession = PaneHeaderModel(status: nil, title: "New Session", directory: nil)
}

/// The header row of a pane card: status glyph, title, working directory,
/// while the pane is recorded a pulsing red dot and a stop button, and the
/// "…" button that opens the pane menu (whose Split Right and Split Down
/// are the header's way to split; no split buttons, owner's decision).
/// Drawn in the pane's appearance, in the theme's foreground at reduced
/// opacity; the recording controls in the system red.
struct PaneHeaderView: View {
    var model: PaneHeaderModel
    /// The "…" button was pressed.
    var openMenu: () -> Void = {}
    /// The stop button was pressed.
    var stopRecording: () -> Void = {}

    private var title: some View {
        Text(model.title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(model.needsAttention
                ? AnyShapeStyle(StatusGlyph.attentionColor)
                : AnyShapeStyle(Color(nsColor: PaneCardStyle.nsColor(model.foreground)).opacity(PaneCardStyle.titleOpacity)))
            .lineLimit(1)
            .truncationMode(.middle)
    }

    var body: some View {
        // What the header's width holds, in the order things give way
        // (``PaneCardStyle/headerParts(width:hasGlyph:isRecording:)``).
        GeometryReader { proxy in
            row(PaneCardStyle.headerParts(
                width: proxy.size.width, hasGlyph: model.status != nil, isRecording: model.isRecording))
        }
        .contentShape(Rectangle())
    }

    private func row(_ parts: PaneCardStyle.HeaderParts) -> some View {
        let foreground = Color(nsColor: PaneCardStyle.nsColor(model.foreground))
        return HStack(spacing: 0) {
            if parts.glyph, let status = model.status {
                StatusGlyph(status: status)
                Color.clear.frame(width: PaneCardStyle.textSpacing, height: 1)
            }
            if parts.title {
                // The title and the directory share the width the row
                // leaves them by ``PaneCardStyle/headerTextWidths(available:title:directory:)``.
                HeaderTextLayout {
                    title
                    if let directory = model.shownDirectory {
                        Text(directory)
                            .font(.system(size: 12))
                            .foregroundStyle(foreground.opacity(PaneCardStyle.directoryOpacity))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            // Dropped by the layout (no width) without a stray "…".
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                            .clipped()
                    }
                }
            }
            Spacer(minLength: PaneCardStyle.headerGap(parts))
            if parts.dot {
                PulsingDot()
                    .frame(width: PaneCardStyle.recordingDotFrameWidth, height: PaneCardStyle.recordingDotFrameWidth)
                    .help("Recording")
                    .accessibilityElement()
                    .accessibilityLabel("Recording")
                Color.clear.frame(width: PaneCardStyle.recordingControlsSpacing, height: 1)
            }
            if parts.stop {
                StopRecordingButton(stop: stopRecording)
                Color.clear.frame(width: PaneCardStyle.textSpacing, height: 1)
            }
            PaneHeaderButton(symbol: "ellipsis", label: "Pane Menu", foreground: foreground, action: openMenu)
        }
        .padding(.leading, PaneCardStyle.headerLeading)
        .padding(.trailing, PaneCardStyle.headerTrailing)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A header button (today only "…"): a symbol in the theme's foreground at
/// ``PaneCardStyle/headerButtonOpacity``, full strength under the pointer,
/// with its label as tooltip.
private struct PaneHeaderButton: View {
    let symbol: String
    let label: String
    let foreground: Color
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: PaneCardStyle.headerButtonSize.width, height: PaneCardStyle.headerButtonSize.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(foreground.opacity(
            isHovering ? PaneCardStyle.headerButtonHoverOpacity : PaneCardStyle.headerButtonOpacity))
        .onHover { isHovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The stop button of a recording pane, in the system red.
private struct StopRecordingButton: View {
    let stop: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: stop) {
            Image(systemName: "stop.fill")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: PaneCardStyle.stopButtonSize.width, height: PaneCardStyle.stopButtonSize.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(nsColor: .systemRed).opacity(isHovering ? 1 : 0.85))
        .onHover { isHovering = $0 }
        .help("Stop Recording")
        .accessibilityLabel("Stop Recording")
    }
}

/// The recording dot: a red circle whose opacity pulses as a Core Animation
/// animation on its layer, which the render server runs with no SwiftUI
/// update per frame. The view is kept when the header's root view is
/// replaced (a title or directory change), so the pulse goes on; it is
/// added again when the view comes back into a window, and the dot is
/// steady with Reduce Motion, following a change of that setting.
private struct PulsingDot: NSViewRepresentable {
    func makeNSView(context: Context) -> PulsingDotView { PulsingDotView() }
    func updateNSView(_ view: PulsingDotView, context: Context) {}
}

/// The view behind ``PulsingDot``.
final class PulsingDotView: NSView {
    static let animationKey = "armadale.recording-pulse"
    private var observer: (any NSObjectProtocol)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: PaneCardStyle.recordingDotFrameWidth, height: PaneCardStyle.recordingDotFrameWidth))
        wantsLayer = true
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePulse() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    isolated deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let size = PaneCardStyle.recordingDotSize
        let rect = NSRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: rect).fill()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updatePulse()
    }

    /// Whether the dot pulses now.
    var isPulsing: Bool { layer?.animation(forKey: Self.animationKey) != nil }

    /// Adds the pulse, or takes it away (out of a window, Reduce Motion).
    func updatePulse() {
        guard let layer else { return }
        let steady = window == nil || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if steady {
            layer.removeAnimation(forKey: Self.animationKey)
        } else if layer.animation(forKey: Self.animationKey) == nil {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = RecordingPulse.minimum
            pulse.duration = RecordingPulse.period / 2
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pulse.isRemovedOnCompletion = false
            layer.add(pulse, forKey: Self.animationKey)
        }
    }
}

/// The recording dot's pulse: its opacity swings between full and
/// ``minimum`` and back every ``period`` seconds.
enum RecordingPulse {
    static let period: Double = 1.6
    static let minimum: Float = 0.25
}

/// Lays out a header's title and, if any, its working directory side by
/// side, in the widths ``PaneCardStyle/headerTextWidths(available:title:directory:)``
/// gives; a dropped directory gets no width.
struct HeaderTextLayout: Layout {
    private func ideal(_ subviews: Subviews) -> (title: CGFloat, directory: CGFloat?, height: CGFloat) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return (sizes.first?.width ?? 0, sizes.count > 1 ? sizes[1].width : nil, sizes.map(\.height).max() ?? 0)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = ideal(subviews)
        let whole = ideal.title + (ideal.directory.map { $0 + PaneCardStyle.textSpacing } ?? 0)
        let width = proposal.width.map { min($0, whole) } ?? whole
        return CGSize(width: width, height: proposal.height.map { min($0, ideal.height) } ?? ideal.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let ideal = ideal(subviews)
        let widths = PaneCardStyle.headerTextWidths(
            available: bounds.width, title: ideal.title, directory: ideal.directory)
        guard let title = subviews.first else { return }
        title.place(
            at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
            proposal: ProposedViewSize(width: widths.title, height: bounds.height))
        guard subviews.count > 1 else { return }
        let x = bounds.minX + widths.title + PaneCardStyle.textSpacing
        subviews[1].place(
            at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
            proposal: ProposedViewSize(width: widths.directory ?? 0, height: bounds.height))
    }
}

/// Hosts a card's ``PaneHeaderView`` in a ``PaneView`` or ``EmptyPaneView``.
/// The header is the pane's own, never the program's: a click on it focuses
/// the pane (as a click on the padding does), the "…" button opens the pane menu below itself, and a right-click (or Control-click) anywhere on it
/// opens the same menu at the pointer. Nothing here reaches the terminal or
/// the chooser below, which lie outside the header's frame.
@MainActor
final class PaneHeaderHostingView: NSHostingView<PaneHeaderView> {
    /// Focuses the pane (``PaneView/focusTerminal()``, ``EmptyPaneView/focusPane()``).
    var focusPane: () -> Void = {}
    /// The pane's menu, built fresh (``PaneView/paneMenu()``).
    var makeMenu: () -> NSMenu? = { nil }
    /// Shows the "…" button's menu at a point of this view. Popping a menu
    /// up runs a modal loop, so tests replace it.
    var presentMenu: (NSMenu, NSPoint, NSView) -> Void = { menu, point, view in
        menu.popUp(positioning: nil, at: point, in: view)
    }
    /// The stop button of a recording pane (``PaneView`` stops its
    /// controller's recording).
    var stopRecording: () -> Void = {}
    /// Shows the right-click menu for an event; replaced in tests.
    var presentContextMenu: (NSMenu, NSEvent, NSView) -> Void = { menu, event, view in
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    /// What the header shows; setting a different one redraws it.
    var model: PaneHeaderModel {
        get { rootView.model }
        set {
            guard newValue != rootView.model else { return }
            var view = rootView
            view.model = newValue
            rootView = view
        }
    }

    /// A header showing `model`, wired to its own menu button.
    static func make(model: PaneHeaderModel) -> PaneHeaderHostingView {
        let header = PaneHeaderHostingView(rootView: PaneHeaderView(model: model))
        header.sizingOptions = []
        header.rootView = PaneHeaderView(
            model: model,
            openMenu: { [weak header] in header?.openMenuFromButton() },
            stopRecording: { [weak header] in header?.stopRecording() })
        return header
    }

    /// The "…" button: focus the pane, then the menu as a pull-down under
    /// the button.
    func openMenuFromButton() {
        focusPane()
        guard let menu = makeMenu() else { return }
        var origin = PaneCardStyle.menuOrigin(
            inHeaderOf: bounds.size, menuWidth: menu.size.width, roomRightOfHeader: roomRightOfHeader)
        if !isFlipped { origin.y = bounds.height - origin.y }
        presentMenu(menu, origin, self)
    }

    /// The width of the window's content right of this header's trailing
    /// edge (the gutter, or another pane), so the "…" menu can stay inside
    /// the window.
    private var roomRightOfHeader: CGFloat {
        guard let content = window?.contentView else { return .infinity }
        let trailing = convert(NSPoint(x: bounds.maxX, y: bounds.midY), to: content).x
        return max(content.bounds.maxX - trailing, 0)
    }

    override func mouseDown(with event: NSEvent) {
        focusPane()
        super.mouseDown(with: event)
    }

    /// Right-click: focus the pane, then the menu at the pointer.
    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menu(for: event) else { return }
        presentContextMenu(menu, event, self)
    }

    /// AppKit asks for it on a Control-click (and accessibility's Show
    /// Menu); the pane is focused first, as a click would.
    override func menu(for event: NSEvent) -> NSMenu? {
        focusPane()
        return makeMenu()
    }
}
