import AppKit
import JaplosProtocol

/// Hold Space to talk, release to send — original Japlos behaviour.
/// Space only drives PTT when the composer is empty (and nothing else is
/// being typed); otherwise it types a normal space.
@MainActor
final class PushToTalkMonitor {
    var composerText: () -> String = { "" }
    var overlayPresented: () -> Bool = { false }
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    var onCancel: () -> Void = {}

    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private(set) var holding = false

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.cancelHold() }
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        cancelHold()
    }

    private func cancelHold() {
        guard holding else { return }
        holding = false
        onCancel()
    }

    /// Returns true when the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        let isSpace = event.keyCode == 49
        guard isSpace else { return false }
        if event.type == .keyUp {
            guard holding else { return false }
            holding = false
            onRelease()
            return true
        }
        // keyDown
        if holding { return true } // swallow auto-repeat
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift, .function])
        let responder = event.window?.firstResponder
        let textView = responder as? NSTextView
        let imeComposing = textView?.hasMarkedText() ?? false
        // Field editor of the composer is an NSTextView whose delegate is the
        // composer's NSTextField; any other editable text view counts as
        // "typing elsewhere".
        let otherText: Bool = {
            guard let textView else { return false }
            if textView.isFieldEditor { return textView.string != composerText() }
            return textView.isEditable
        }()
        let ok = PushToTalkGate.shouldHandle(
            isSpace: true,
            hasModifiers: !modifiers.isEmpty,
            appActive: NSApp.isActive && event.window?.isKeyWindow == true && event.window?.attachedSheet == nil,
            overlayPresented: overlayPresented(),
            composerText: composerText(),
            imeComposing: imeComposing,
            focusInOtherTextField: otherText
        )
        guard ok, !event.isARepeat else { return false }
        holding = true
        onPress()
        return true
    }
}
