import AppKit

/// The content side of a workspace window. Step 1 placeholder: the tab bar
/// and pane container arrive in later steps.
@MainActor
final class ContentViewController: NSViewController {
    override func loadView() {
        let container = NSView()
        let label = NSTextField(labelWithString: "No terminal yet")
        label.font = .preferredFont(forTextStyle: .title2)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        view = container
    }
}
