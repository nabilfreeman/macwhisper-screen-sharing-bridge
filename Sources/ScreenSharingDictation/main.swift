import AppKit
import SQLite3

private let screenSharingBundleIdentifier = "com.apple.ScreenSharing"
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
private let clipboardPropagationDelay: TimeInterval = 1.5
private let pasteModifierDelay: TimeInterval = 0.12
private let macWhisperActivationAction: [String: Any] = [
    "BTTPredefinedActionType": 264,
    "BTTPredefinedActionName": "Send Globe Key",
    "BTTShortcutToSend": "179"
]

final class BridgeLogger {
    let fileURL: URL

    init() {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Screen Sharing Dictation", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        fileURL = directory.appendingPathComponent("bridge.log")
    }

    func write(_ message: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = "\(formatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }

        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Logging must never interrupt dictation.
        }
    }
}

final class CaptureTextView: NSTextView {
    var cancelHandler: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            cancelHandler?()
            return
        }
        super.keyDown(with: event)
    }
}

final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct BetterTouchToolStep {
    let action: [String: Any]
    let delayAfter: TimeInterval
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var panel: NSPanel!
    private var textView: CaptureTextView!
    private var titleLabel: NSTextField!
    private var subtitleLabel: NSTextField!
    private var progressIndicator: NSProgressIndicator!
    private var closeButton: NSButton!
    private var screenSharingApp: NSRunningApplication?
    private var timeoutWorkItem: DispatchWorkItem?
    private var database: OpaquePointer?
    private var databaseTimer: Timer?
    private var baselineDictationDate = ""
    private var lastLoggedDatabaseState = ""
    private let logger = BridgeLogger()
    private var finishing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.write("launch version=0.1.0")
        screenSharingApp = NSRunningApplication
            .runningApplications(withBundleIdentifier: screenSharingBundleIdentifier)
            .first

        guard screenSharingApp != nil else {
            logger.write("failure screen_sharing_not_running")
            showFatalError("Screen Sharing is not running.")
            return
        }
        logger.write("screen_sharing detected")

        buildCapturePanel()
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)

        do {
            try startDatabaseMonitor()
        } catch {
            logger.write("failure database_monitor_start error=\(error.localizedDescription)")
            showFatalError("Could not monitor MacWhisper's finished dictations.\n\n\(error.localizedDescription)")
            return
        }

        let timeout = DispatchWorkItem { [weak self] in
            self?.cancelCapture(reason: "timeout")
        }
        timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 180, execute: timeout)

        // Give the capture field enough time to become the active text input,
        // then ask BetterTouchTool to invoke MacWhisper's existing shortcut.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, !self.finishing else { return }
            do {
                try self.runBetterTouchToolAction(macWhisperActivationAction)
                self.logger.write("macwhisper activation_sent key=globe")
            } catch {
                self.logger.write("failure macwhisper_activation error=\(error.localizedDescription)")
                self.showFatalError("Could not start MacWhisper through BetterTouchTool.\n\n\(error.localizedDescription)")
            }
        }
    }

    private func buildCapturePanel() {
        let panelSize = NSSize(width: 350, height: 104)
        let targetScreen = NSScreen.main ?? NSScreen.screens.first

        panel = CapturePanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.delegate = self

        if let targetScreen {
            let screenFrame = targetScreen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: screenFrame.maxX - panelSize.width - 24,
                y: screenFrame.minY + 24
            ))
        }

        let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: panelSize))
        glass.autoresizingMask = [.width, .height]
        glass.style = .regular
        glass.cornerRadius = 22
        glass.tintColor = NSColor.controlAccentColor.withAlphaComponent(0.08)

        let content = NSView(frame: NSRect(origin: .zero, size: panelSize))
        glass.contentView = content
        panel.contentView = glass

        let icon = NSImageView()
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
        icon.image = NSImage(
            systemSymbolName: "waveform.circle.fill",
            accessibilityDescription: "Capturing dictation"
        )?.withSymbolConfiguration(symbolConfig)
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        titleLabel = NSTextField(labelWithString: "Capturing dictation")
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel = NSTextField(labelWithString: "Press Globe again to finish")
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        progressIndicator = NSProgressIndicator()
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isIndeterminate = true
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.startAnimation(nil)

        let closeImage = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: "Cancel dictation"
        )
        closeButton = NSButton(image: closeImage ?? NSImage(), target: self, action: #selector(cancelButtonPressed))
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .tertiaryLabelColor
        closeButton.toolTip = "Cancel dictation"
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        // This tiny, nearly transparent editor is deliberately kept focusable.
        // MacWhisper sees it as a valid local text destination, while the user
        // only sees the compact toast above it.
        let documentSize = NSSize(width: 4, height: 4)
        textView = CaptureTextView(frame: NSRect(origin: .zero, size: documentSize))
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.alphaValue = 0.01
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = .zero
        textView.minSize = documentSize
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = true
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        textView.cancelHandler = { [weak self] in self?.cancelCapture(reason: "escape") }

        content.addSubview(icon)
        content.addSubview(titleLabel)
        content.addSubview(subtitleLabel)
        content.addSubview(progressIndicator)
        content.addSubview(closeButton)
        content.addSubview(textView)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            icon.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 34),
            icon.heightAnchor.constraint(equalToConstant: 34),

            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 14),
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: progressIndicator.leadingAnchor, constant: -14),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: progressIndicator.leadingAnchor, constant: -14),

            progressIndicator.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            progressIndicator.centerYAnchor.constraint(equalTo: content.centerYAnchor, constant: 8),

            closeButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            closeButton.topAnchor.constraint(equalTo: content.topAnchor, constant: 9),
            closeButton.widthAnchor.constraint(equalToConstant: 22),
            closeButton.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        restoreCaptureFocus()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        restoreCaptureFocus()
        return true
    }

    private func restoreCaptureFocus() {
        guard !finishing, panel != nil, textView != nil else { return }
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(textView)
        logger.write("focus restored")
    }

    @objc private func cancelButtonPressed() {
        cancelCapture(reason: "close_button")
    }

    private func startDatabaseMonitor() throws {
        let databaseURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacWhisper/Database/main.sqlite")

        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            let message = database.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:))
                ?? "The database could not be opened."
            throw NSError(
                domain: "DictationBridge",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        sqlite3_busy_timeout(database, 500)
        baselineDictationDate = try latestDictationDate()
        logger.write("database monitor_started baseline=\(baselineDictationDate.isEmpty ? "none" : baselineDictationDate)")

        let timer = Timer(
            timeInterval: 0.2,
            target: self,
            selector: #selector(checkForFinishedDictation),
            userInfo: nil,
            repeats: true
        )
        databaseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func latestDictationDate() throws -> String {
        guard let database else { return "" }
        let sql = """
        SELECT COALESCE(MAX(dateCreated), '')
        FROM dictation
        WHERE dateDeleted IS NULL
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw databaseError(code: 4)
        }

        guard sqlite3_step(statement) == SQLITE_ROW else { return "" }
        return sqliteText(statement, column: 0) ?? ""
    }

    @objc private func checkForFinishedDictation() {
        guard !finishing, let database else { return }

        let sql = """
        SELECT dateCreated,
               targetAppBundleID,
               transcribedText,
               processedText,
               COALESCE(transcriptionDidSucceed, 0),
               (aiPromptID IS NOT NULL),
               processingError
        FROM dictation
        WHERE dateDeleted IS NULL
          AND dateCreated > ?
        ORDER BY dateCreated ASC
        LIMIT 1
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return }

        sqlite3_bind_text(statement, 1, baselineDictationDate, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return }

        let dateCreated = sqliteText(statement, column: 0) ?? baselineDictationDate
        let targetBundleID = sqliteText(statement, column: 1) ?? "unknown"
        let transcribedText = sqliteText(statement, column: 2)
        let processedText = sqliteText(statement, column: 3)
        let transcriptionSucceeded = sqlite3_column_int(statement, 4) != 0
        let hasAIPrompt = sqlite3_column_int(statement, 5) != 0
        let processingError = sqliteText(statement, column: 6)

        let rowState = "\(dateCreated)|\(targetBundleID)|\(transcribedText?.count ?? 0)|\(processedText?.count ?? 0)|\(transcriptionSucceeded)|\(hasAIPrompt)|\(processingError != nil)"
        if rowState != lastLoggedDatabaseState {
            lastLoggedDatabaseState = rowState
            logger.write(
                "database row date=\(dateCreated) target=\(targetBundleID) raw_chars=\(transcribedText?.count ?? 0) processed_chars=\(processedText?.count ?? 0) success=\(transcriptionSucceeded) ai_prompt=\(hasAIPrompt) processing_error=\(processingError != nil)"
            )
        }

        guard transcriptionSucceeded else { return }

        if let processedText, !processedText.isEmpty {
            baselineDictationDate = dateCreated
            logger.write("database final_processed chars=\(processedText.count)")
            finishWithDatabaseText(processedText)
            return
        }

        if !hasAIPrompt || processingError != nil {
            guard let transcribedText, !transcribedText.isEmpty else { return }
            baselineDictationDate = dateCreated
            logger.write("database final_raw chars=\(transcribedText.count) reason=\(hasAIPrompt ? "processing_error" : "no_ai_prompt")")
            finishWithDatabaseText(transcribedText)
            return
        }

        titleLabel.stringValue = "Polishing dictation"
        subtitleLabel.stringValue = "Waiting for MacWhisper…"
    }

    private func finishWithDatabaseText(_ text: String) {
        guard !finishing else { return }
        databaseTimer?.invalidate()
        logger.write("delivery scheduled chars=\(text.count)")
        titleLabel.stringValue = "Dictation ready"
        subtitleLabel.stringValue = "Typing into Screen Sharing…"
        progressIndicator.stopAnimation(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.deliver(text)
        }
    }

    private func databaseError(code: Int) -> NSError {
        let message = database.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:))
            ?? "Unknown MacWhisper database error."
        return NSError(
            domain: "DictationBridge",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private func sqliteText(_ statement: OpaquePointer, column: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }

    private func deliver(_ transcript: String) {
        guard !finishing else { return }
        finishing = true
        let normalized = normalizeForRemoteTyping(transcript)
        logger.write(
            "delivery normalized original_chars=\(transcript.count) output_chars=\(normalized.text.count) line_breaks=\(normalized.lineBreakCount)"
        )

        guard !normalized.text.isEmpty else {
            finishing = false
            showFatalError("MacWhisper finished, but its transcript did not contain any text to type.")
            return
        }
        logger.write("delivery begin chars=\(normalized.text.count) mode=shared_clipboard")
        timeoutWorkItem?.cancel()
        databaseTimer?.invalidate()
        if let database {
            sqlite3_close(database)
            self.database = nil
        }
        panel.orderOut(nil)

        guard let screenSharingApp else {
            showFatalError("Screen Sharing closed before the transcript was ready.")
            return
        }

        screenSharingApp.activate(options: [.activateAllWindows])

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            guard self.writeTranscriptToPasteboard(normalized.text) else {
                self.finishing = false
                self.showFatalError("Could not place the finished transcript on the clipboard.")
                return
            }
            self.logger.write("clipboard staged chars=\(normalized.text.count) pass=1")

            // A second change notification makes Screen Sharing's automatic
            // clipboard bridge much less likely to miss the update.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, self.finishing else { return }
                guard self.writeTranscriptToPasteboard(normalized.text) else {
                    self.failClipboardDelivery("Could not refresh the clipboard before pasting.")
                    return
                }
                self.logger.write("clipboard staged chars=\(normalized.text.count) pass=2")
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + clipboardPropagationDelay) { [weak self] in
                self?.sendPasteShortcut(totalCharacters: normalized.text.count)
            }
        }
    }

    private func normalizeForRemoteTyping(_ text: String) -> (text: String, lineBreakCount: Int) {
        let lineBreakCount = text.unicodeScalars.reduce(into: 0) { count, scalar in
            if CharacterSet.newlines.contains(scalar) {
                count += 1
            }
        }

        // MacWhisper commonly formats polished dictation into paragraphs. A newline
        // sent through BetterTouchTool becomes Return in the remote session, so make
        // all dictated prose a single, whitespace-normalized line before typing it.
        let flattened = text.components(separatedBy: .newlines).joined(separator: " ")
        let normalized = flattened
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return (normalized, lineBreakCount)
    }

    @discardableResult
    private func writeTranscriptToPasteboard(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    private func sendPasteShortcut(totalCharacters: Int) {
        let modifierConfiguration = "{\"BTTModifierActionBehavior\":2,\"BTTModifierActionEventTap\":0}"
        let steps = [
            BetterTouchToolStep(
                action: [
                    "BTTPredefinedActionType": 547,
                    "BTTPredefinedActionName": "All Modifier Keys UP"
                ],
                delayAfter: pasteModifierDelay
            ),
            BetterTouchToolStep(
                action: [
                    "BTTPredefinedActionType": 186,
                    "BTTPredefinedActionName": "Command Down",
                    "BTTAdditionalActionData": modifierConfiguration
                ],
                delayAfter: pasteModifierDelay
            ),
            BetterTouchToolStep(
                action: [
                    "BTTPredefinedActionType": 264,
                    "BTTPredefinedActionName": "Send V Key",
                    "BTTShortcutToSend": "9",
                    "BTTAdditionalActionData": [
                        "BTTActionSendKeyboardShortcutIncludeCurrentModifiers": true,
                        "BTTActionSendKeyboardShortcutLowLevel": true
                    ]
                ],
                delayAfter: pasteModifierDelay
            ),
            BetterTouchToolStep(
                action: [
                    "BTTPredefinedActionType": 187,
                    "BTTPredefinedActionName": "Command Up",
                    "BTTAdditionalActionData": modifierConfiguration
                ],
                delayAfter: pasteModifierDelay
            ),
            BetterTouchToolStep(
                action: [
                    "BTTPredefinedActionType": 547,
                    "BTTPredefinedActionName": "All Modifier Keys UP"
                ],
                delayAfter: 0.65
            )
        ]
        logger.write("clipboard paste_shortcut_begin chars=\(totalCharacters)")
        performPasteSteps(steps, index: 0, totalCharacters: totalCharacters)
    }

    private func performPasteSteps(
        _ steps: [BetterTouchToolStep],
        index: Int,
        totalCharacters: Int
    ) {
        guard index < steps.count else {
            logger.write("delivery success chars=\(totalCharacters) mode=shared_clipboard clipboard=retained")
            NSApp.terminate(nil)
            return
        }

        do {
            try runBetterTouchToolAction(steps[index].action)
        } catch {
            try? runBetterTouchToolAction([
                "BTTPredefinedActionType": 547,
                "BTTPredefinedActionName": "All Modifier Keys UP"
            ])
            failClipboardDelivery(
                "The transcript reached the clipboard, but BetterTouchTool could not send Paste.\n\n\(error.localizedDescription)"
            )
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + steps[index].delayAfter) { [weak self] in
            self?.performPasteSteps(steps, index: index + 1, totalCharacters: totalCharacters)
        }
    }

    private func failClipboardDelivery(_ message: String) {
        finishing = false
        logger.write("failure clipboard_delivery")
        showFatalError(message)
    }

    private func runBetterTouchToolAction(_ action: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: action, options: [])
        guard let json = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "DictationBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not encode the BetterTouchTool action."])
        }

        let appleScriptJSON = json
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let source = """
        set actionJSON to "\(appleScriptJSON)"
        tell application "BetterTouchTool" to trigger_action actionJSON
        """

        var errorInfo: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            throw NSError(domain: "DictationBridge", code: 2, userInfo: [NSLocalizedDescriptionKey: errorInfo.description])
        }
        _ = result
    }

    func windowWillClose(_ notification: Notification) {
        cancelCapture(reason: "window_close")
    }

    private func cancelCapture(reason: String = "cancel") {
        guard !finishing else { return }
        finishing = true
        logger.write("cancel reason=\(reason)")
        timeoutWorkItem?.cancel()
        databaseTimer?.invalidate()
        if let database {
            sqlite3_close(database)
            self.database = nil
        }
        screenSharingApp?.activate(options: [.activateAllWindows])
        NSApp.terminate(nil)
    }

    private func showFatalError(_ message: String) {
        finishing = true
        logger.write("fatal_error")
        databaseTimer?.invalidate()
        if let database {
            sqlite3_close(database)
            self.database = nil
        }
        panel?.orderOut(nil)
        let alert = NSAlert()
        alert.messageText = "Screen Sharing Dictation"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
        screenSharingApp?.activate(options: [.activateAllWindows])
        NSApp.terminate(nil)
    }
}

@main
@MainActor
struct ScreenSharingDictationApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
