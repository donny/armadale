import ArmadaleCore
import SwiftUI

/// The New Session chooser (DESIGN §8, "New sessions"): what an empty pane
/// shows in place of a terminal. A card over the pane's background, like
/// the *Session Ended* placeholder (``SessionPlaceholderView``): the heading,
/// the favorites (a click starts one; a drag onto another row reorders
/// them; a right-click offers Edit…, Move Up, Move Down and Remove; a
/// broken one is dimmed with its reason and does not start), and Cancel and
/// New Session…. The decisions are ``NewSessionChooser``'s; keys reach it
/// through ``EmptyPaneView``.
struct NewSessionPaneView: View {
    let chooser: NewSessionChooser
    /// A click on the pane around the card focuses the pane, as a click on
    /// a terminal does (and so gives it the arrow keys, Return and Escape).
    var focusPane: () -> Void = {}

    static let emptyHint = "No favorites yet. New Session… starts one and can save it as a favorite."

    var body: some View {
        GeometryReader { proxy in
            let compact = PaneCard.isCompact(width: proxy.size.width)
            ZStack {
                Rectangle()
                    .fill(.clear)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: focusPane)
                card(compact: compact, tiny: PaneCard.isTiny(width: proxy.size.width))
                    .modifier(PaneCard(compact: compact))
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private func card(compact: Bool, tiny: Bool) -> some View {
        VStack(spacing: compact ? 6 : 10) {
            if !compact {
                Image(systemName: "plus.rectangle")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
            }
            Text("New Session")
                .font(compact ? .headline : .title2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if chooser.favorites.isEmpty {
                Text(Self.emptyHint)
                    .font(compact ? .callout : .body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                favoriteList(compact: compact)
                    .padding(.top, compact ? 0 : 4)
            }
            // The full labels when they fit, else "New…", else stacked.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    cancelButton
                    newSessionButton("New Session…")
                }
                HStack(spacing: 8) {
                    cancelButton
                    newSessionButton("New…")
                }
                VStack(spacing: 6) {
                    cancelButton
                    newSessionButton("New…")
                }
            }
            .controlSize(tiny ? .small : (compact ? .regular : .large))
            .padding(.top, compact ? 4 : 8)
        }
    }

    private var cancelButton: some View {
        Button("Cancel", action: chooser.cancel)
            .help("Close this pane")
            .fixedSize()
    }

    /// New Session… looks like the default button while Return would press
    /// it (this pane takes keys and no favorite is selected). Return itself
    /// reaches the chooser through ``EmptyPaneView/keyDown(with:)``, not a
    /// key equivalent, so no other pane's Return can press it.
    @ViewBuilder private func newSessionButton(_ title: String) -> some View {
        let button = Button(title, action: chooser.newSession)
            .help("New Session…: choose where and what to run")
            .fixedSize()
        if chooser.isKeyTarget && chooser.returnOpensDialog {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    /// The rows as they are when they fit, else in a scroll view that
    /// follows the selection.
    private func favoriteList(compact: Bool) -> some View {
        ViewThatFits(in: .vertical) {
            rows(compact: compact)
            ScrollViewReader { proxy in
                ScrollView {
                    rows(compact: compact)
                }
                .scrollIndicators(.automatic)
                .onChange(of: chooser.selection) { _, selection in
                    guard let selection else { return }
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(selection) }
                }
            }
        }
    }

    private func rows(compact: Bool) -> some View {
        VStack(spacing: 2) {
            ForEach(chooser.favorites) { favorite in
                FavoriteChoiceRow(
                    chooser: chooser,
                    favorite: favorite,
                    problem: chooser.problem(of: favorite),
                    isSelected: chooser.selectedFavoriteID == favorite.id,
                    compact: compact)
                .id(favorite.id)
            }
        }
    }
}

/// One favorite in the chooser: its profile's icon, its name, and where it
/// runs (a host badge with the host's name for a remote one, and the
/// directory), or why it cannot start. A click starts it (a broken one
/// does nothing); it can be dragged onto another row, whose place it takes,
/// as a tab does in the tab bar; its context menu and accessibility actions
/// edit, move and remove it.
private struct FavoriteChoiceRow: View {
    let chooser: NewSessionChooser
    let favorite: Favorite
    let problem: String?
    let isSelected: Bool
    /// A narrow pane: the name and the reason on one line each, no host or
    /// directory line, less padding.
    let compact: Bool
    @State private var isHovering = false
    /// Where a favorite dragged over this row would land, while one is.
    @State private var dropEdge: NewSessionChooser.DropEdge?

    private var model: AppModel { chooser.model }

    var body: some View {
        let id = favorite.id
        let canMoveUp = chooser.canMove(id, by: -1)
        let canMoveDown = chooser.canMove(id, by: 1)
        HStack(spacing: compact ? 6 : 10) {
            Image(systemName: problem == nil
                ? ProfileIcon.symbol(model.profile(favorite.request.profileID)?.icon ?? "")
                : "exclamationmark.triangle")
                .font(.system(size: compact ? 13 : 15))
                .foregroundStyle(.secondary)
                .frame(width: compact ? 16 : 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(favorite.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let problem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if !compact {
                    HStack(spacing: 5) {
                        if let host {
                            HostBadge(hosts: [host], persistenceNote: nil, showsName: true)
                        }
                        Text(directory)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, compact ? 6 : 10)
        .padding(.vertical, compact ? 4 : 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .opacity(problem == nil ? 1 : 0.55)
        .overlay(alignment: dropEdge == .below ? .bottom : .top) {
            if dropEdge != nil {
                // Where the dragged favorite lands, as the tab bar's bar.
                Capsule().fill(Color.accentColor)
                    .frame(height: 2)
                    .padding(.horizontal, 4)
                    .offset(y: dropEdge == .below ? 2 : -2)
            }
        }
        .onHover { isHovering = $0 }
        .onTapGesture {
            guard problem == nil else { return }
            chooser.start(id)
        }
        .draggable(FavoriteDragItem.dragging(id)) {
            Label(favorite.name, systemImage: "star")
                .padding(6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
        .dropDestination(for: FavoriteDragItem.self) { items, _ in
            dropEdge = nil
            return chooser.drop(items, onto: id)
        } isTargeted: { targeted in
            dropEdge = targeted ? FavoriteDragItem.lastDragged.flatMap {
                NewSessionChooser.dropEdge(of: $0, onto: id, in: chooser.favorites.map(\.id))
            } : nil
        }
        .contextMenu {
            Button("Edit…") { chooser.edit(id) }
            Divider()
            Button("Move Up") { chooser.move(id, by: -1) }
                .disabled(!canMoveUp)
            Button("Move Down") { chooser.move(id, by: 1) }
                .disabled(!canMoveDown)
            Divider()
            Button("Remove") { chooser.remove(id) }
        }
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(problem == nil ? .isButton : [])
        .accessibilityAction {
            guard problem == nil else { return }
            chooser.start(id)
        }
        .accessibilityAction(named: "Edit…") { chooser.edit(id) }
        .accessibilityActions {
            if canMoveUp { Button("Move Up") { chooser.move(id, by: -1) } }
            if canMoveDown { Button("Move Down") { chooser.move(id, by: 1) } }
        }
        .accessibilityAction(named: "Remove") { chooser.remove(id) }
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(0.25) }
        if isHovering && problem == nil { return Color.primary.opacity(0.07) }
        return .clear
    }

    private var help: String {
        if let problem {
            return "“\(favorite.name)” can’t start: \(problem). Right-click to edit, move or remove it."
        }
        return "Start “\(favorite.name)”"
    }

    /// The host of a remote favorite, if it still exists.
    private var host: ArmadaleCore.Host? {
        guard case .remote(let id) = favorite.request.location else { return nil }
        return model.host(id)
    }

    /// The directory, `~` for home; a local one with the home folder
    /// abbreviated, a remote one as typed (it is the host's).
    private var directory: String {
        let trimmed = favorite.request.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = trimmed.isEmpty ? "~" : trimmed
        guard case .local = favorite.request.location else { return shown }
        return ProfileIcon.abbreviatingHome(shown, home: model.defaultWorkingDirectory)
    }
}

/// The card the chooser and the *Session Ended* placeholder put over a
/// pane: material, rounded, shadowed, at most 440 pt wide. In a narrow
/// pane (``isCompact(width:)``) its padding shrinks from 32 pt inside and
/// 24 pt outside to 12 and 8, so a split three times still has room for
/// its text (the views drop their big icon and shorten labels too).
struct PaneCard: ViewModifier {
    let compact: Bool

    /// Below this pane width the card is compact.
    static let compactWidth: CGFloat = 340

    static func isCompact(width: CGFloat) -> Bool {
        width < compactWidth
    }

    /// Below this pane width buttons are small as well.
    static func isTiny(width: CGFloat) -> Bool {
        width < 180
    }

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, compact ? 12 : 32)
            .padding(.vertical, compact ? 14 : 26)
            .frame(maxWidth: 440)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: compact ? 10 : 14, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: compact ? 10 : 18, y: compact ? 3 : 6)
            .padding(compact ? 8 : 24)
    }
}
