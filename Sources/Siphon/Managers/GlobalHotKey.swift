import AppKit
import Carbon.HIToolbox

/// Process-wide show/hide shortcut.
///
/// Carbon is the only API that lets an inactive app own a key chord without an
/// Accessibility or Input-Monitoring grant: `NSEvent` global monitors silently
/// receive nothing until the user approves them in System Settings, while
/// `RegisterEventHotKey` simply reserves the combination system-wide.
@MainActor
public final class GlobalHotKeyManager {
    public static let shared = GlobalHotKeyManager()

    public enum PrefKey {
        /// 全局热键开关（默认开）。
        public static let enabled = "Siphon.globalHotKey"
    }

    /// ⌥⌘D, matching the DownloadPopup shortcut so both surfaces are one habit.
    public static let displayText = "⌥⌘D"

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var action: (() -> Void)?

    private init() {}

    public static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: PrefKey.enabled) as? Bool ?? true
    }

    /// Installs (or updates) the chord. The action is retained so the Settings
    /// toggle can turn the hotkey back on without re-registering by hand.
    public func install(action: @escaping () -> Void) {
        self.action = action
        guard Self.isEnabled else {
            unregister()
            return
        }
        installHandlerIfNeeded()
        guard hotKeyRef == nil else { return }

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_D),
                                         UInt32(cmdKey | optionKey),
                                         hotKeyID,
                                         GetApplicationEventTarget(),
                                         0,
                                         &ref)
        if status == noErr {
            hotKeyRef = ref
        } else {
            DiagnosticLog.shared.log("hotkey registration failed (OSStatus \(status))")
        }
    }

    public func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: PrefKey.enabled)
        if enabled {
            if let action { install(action: action) }
        } else {
            unregister()
        }
    }

    public func uninstall() {
        action = nil
        unregister()
    }

    fileprivate func fire() {
        action?()
    }

    // MARK: - Carbon plumbing

    private static let signature: OSType = 0x5369_7068  // 'Siph'

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), siphonHotKeyHandler,
                            1, &spec, nil, &handlerRef)
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
    }
}

/// C callback: Carbon delivers the chord on the main thread, so hopping to the
/// main actor only needs to assert the isolation we already have.
private func siphonHotKeyHandler(_ nextHandler: EventHandlerCallRef?,
                                 _ event: EventRef?,
                                 _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event,
                                   EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID),
                                   nil,
                                   MemoryLayout<EventHotKeyID>.size,
                                   nil,
                                   &hotKeyID)
    guard status == noErr, hotKeyID.signature == 0x5369_7068 else {
        return OSStatus(eventNotHandledErr)
    }
    DispatchQueue.main.async {
        MainActor.assumeIsolated { GlobalHotKeyManager.shared.fire() }
    }
    return noErr
}