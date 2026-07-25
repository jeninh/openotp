import AppKit
import Carbon.HIToolbox

@MainActor
final class HotKey {

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var handler: (() -> Void)?

    private static var instances: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1
    private let id: UInt32

    init() {
        self.id = HotKey.nextID
        HotKey.nextID += 1
    }

    private var savedHandler: (() -> Void)?

    @discardableResult
    func register(
        keyCode: UInt32 = UInt32(kVK_ANSI_V),
        modifiers: UInt32 = UInt32(controlKey | optionKey),
        handler: @escaping () -> Void
    ) -> Bool {
        self.handler = handler
        self.savedHandler = handler
        HotKey.instances[id] = self

        installHandlerIfNeeded()

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4F544F50 ), id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr { hotKeyRef = ref; return true }
        return false
    }

    @discardableResult
    func reregister(keyCode: UInt32, modifiers: UInt32) -> Bool {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        guard let handler = savedHandler else { return false }
        return register(keyCode: keyCode, modifiers: modifiers, handler: handler)
    }

    func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        HotKey.instances[id] = nil
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let matchedID = hkID.id
            DispatchQueue.main.async {
                HotKey.instances[matchedID]?.handler?()
            }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }
}
