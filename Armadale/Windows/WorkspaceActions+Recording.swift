import AppKit
import ArmadaleCore
import ArmadaleSessions
import Observation

/// How the Record Pane… save panel and the alert about a recording are
/// put up and taken down (``WorkspaceActions/recordPanelPresenter``).
struct RecordPanelPresenter {
    var present: @MainActor (NSSavePanel, NSWindow, @escaping @MainActor (NSApplication.ModalResponse) -> Void) -> Void
    var dismiss: @MainActor (NSSavePanel) -> Void
    var presentAlert: @MainActor (NSAlert, NSWindow, @escaping @MainActor () -> Void) -> Void
    var dismissAlert: @MainActor (NSAlert) -> Void

    /// A sheet on the window, as the app shows it.
    static let sheet = RecordPanelPresenter(
        present: { panel, window, completion in
            panel.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { completion(response) }
            }
        },
        dismiss: { panel in
            panel.sheetParent?.endSheet(panel, returnCode: .cancel)
        },
        presentAlert: { alert, window, completion in
            alert.beginSheetModal(for: window) { _ in
                MainActor.assumeIsolated { completion() }
            }
        },
        dismissAlert: { alert in
            alert.window.sheetParent?.endSheet(alert.window)
        })
}

/// The Record Pane… save sheet that is up on a window.
struct RecordSheet {
    let panel: NSSavePanel
    /// The session whose pane is to be recorded.
    let session: SessionID
    /// Takes the sheet down when the pane leaves this window.
    let watch: Task<Void, Never>
}

/// Recording a pane, the window's part (docs/DESIGN.md section 8,
/// "Recording a pane"): the save sheet Record Pane… opens, and the alert
/// when a recording cannot start or stops because its file cannot be
/// written.
extension WorkspaceActions {
    /// Record Pane… from the menu of `session`'s pane: a save panel as a
    /// sheet on this window, suggesting "<pane title> <date> at <time>.cast"
    /// (``RecordingFileName``); the recording starts when it is confirmed.
    /// Does nothing while a sheet is up, without a window, or when the pane
    /// has no live terminal to record
    /// (``SessionController/canStartRecording``). The sheet goes when the
    /// pane leaves the window (closed, or its tab moved to another
    /// workspace), when the window closes and before a quit
    /// (``endRecordSheet()``); then nothing is recorded.
    func recordPane(session: SessionID) {
        guard recordSheet == nil, newSessionForm == nil, canPresentSheet(), let window, window.attachedSheet == nil,
              let controller = registry.controllers[session], controller.canStartRecording
        else { return }
        rename.commit()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = RecordingFileName.suggested(
            title: registry.displayName(of: controller.session), date: Date())
        panel.allowedContentTypes = [RecordingFileName.contentType]
        panel.allowsOtherFileTypes = false
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        panel.prompt = "Record"
        recordSheet = RecordSheet(panel: panel, session: session, watch: watchRecordSheet(of: session))
        recordPanelPresenter.present(panel, window) { [weak self] response in
            self?.recordSheetEnded(panel, response: response)
        }
    }

    /// Whether the pane of `session` is still in this window: the sheet is
    /// about it.
    static func recordSheetIsWanted(for session: SessionID, in model: AppModel, workspace: WorkspaceID) -> Bool {
        model.place(of: session)?.workspace == workspace
    }

    private func watchRecordSheet(of session: SessionID) -> Task<Void, Never> {
        let model = model
        let workspaceID = workspaceID
        return Task { [weak self] in
            let wanted = Observations { WorkspaceActions.recordSheetIsWanted(for: session, in: model, workspace: workspaceID) }
            for await isWanted in wanted where !isWanted {
                self?.endRecordSheet()
                return
            }
        }
    }

    /// The save panel ended: Record starts the recording; Cancel, or a
    /// sheet taken down by ``endRecordSheet()``, starts nothing.
    private func recordSheetEnded(_ panel: NSSavePanel, response: NSApplication.ModalResponse) {
        guard let sheet = recordSheet, sheet.panel === panel else { return }
        recordSheet = nil
        sheet.watch.cancel()
        guard response == .OK, let url = panel.url else { return }
        do {
            try registry.startRecording(session: sheet.session, to: url)
        } catch {
            registry.queueRecordingProblem(.couldNotStart(error), workspace: workspaceID)
        }
    }

    /// Takes the save sheet down, if one is up, without recording, and the
    /// alert about a recording: a quit (``AppDelegate/prepareForQuit()``),
    /// the window closing, the pane leaving the window.
    func endRecordSheet() {
        if let sheet = recordSheet {
            recordSheet = nil
            sheet.watch.cancel()
            recordPanelPresenter.dismiss(sheet.panel)
        }
        if let (alert, onEnd) = recordingAlert {
            // Taken down, not answered: the next problem waits for a window.
            recordingAlert = nil
            recordPanelPresenter.dismissAlert(alert)
            onEnd(false)
        }
    }

    /// Says why a recording could not start, or why it stopped, in a sheet
    /// on this window; `onEnd` is called when it goes, with whether the
    /// next one may be shown (not when it was taken down by
    /// ``endRecordSheet()``). The registry shows one at a time
    /// (``SessionRegistry/showNextRecordingProblem(preferring:)``).
    func showRecordingProblem(_ problem: RecordingProblem, onEnd: @escaping (Bool) -> Void) {
        guard let window, recordingAlert == nil else {
            onEnd(false)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = problem.message
        alert.informativeText = problem.informative
        alert.addButton(withTitle: "OK")
        recordingAlert = (alert, onEnd)
        recordPanelPresenter.presentAlert(alert, window) { [weak self, weak alert] in
            guard let self, let current = self.recordingAlert, current.alert === alert else { return }
            self.recordingAlert = nil
            current.onEnd(true)
        }
    }
}
