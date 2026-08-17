import Foundation
import Carbon.HIToolbox

/// Глобальная горячая клавиша ⌘⇧R: запись стартует и останавливается,
/// даже когда окно приложения не активно. Carbon-подход не требует
/// разрешения на управление компьютером.
private var hotKeyAction: (() -> Void)?

final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    var isRegistered: Bool { hotKeyRef != nil }

    func register(action: @escaping () -> Void) {
        guard hotKeyRef == nil else { return }
        hotKeyAction = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async { hotKeyAction?() }
            return noErr
        }, 1, &eventType, nil, &eventHandler)

        // 'DKRC' — произвольная подпись, чтобы не пересечься с чужими клавишами.
        let hotKeyID = EventHotKeyID(signature: OSType(0x444B5243), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_R),
                            UInt32(cmdKey | shiftKey),
                            hotKeyID,
                            GetApplicationEventTarget(),
                            0,
                            &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        hotKeyAction = nil
    }

    static var shortcutTitle: String { "⌘⇧R" }
}
