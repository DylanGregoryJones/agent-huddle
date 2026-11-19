import Carbon

/// A system-wide shortcut through Carbon's RegisterEventHotKey. Works while the app is in the
/// background and needs no Accessibility permission. Unregistered when released.
final class HotKey {
  private let action: () -> Void
  private var ref: EventHotKeyRef?
  private var handler: EventHandlerRef?

  /// nil when the shortcut can't be registered, e.g. another app already holds it.
  init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
    self.action = action
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let me = Unmanaged.passUnretained(self).toOpaque()
    let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
      guard let userData else { return OSStatus(eventNotHandledErr) }
      Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().action()
      return noErr
    }, 1, &spec, me, &handler)
    guard installed == noErr else { return nil }
    let id = EventHotKeyID(signature: 0x4148_7564 /* "AHud" */, id: 1)
    guard RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr else { return nil }
  }

  deinit {
    if let ref { UnregisterEventHotKey(ref) }
    if let handler { RemoveEventHandler(handler) }
  }
}
