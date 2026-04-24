import Cocoa
import QuartzCore

enum HotkeyType: String, CaseIterable {
    case rightCommand
    case rightOption

    var displayName: String {
        switch self {
        case .rightCommand: return "Right ⌘ Command"
        case .rightOption:  return "Right ⌥ Option"
        }
    }

    /// The virtual keycode for this modifier's right-side key.
    var keyCode: Int64 {
        switch self {
        case .rightCommand: return 0x36    // kVK_RightCommand
        case .rightOption:  return 0x3D    // kVK_RightOption
        }
    }

    var modifierFlag: CGEventFlags {
        switch self {
        case .rightCommand: return .maskCommand
        case .rightOption:  return .maskAlternate
        }
    }
}

final class KeyMonitor {
    var onHotkeyToggle: (() -> Void)?

    var hotkey: HotkeyType = .rightCommand {
        didSet { isPressed = false }
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isPressed = false
    private var lastToggleTime: TimeInterval = 0
    private let debounceInterval: TimeInterval = 0.25

    /// Start monitoring. Returns false if accessibility permission is missing.
    func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let monitor = Unmanaged<KeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
    }

    // MARK: - Private

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        // flagsChanged reports every modifier state change. We only care
        // about the exact key the user chose: filter by keyCode first.
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == hotkey.keyCode else {
            return Unmanaged.passRetained(event)
        }

        // Rising edge on the modifier flag = the user just pressed the key.
        // Falling edge = they released it. We only fire onHotkeyToggle on
        // press (never on release) — this is what makes it a press-to-toggle.
        let flagActive = event.flags.contains(hotkey.modifierFlag)

        if flagActive && !isPressed {
            let now = CACurrentMediaTime()
            if now - lastToggleTime < debounceInterval {
                // macOS generates phantom press/release/press bursts on modifier
                // keys (especially Right Option for input-source switching).
                // Ignore any "press" that lands within 250ms of the last toggle.
                isPressed = true
                return nil
            }
            isPressed = true
            lastToggleTime = now
            DispatchQueue.main.async { [weak self] in self?.onHotkeyToggle?() }
        } else if !flagActive && isPressed {
            isPressed = false
        }

        // Always swallow the event so Cmd/Opt-by-itself doesn't leak into
        // whatever app is focused.
        return nil
    }
}
