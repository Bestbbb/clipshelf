import AppKit
import Carbon

@MainActor
final class GlobalHotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static var nextID: UInt32 = 1
    private let hotKeyID: UInt32
    var onPressed: (() -> Void)?

    init() { hotKeyID = Self.nextID; Self.nextID &+= 1 }

    func register(keyCode: UInt32 = UInt32(kVK_ANSI_V), modifiers: UInt32 = UInt32(cmdKey | shiftKey)) -> OSStatus {
        unregister()
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            return MainActor.assumeIsolated {
                var received = EventHotKeyID()
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &received) == noErr,
                      received.signature == 0x43534846, received.id == hotKey.hotKeyID else { return OSStatus(eventNotHandledErr) }
                hotKey.onPressed?()
                return noErr
            }
        }, 1, &event, context, &handler)
        guard installed == noErr else { return installed }
        let identifier = EventHotKeyID(signature: 0x43534846, id: hotKeyID)
        let result = RegisterEventHotKey(keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &reference)
        if result != noErr { unregister() }
        return result
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        reference = nil
        handler = nil
    }
}
