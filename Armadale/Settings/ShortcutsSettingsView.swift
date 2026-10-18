import SwiftUI

/// Settings › Shortcuts: the read-only table of key equivalents, generated
/// from the menu bar (``ShortcutTable``).
struct ShortcutsSettingsView: View {
    let rows: [ShortcutTable.Row]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Table(rows) {
                TableColumn("Command", value: \.command)
                TableColumn("Shortcut") { row in
                    Text(row.shortcut).monospacedDigit()
                }
                .width(min: 90, ideal: 130)
                TableColumn("Menu", value: \.menu)
                    .width(min: 70, ideal: 90)
            }
            Text("Armadale’s own shortcuts; every command is also in the menu bar. Shortcuts can’t be changed yet. Other keys go to the terminal, apart from system shortcuts such as window tiling.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }
}
