import Cocoa
import CoreGraphics
import CoreMedia
import Carbon.HIToolbox
import ScreenCaptureKit

// MARK: – Display helper ----------------------------------------------------

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

enum DisplayHelper {
    /// All attached displays (main first)
    static var active: [CGDirectDisplayID] {
        var cnt: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &cnt) == .success, cnt > 0 else { return [] }
        var list = [CGDirectDisplayID](repeating: 0, count: Int(cnt))
        guard CGGetActiveDisplayList(cnt, &list, &cnt) == .success else { return [] }
        return Array(list.prefix(Int(cnt)))
    }

    /// Prefer externals; fall back to main if none
    static var selectable: [CGDirectDisplayID] {
        let main = CGMainDisplayID()
        let externals = active.filter { $0 != main }
        return externals.isEmpty ? [main] : externals
    }

    /// Human‑readable name or generic fallback
    static func name(for id: CGDirectDisplayID, idx: Int) -> String {
        if let screen = NSScreen.screens.first(where: { $0.displayID == id }) {
            return screen.localizedName
        }
        return "Monitor \(idx + 1)"
    }

    /// The built-in panel, if present (nil in clamshell mode).
    static var builtin: CGDirectDisplayID? {
        active.first { CGDisplayIsBuiltin($0) != 0 }
    }

    /// True pixel resolution. CGDisplayBounds (and SCDisplay.width/height) are
    /// in *points* — capping a capture there discards half the detail of a
    /// HiDPI display.
    static func pixelSize(of id: CGDirectDisplayID) -> CGSize {
        if let mode = CGDisplayCopyDisplayMode(id),
           mode.pixelWidth > 0, mode.pixelHeight > 0 {
            return CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
        }
        let b = CGDisplayBounds(id)
        return CGSize(width: max(b.width, 1), height: max(b.height, 1))
    }

    static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == id }
    }
}

// MARK: – Frame relay --------------------------------------------------------

extension CMSampleBuffer {
    /// ScreenCaptureKit also emits "idle"/"blank" frames when nothing
    /// changed — only `.complete` frames carry a new image worth showing.
    var isCompleteScreenFrame: Bool {
        guard isValid else { return false }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           SCFrameStatus(rawValue: raw) != .complete {
            return false
        }
        return true
    }
}

/// Renders SCStream sample buffers off the main thread and hands the newest
/// frame to a CALayer, coalescing so a slow main thread can never accumulate
/// an unbounded backlog of stale frames.
final class FrameRelay {
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var pending: CGImage?
    private var scheduled = false
    private weak var layer: CALayer?

    /// Device-pixel size to Lanczos-resample frames to (nil: use as captured).
    /// Guarded by `lock`: written from the main thread, read per frame.
    private var targetSize: CGSize?
    private let lanczos = CIFilter(name: "CILanczosScaleTransform")

    init(layer: CALayer) { self.layer = layer }

    /// Resample every frame to exactly this pixel size before display.
    /// Lanczos keeps downscaled text markedly crisper than the capture
    /// pipeline's own scaler — capture at native resolution and let this
    /// do the single, high-quality scale to the output's pixel grid.
    func setTargetPixelSize(_ size: CGSize?) {
        lock.lock()
        targetSize = size
        lock.unlock()
    }

    /// Call from the stream's sample-handler queue.
    func handle(_ sb: CMSampleBuffer) {
        guard sb.isCompleteScreenFrame, let buf = sb.imageBuffer else { return }

        var ciImg = CIImage(cvImageBuffer: buf)

        lock.lock()
        let target = targetSize
        lock.unlock()
        if let target, target.width > 1, target.height > 1, ciImg.extent.height > 1,
           abs(target.width - ciImg.extent.width) > 0.5 || abs(target.height - ciImg.extent.height) > 0.5,
           let filter = lanczos {
            let scale = target.height / ciImg.extent.height
            filter.setValue(ciImg, forKey: kCIInputImageKey)
            filter.setValue(scale, forKey: kCIInputScaleKey)
            filter.setValue((target.width / ciImg.extent.width) / scale, forKey: kCIInputAspectRatioKey)
            if let scaled = filter.outputImage {
                ciImg = scaled.cropped(to: CGRect(x: 0, y: 0,
                                                  width: target.width.rounded(),
                                                  height: target.height.rounded()))
            }
        }

        guard let cgImg = ciContext.createCGImage(ciImg, from: ciImg.extent) else { return }

        lock.lock()
        pending = cgImg
        let needsSchedule = !scheduled
        scheduled = true
        lock.unlock()

        guard needsSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let img = self.pending
            self.pending = nil
            self.scheduled = false
            self.lock.unlock()
            self.layer?.contents = img
        }
    }

    func clear() {
        lock.lock()
        pending = nil
        lock.unlock()
    }
}

/// Hands the newest frame of a stream to the main thread as a bare IOSurface.
/// The surface goes straight into a layer's `contents` — no copy, no CPU
/// readback — and delivery is coalesced so a busy main thread only ever
/// sees the newest frame.
final class SurfaceRelay {
    private let lock = NSLock()
    private var pending: IOSurface?
    private var scheduled = false
    private let deliver: (IOSurface) -> Void

    /// `deliver` runs on the main thread.
    init(deliver: @escaping (IOSurface) -> Void) { self.deliver = deliver }

    /// Call from the stream's sample-handler queue.
    func handle(_ sb: CMSampleBuffer) {
        guard sb.isCompleteScreenFrame,
              let buffer = sb.imageBuffer,
              let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue()
        else { return }

        lock.lock()
        pending = surface
        let needsSchedule = !scheduled
        scheduled = true
        lock.unlock()
        guard needsSchedule else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let next = self.pending
            self.pending = nil
            self.scheduled = false
            self.lock.unlock()
            if let next { self.deliver(next) }
        }
    }
}

// MARK: – Accessibility helper ----------------------------------------------

enum Accessibility {
    static var trusted: Bool { AXIsProcessTrusted() }

    /// Shows the system's one-time Accessibility prompt if not yet trusted.
    static func request() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: – Keyboard shortcuts --------------------------------------------------

/// A user-recorded key combination, stored in UserDefaults.
struct KeyShortcut: Equatable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let display: String          // e.g. "⌃⌥P", captured at record time

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14",
        kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19", kVK_F20: "F20",
    ]
    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]

    /// Nil for combinations that would clash with ordinary typing: a plain
    /// letter or a ⇧-letter must not become a global hotkey. Function keys
    /// are fine on their own — handy on a presentation remote.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let code = Int(event.keyCode)
        let isFunctionKey = Self.functionKeys[code] != nil
        guard isFunctionKey || !flags.intersection([.command, .option, .control]).isEmpty else { return nil }

        let key: String
        if let name = Self.functionKeys[code] ?? Self.namedKeys[code] {
            key = name
        } else if let chars = event.characters(byApplyingModifiers: []), !chars.isEmpty,
                  !chars.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            key = chars.uppercased()
        } else {
            return nil
        }

        var symbols = ""
        var carbon: UInt32 = 0
        if flags.contains(.control) { symbols += "⌃"; carbon |= UInt32(controlKey) }
        if flags.contains(.option)  { symbols += "⌥"; carbon |= UInt32(optionKey) }
        if flags.contains(.shift)   { symbols += "⇧"; carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { symbols += "⌘"; carbon |= UInt32(cmdKey) }
        self.init(keyCode: UInt32(code), carbonModifiers: carbon, display: symbols + key)
    }

    init(keyCode: UInt32, carbonModifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.display = display
    }

    static func load(_ key: String) -> KeyShortcut? {
        guard let d = UserDefaults.standard.dictionary(forKey: key),
              let code = d["keyCode"] as? Int, let mods = d["modifiers"] as? Int,
              let display = d["display"] as? String else { return nil }
        return KeyShortcut(keyCode: UInt32(code), carbonModifiers: UInt32(mods), display: display)
    }

    static func save(_ shortcut: KeyShortcut?, _ key: String) {
        guard let s = shortcut else { UserDefaults.standard.removeObject(forKey: key); return }
        UserDefaults.standard.set(["keyCode": Int(s.keyCode), "modifiers": Int(s.carbonModifiers),
                                   "display": s.display], forKey: key)
    }
}

private func hotKeyEventHandler(_ next: EventHandlerCallRef?, _ event: EventRef?,
                                _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID), nil,
                                   MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr else { return status }
    GlobalHotKey.fire(hotKeyID.id)
    return noErr
}

/// A true system-wide hotkey (Carbon `RegisterEventHotKey`). Unlike an
/// NSEvent global monitor it needs no Accessibility access, and it *consumes*
/// the keystroke — the frontmost app never sees it.
final class GlobalHotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    private let id: UInt32
    private var ref: EventHotKeyRef?

    init(action: @escaping () -> Void) {
        id = Self.nextID
        Self.nextID += 1
        Self.handlers[id] = action
        Self.installHandlerOnce()
    }

    deinit {
        unregister()
        Self.handlers[id] = nil
    }

    fileprivate static func fire(_ id: UInt32) { handlers[id]?() }

    private static func installHandlerOnce() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &spec, nil, nil)
    }

    /// Replaces any previous binding. False if the combination is taken
    /// (another app registered it first).
    @discardableResult
    func register(_ shortcut: KeyShortcut) -> Bool {
        unregister()
        let hotKeyID = EventHotKeyID(signature: OSType(0x5349_5348), id: id)   // 'SISH'
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            NSLog("ScreenInScreen: could not register hotkey %@ (%d)", shortcut.display, status)
            ref = nil
        }
        return status == noErr
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }
}

// MARK: – Click-through forwarding ------------------------------------------

/// CG global coordinates put the origin at the *top-left* of the primary
/// display with y growing downward, while Cocoa puts it bottom-left with y
/// growing upward. All CGEvent locations live in CG space.
private var primaryDisplayHeight: CGFloat { CGDisplayBounds(CGMainDisplayID()).height }

/// Everything needed to translate mouse events over the preview into events on
/// the mirrored display. Captured once when a gesture begins so the mapping
/// stays stable even if the window moves or the mirrored display changes
/// mid-drag. All rects are in CG global coordinates.
struct ForwardTarget {
    let imageRect: CGRect      // the aspect-fit image area inside the preview
    let displayBounds: CGRect  // the mirrored display

    /// Display points travelled per preview point — a drag across the small
    /// preview must sweep the whole monitor.
    var scale: CGPoint {
        CGPoint(x: displayBounds.width / imageRect.width,
                y: displayBounds.height / imageRect.height)
    }

    func remotePoint(for local: CGPoint) -> CGPoint {
        CGPoint(x: displayBounds.minX + (local.x - imageRect.minX) / imageRect.width * displayBounds.width,
                y: displayBounds.minY + (local.y - imageRect.minY) / imageRect.height * displayBounds.height)
    }

    func localPoint(for remote: CGPoint) -> CGPoint {
        CGPoint(x: imageRect.minX + (remote.x - displayBounds.minX) / displayBounds.width * imageRect.width,
                y: imageRect.minY + (remote.y - displayBounds.minY) / displayBounds.height * imageRect.height)
    }

    /// Keep the point on the display — one point shy of the far edges so
    /// hit-testing can never spill onto a neighbouring display.
    func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, displayBounds.minX), displayBounds.maxX - 1),
                y: min(max(p.y, displayBounds.minY), displayBounds.maxY - 1))
    }
}

private func mouseForwarderCallback(proxy: CGEventTapProxy, type: CGEventType,
                                    event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<MouseForwarder>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
}

/// Redirects physical mouse events that land on the preview onto the mirrored
/// display by rewriting their location inside a HID-level event tap.
///
/// Relocating the *real* event stream — instead of swallowing it and posting a
/// synthetic one — means click counts (double-click), modifier flags, momentum
/// scrolling and the window server's drag tracking all keep working, and there
/// is never a second, conflicting notion of the button state.
final class MouseForwarder {
    /// Returns a mapping when the given CG-global point should be forwarded.
    var targetProvider: (CGPoint) -> ForwardTarget? = { _ in nil }

    /// Whether forwarding should currently happen. The tap outlives a mid-air
    /// drag so the mirrored app is guaranteed to receive its mouse-up.
    var wantsActive = false { didSet { updateTapState() } }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private struct DragSession {
        let target: ForwardTarget
        var point: CGPoint     // current virtual location on the mirrored display
        var buttonsDown: Int
    }
    private var session: DragSession?

    deinit {
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
    }

    private func updateTapState() {
        if wantsActive {
            if tap == nil { createTap() }
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        } else if session == nil, let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
    }

    private func createTap() {
        guard Accessibility.trusted else { return }
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                    .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                                    .otherMouseDown, .otherMouseUp, .otherMouseDragged,
                                    .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        tap = CGEvent.tapCreate(tap: .cghidEventTap,
                                place: .headInsertEventTap,
                                options: .defaultTap,
                                eventsOfInterest: mask,
                                callback: mouseForwarderCallback,
                                userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else {
            NSLog("ScreenInScreen: could not create event tap — Accessibility access missing?")
            return
        }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    }

    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system cut us off (slow main thread, secure input, …) —
            // recover instead of silently losing click-through forever.
            session = nil
            if wantsActive, let tap { CGEvent.tapEnable(tap: tap, enable: true) }

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if session != nil {
                // A second button joined an ongoing gesture (e.g. right-click
                // while left-dragging) — keep it at the same virtual point.
                session!.buttonsDown += 1
                event.location = session!.point
            } else if wantsActive, let target = targetProvider(event.location) {
                let point = target.clamp(target.remotePoint(for: event.location))
                session = DragSession(target: target, point: point, buttonsDown: 1)
                event.location = point
            }

        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            if var s = session {
                // Integrate hardware deltas rather than trusting the event's
                // absolute location: once earlier events were relocated, the
                // absolute stream no longer describes the user's hand.
                let dx = CGFloat(event.getIntegerValueField(.mouseEventDeltaX))
                let dy = CGFloat(event.getIntegerValueField(.mouseEventDeltaY))
                s.point = s.target.clamp(CGPoint(x: s.point.x + dx * s.target.scale.x,
                                                 y: s.point.y + dy * s.target.scale.y))
                session = s
                event.location = s.point
            }

        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            if var s = session {
                event.location = s.point
                s.buttonsDown -= 1
                if s.buttonsDown <= 0 { endSession(s) } else { session = s }
            }

        case .scrollWheel:
            if let s = session {
                event.location = s.point
            } else if wantsActive, let target = targetProvider(event.location) {
                event.location = target.clamp(target.remotePoint(for: event.location))
            }

        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private func endSession(_ s: DragSession) {
        session = nil
        // Park the cursor back over the preview at the spot matching where the
        // gesture ended, so the pointer is never stranded on the other monitor.
        // Slightly delayed so the window server processes the mouse-up first.
        let home = s.target.localPoint(for: s.point)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            CGWarpMouseCursorPosition(home)
            // Cancels the brief post-warp suppression of hardware deltas.
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        if !wantsActive { updateTapState() }
    }
}

// MARK: – AppDelegate -------------------------------------------------------

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var statusMenu = NSMenu()
    private let mirror = MirrorController(displayID: DisplayHelper.selectable.first ?? CGMainDisplayID())
    private let presenter = PresenterController()
    private lazy var windowPicker: WindowPickerController = {
        let picker = WindowPickerController()
        picker.isHidden = { [weak self] id in self?.presenter.hiddenWindowIDs.contains(id) ?? false }
        picker.onToggle = { [weak self] id, hidden in
            guard let self else { return }
            var ids = self.presenter.hiddenWindowIDs
            if hidden { ids.insert(id) } else { ids.remove(id) }
            self.presenter.setHidden(ids)
        }
        picker.transparency = { [weak self] in self?.presenter.hiddenWindowTransparency ?? 0 }
        picker.onTransparencyChange = { [weak self] value in
            self?.presenter.hiddenWindowTransparency = value
        }
        picker.pinShortcut = { KeyShortcut.load(Self.pinShortcutDefaultsKey) }
        picker.onPinShortcutChange = { [weak self] shortcut in
            guard let self else { return false }
            if let shortcut, !self.pinHotKey.register(shortcut) { return false }
            if shortcut == nil { self.pinHotKey.unregister() }
            KeyShortcut.save(shortcut, Self.pinShortcutDefaultsKey)
            return true
        }
        picker.onRecordingShortcut = { [weak self] recording in
            guard let self else { return }
            if recording {
                self.pinHotKey.unregister()
            } else if let stored = KeyShortcut.load(Self.pinShortcutDefaultsKey) {
                self.pinHotKey.register(stored)
            }
        }
        return picker
    }()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var trustPollTimer: Timer?
    private static let pinShortcutDefaultsKey = "PinHiddenWindowsShortcut"
    private lazy var pinHotKey = GlobalHotKey { [weak self] in self?.togglePinned() }

    func applicationDidFinishLaunching(_ n: Notification) {

        // menu‑bar item (left‑click = toggle, right‑click = menu)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "display", accessibilityDescription: "ScreenInScreen")
            btn.toolTip = "ScreenInScreen — Toggle Preview (⌥B)"
            btn.target = self
            btn.action = #selector(statusItemClicked(_:))
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusMenu.delegate = self

        mirror.showWindow()
        registerHotkey()
        if let shortcut = KeyShortcut.load(Self.pinShortcutDefaultsKey) { pinHotKey.register(shortcut) }
        ensureAccessibility()
    }

    func applicationWillTerminate(_ n: Notification) {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        localMonitor = nil
        trustPollTimer?.invalidate()
        trustPollTimer = nil
        presenter.setPinned(false)   // never leave windows parked in a corner
        presenter.stop()
        mirror.shutDown()
    }

    // MARK: Accessibility (click-through + global ⌥B both need it) ----------
    private func ensureAccessibility() {
        trustPollTimer?.invalidate()
        trustPollTimer = nil
        guard !Accessibility.trusted else { return }
        Accessibility.request()
        // TCC grants arrive without any notification — poll until they do so
        // click-through starts working the moment access is flipped on.
        trustPollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard Accessibility.trusted else { return }
            timer.invalidate()
            self?.trustPollTimer = nil
            self?.mirror.refreshForwarding()
        }
    }

    // MARK: status‑item click handler --------------------------------------
    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            // show dropdown on right‑click
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil) // pops menu
            statusItem.menu = nil                // detach menu to keep left‑click action
        } else {
            mirror.toggleWindow()                 // left‑click toggles preview
        }
    }

    // MARK: menu
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for (idx, id) in DisplayHelper.selectable.enumerated() {
            let item = NSMenuItem(title: DisplayHelper.name(for: id, idx: idx),
                                  action: #selector(selectDisplay(_:)), keyEquivalent: "")
            item.representedObject = id as NSNumber
            if id == mirror.currentDisplayID { item.state = .on }
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let presenterItem = NSMenuItem(title: "Presenter Mode (Mac → Monitor)",
                                       action: #selector(togglePresenter), keyEquivalent: "")
        presenterItem.state = presenter.isActive ? .on : .off
        menu.addItem(presenterItem)
        menu.addItem(NSMenuItem(title: "Settings…",
                                action: #selector(showWindowPicker), keyEquivalent: ""))
        var pinTitle = "Pin Windows"
        if let shortcut = KeyShortcut.load(Self.pinShortcutDefaultsKey) { pinTitle += "  (\(shortcut.display))" }
        let pinItem = NSMenuItem(title: pinTitle, action: #selector(togglePinned), keyEquivalent: "")
        pinItem.state = presenter.isPinned ? .on : .off
        menu.addItem(pinItem)

        menu.addItem(.separator())

        let clickThrough = NSMenuItem(title: "Click Through to Monitor",
                                      action: #selector(toggleClickThrough), keyEquivalent: "")
        clickThrough.state = mirror.clickThroughEnabled ? .on : .off
        menu.addItem(clickThrough)
        if !Accessibility.trusted {
            let grant = NSMenuItem(title: "Grant Accessibility Access…",
                                   action: #selector(grantAccessibility), keyEquivalent: "")
            menu.addItem(grant)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ScreenInScreen", action: #selector(quit), keyEquivalent: "q"))
    }
    @objc private func selectDisplay(_ sender: NSMenuItem) {
        guard let num = sender.representedObject as? NSNumber else { return }
        let id = CGDirectDisplayID(truncating: num)
        mirror.switchDisplay(to: id)
        presenter.moveOutput(to: id)
    }

    @objc private func togglePresenter() {
        if presenter.isActive {
            presenter.stop()
            windowPicker.close()
            return
        }
        // Output goes to the display selected in the menu; if that is the
        // built-in screen itself, fall back to the first real external.
        var out = mirror.currentDisplayID
        if out == DisplayHelper.builtin {
            out = DisplayHelper.selectable.first(where: { $0 != DisplayHelper.builtin }) ?? out
        }
        presenter.start(on: out)
        if presenter.isActive { windowPicker.show() }
    }

    @objc private func showWindowPicker() { windowPicker.show() }

    /// Pinning moves the real windows aside via Accessibility — without it
    /// the copies would sit on top of windows that still catch every click.
    @objc private func togglePinned() {
        if presenter.isPinned {
            presenter.setPinned(false)
            return
        }
        guard Accessibility.trusted else {
            NSSound.beep()
            ensureAccessibility()
            return
        }
        guard !presenter.hiddenWindowIDs.isEmpty else {
            NSSound.beep()   // nothing ticked — nothing to pin
            return
        }
        presenter.setPinned(true)
    }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleClickThrough() {
        mirror.clickThroughEnabled.toggle()
        if mirror.clickThroughEnabled && !Accessibility.trusted { ensureAccessibility() }
    }

    @objc private func grantAccessibility() {
        Accessibility.request()
        Accessibility.openSettings()
        ensureAccessibility()   // (re)start polling for the grant
    }

    // MARK: hotkey ⌥B
    private func registerHotkey() {
        // The global monitor only fires once the user grants Accessibility access;
        // the local monitor keeps the shortcut working while we are frontmost.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in _ = self?.handle(e) }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.handle(e) ?? e }
    }
    private func handle(_ e: NSEvent) -> NSEvent? {
        if e.keyCode == UInt16(kVK_ANSI_B) &&
            e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option {
            mirror.toggleWindow(); return nil
        }
        return e
    }
}

// MARK: – MirrorController --------------------------------------------------

/// Plain NSView that reports layout passes so the content layer can be kept
/// pixel-aligned while the window resizes.
final class PreviewView: NSView {
    var onLayout: (() -> Void)?
    override func layout() {
        super.layout()
        onLayout?()
    }
}

final class MirrorController: NSObject, SCStreamOutput, SCStreamDelegate, NSWindowDelegate {
    private(set) var currentDisplayID: CGDirectDisplayID

    // UI
    private let window: NSWindow
    private let previewView = PreviewView()
    /// Frames are drawn into this layer, whose frame is the aspect-fit rect
    /// snapped to the device pixel grid. Capturing at exactly this layer's
    /// pixel size means frames are shown 1:1 with no resampling — the whole
    /// crispness story hinges on it.
    private let contentLayer = CALayer()
    private static let frameAutosaveName = "ScreenInScreenPreview"

    // Capture
    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "app.screeninscreen.capture", qos: .userInitiated)
    private lazy var relay = FrameRelay(layer: contentLayer)

    // Remember frame in session
    private var lastFrame: NSRect?
    private var permissionAlertShown = false

    // Click-through
    private let forwarder = MouseForwarder()
    private static let clickThroughDefaultsKey = "ClickThroughEnabled"
    var clickThroughEnabled: Bool {
        didSet {
            UserDefaults.standard.set(clickThroughEnabled, forKey: Self.clickThroughDefaultsKey)
            refreshForwarding()
        }
    }

    init(displayID: CGDirectDisplayID) {
        currentDisplayID = displayID
        UserDefaults.standard.register(defaults: [Self.clickThroughDefaultsKey: true])
        clickThroughEnabled = UserDefaults.standard.bool(forKey: Self.clickThroughDefaultsKey)

        // window setup
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 500),
                          styleMask: [.titled, .resizable, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "ScreenInScreen — Preview"
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        // Invisible to all capture APIs — in presenter mode the audience must
        // never see our own UI mirrored onto the external display.
        window.sharingType = .none

        previewView.wantsLayer = true
        previewView.autoresizingMask = [.width, .height]
        previewView.layer?.backgroundColor = NSColor.black.cgColor

        // .resize (not .resizeAspect): the layer frame already *is* the
        // aspect-fit rect, so the image maps edge-to-edge onto it.
        contentLayer.contentsGravity = .resize
        contentLayer.magnificationFilter = .trilinear
        contentLayer.minificationFilter = .trilinear
        // Sublayers animate implicitly — a 0.25 s crossfade per video frame
        // and rubber-banding on every resize would ruin the preview.
        contentLayer.actions = ["contents": NSNull(), "bounds": NSNull(),
                                "position": NSNull(), "frame": NSNull()]
        previewView.layer?.addSublayer(contentLayer)
        window.contentView = previewView

        // ► immer im Vordergrund + in allen Spaces
        window.level = .floating
        window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])

        super.init()
        window.delegate = self

        // restore last session's geometry, else centre
        if !window.setFrameUsingName(Self.frameAutosaveName) { window.center() }
        window.setFrameAutosaveName(Self.frameAutosaveName)

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        forwarder.targetProvider = { [weak self] location in self?.forwardTarget(at: location) }
        previewView.onLayout = { [weak self] in self?.layoutContentLayer() }
        enforceAspectRatio()
        layoutContentLayer()
    }

    /// Lock window resizing to the mirrored display's aspect ratio and snap
    /// the current size to it (anchored at the top-left, so the window doesn't
    /// wander). Content ratio, not frame ratio — the title bar is extra.
    private func enforceAspectRatio() {
        let native = nativePixelSize()
        window.contentAspectRatio = NSSize(width: native.width, height: native.height)

        let content = window.contentRect(forFrameRect: window.frame)
        let height = (content.width * native.height / native.width).rounded()
        guard abs(height - content.height) > 0.5 else { return }
        var frame = window.frameRect(forContentRect:
            NSRect(x: content.minX, y: content.minY, width: content.width, height: height))
        frame.origin.y += window.frame.height - frame.height
        window.setFrame(frame, display: true)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: stream
    private func startStream(for id: CGDirectDisplayID) async {
        await stopStream()

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            // Almost always missing Screen Recording permission — tell the user
            // instead of leaving them with a black window.
            showPermissionAlert(error)
            return
        }
        guard let disp = content.displays.first(where: { $0.displayID == id }) else { return }

        let filter = SCContentFilter(display: disp, excludingWindows: [])
        let s = SCStream(filter: filter, configuration: makeConfiguration(), delegate: self)
        do {
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            try await s.startCapture()
            stream = s
        } catch {
            NSLog("ScreenInScreen: stream error — %@", error.localizedDescription)
        }
    }

    private func stopStream() async {
        guard let s = stream else { return }
        stream = nil
        try? await s.stopCapture()
        relay.clear()
    }

    // MARK: geometry — single source of truth for capture, layout & clicks

    private func nativePixelSize() -> CGSize {
        DisplayHelper.pixelSize(of: currentDisplayID)
    }

    private var backingScale: CGFloat { window.screen?.backingScaleFactor ?? 2 }

    /// The aspect-fit rect of the mirrored display inside `bounds`, snapped to
    /// the device pixel grid. Fractional edges would smear every frame across
    /// neighbouring pixels no matter how sharp the capture is.
    private func contentRect(in bounds: NSRect) -> NSRect {
        let native = nativePixelSize()
        guard bounds.width > 1, bounds.height > 1 else { return bounds }
        let fit = min(bounds.width / native.width, bounds.height / native.height)
        let size = NSSize(width: native.width * fit, height: native.height * fit)
        let raw = NSRect(x: bounds.midX - size.width / 2,
                         y: bounds.midY - size.height / 2,
                         width: size.width, height: size.height)
        let s = backingScale
        // Width/height snap to *even* pixel counts so the capture (which video
        // encoders want even-sized) can match the layer exactly, pixel for pixel.
        return NSRect(x: (raw.minX * s).rounded() / s,
                      y: (raw.minY * s).rounded() / s,
                      width: (raw.width * s / 2).rounded() * 2 / s,
                      height: (raw.height * s / 2).rounded() * 2 / s)
    }

    private func layoutContentLayer() {
        contentLayer.frame = contentRect(in: previewView.bounds)
    }

    private func makeConfiguration() -> SCStreamConfiguration {
        let cfg = SCStreamConfiguration()
        let size = captureSize()
        cfg.width = size.width
        cfg.height = size.height
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.queueDepth = 3
        cfg.showsCursor = true
        return cfg
    }

    /// Capture at exactly the content layer's size in device pixels, so frames
    /// are displayed 1:1 — any mismatch means a blurry fractional rescale.
    /// Capped at the display's native pixel size (upscaling invents nothing),
    /// with a floor so a tiny window doesn't degrade the source for later.
    private func captureSize() -> (width: Int, height: Int) {
        let native = nativePixelSize()
        let rect = contentRect(in: previewView.bounds)
        let scale = backingScale

        var w = rect.width * scale
        var h = rect.height * scale
        if w < 640 {
            w = 640
            h = (w * native.height / native.width).rounded()
        }
        if w > native.width || h > native.height {
            w = native.width
            h = native.height
        }
        // even dimensions keep the video encoders happy
        return (Int(w.rounded()) & ~1, Int(h.rounded()) & ~1)
    }

    /// Re-negotiate capture resolution after the window size changed.
    /// The configuration is built here, on the main thread, from live UI state.
    private func reconfigureForCurrentSize() {
        guard let s = stream else { return }
        let cfg = makeConfiguration()
        Task { [weak self] in
            if #available(macOS 14.0, *) {
                try? await s.updateConfiguration(cfg)
            } else {
                guard let self else { return }
                await self.startStream(for: self.currentDisplayID)
            }
        }
    }

    func switchDisplay(to id: CGDirectDisplayID) {
        guard id != currentDisplayID else { return }
        currentDisplayID = id
        enforceAspectRatio()   // aspect ratio may differ
        layoutContentLayer()
        guard window.isVisible else { return }
        Task { await startStream(for: id) }
    }

    /// The mirrored monitor may have been unplugged — fall back to a live one.
    @objc private func screensChanged() {
        defer {                          // resolution/aspect may have changed
            enforceAspectRatio()
            layoutContentLayer()
        }
        guard !DisplayHelper.active.contains(currentDisplayID),
              let fallback = DisplayHelper.selectable.first else { return }
        currentDisplayID = fallback
        guard window.isVisible else { return }
        Task { await startStream(for: fallback) }
    }

    // MARK: click-through mapping

    /// (Re)evaluate whether the event tap should be live. Cheap to call often.
    func refreshForwarding() {
        forwarder.wantsActive = clickThroughEnabled && window.isVisible && Accessibility.trusted
    }

    /// Mapping for a mouse event at `location` (CG global coordinates), or nil
    /// when the event should stay where it is.
    private func forwardTarget(at location: CGPoint) -> ForwardTarget? {
        guard clickThroughEnabled, window.isVisible,
              let target = currentForwardTarget(),
              target.imageRect.contains(location) else { return nil }

        // Only forward when the preview is actually the window that would be
        // hit — not when a menu, alert or another floating window covers it.
        let cocoaPoint = NSPoint(x: location.x, y: primaryDisplayHeight - location.y)
        guard NSWindow.windowNumber(at: cocoaPoint, belowWindowWithWindowNumber: 0) == window.windowNumber
        else { return nil }

        // Never redirect a click onto the preview itself (window overlaps the
        // region of the display it mirrors) — that way lies feedback weirdness.
        let remote = target.clamp(target.remotePoint(for: location))
        let remoteCocoa = NSPoint(x: remote.x, y: primaryDisplayHeight - remote.y)
        guard !window.frame.contains(remoteCocoa) else { return nil }

        return target
    }

    /// The preview's aspect-fit image area and the mirrored display, both in
    /// CG global coordinates. Nil while the geometry is degenerate.
    private func currentForwardTarget() -> ForwardTarget? {
        let display = CGDisplayBounds(currentDisplayID)
        let bounds = previewView.bounds
        guard display.width > 0, display.height > 0, bounds.width > 1, bounds.height > 1
        else { return nil }

        // Same rect the frames are rendered into — clicks and pixels agree.
        let rectInView = contentRect(in: bounds)
        let cocoaRect = window.convertToScreen(previewView.convert(rectInView, to: nil))
        let cgRect = CGRect(x: cocoaRect.minX,
                            y: primaryDisplayHeight - cocoaRect.maxY,
                            width: cocoaRect.width, height: cocoaRect.height)
        return ForwardTarget(imageRect: cgRect, displayBounds: display)
    }

    // MARK: window helpers
    func showWindow() {
        if let f = lastFrame { window.setFrame(f, display: true) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshForwarding()
        if stream == nil { Task { await startStream(for: currentDisplayID) } }
    }

    func toggleWindow() {
        if window.isVisible { hideWindow() } else { showWindow() }
    }

    /// Hiding the preview tears the capture down — a background stream would
    /// keep the GPU and the display's capture path busy for nothing.
    private func hideWindow() {
        lastFrame = window.frame
        window.orderOut(nil)
        refreshForwarding()
        Task { await stopStream() }
    }

    func shutDown() {
        guard let s = stream else { return }
        stream = nil
        s.stopCapture { _ in }
    }

    func windowWillClose(_ n: Notification) {
        lastFrame = window.frame
        // The window still counts as visible here — re-check once it's gone.
        DispatchQueue.main.async { [weak self] in self?.refreshForwarding() }
        Task { await stopStream() }
    }

    func windowDidEndLiveResize(_ n: Notification) { reconfigureForCurrentSize() }

    /// Zoom button / programmatic resizes never get a live-resize end.
    func windowDidResize(_ n: Notification) {
        guard !window.inLiveResize else { return }
        reconfigureForCurrentSize()
    }

    /// Dragged onto a display with a different scale factor — both the pixel
    /// alignment and the capture resolution are stale.
    func windowDidChangeBackingProperties(_ n: Notification) {
        layoutContentLayer()
        reconfigureForCurrentSize()
    }

    // MARK: SCStreamOutput
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        relay.handle(sb)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("ScreenInScreen: stream stopped — %@", error.localizedDescription)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.stream = nil
        }
    }

    // MARK: permission
    private func showPermissionAlert(_ error: Error) {
        NSLog("ScreenInScreen: shareable content unavailable — %@", error.localizedDescription)
        // startStream runs on a background executor; AppKit alerts must be
        // built and run on the main thread.
        DispatchQueue.main.async { [weak self] in self?.runPermissionAlert() }
    }

    private func runPermissionAlert() {
        guard !permissionAlertShown else { return }
        permissionAlertShown = true

        let alert = NSAlert()
        alert.messageText = "ScreenInScreen needs Screen Recording access"
        alert.informativeText = """
            Enable ScreenInScreen under System Settings ▸ Privacy & Security ▸ \
            Screen & System Audio Recording, then toggle the preview again.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        permissionAlertShown = false
    }
}

// MARK: – PresenterController ------------------------------------------------

/// The reverse of the preview mirror: shows the built-in Mac screen on an
/// external display, with chosen windows removed from the picture. Requires
/// the displays to be *extended* (not system-mirrored) — the output window
/// covers the external display while the user keeps working on the built-in
/// screen, and only what isn't hidden reaches the audience.
final class PresenterController: NSObject, SCStreamOutput, SCStreamDelegate {
    private(set) var isActive = false
    private(set) var outputDisplayID: CGDirectDisplayID?

    /// Windows the audience must not see. Session-scoped: window IDs don't
    /// survive an app relaunch, so persisting them would silently un-hide.
    private(set) var hiddenWindowIDs: Set<CGWindowID> = []

    /// How see-through hidden windows look on the presenter's own screen
    /// (0 = normal, opaque). Purely local — the audience never sees them.
    static let maxHiddenWindowTransparency: CGFloat = 0.9
    private static let transparencyDefaultsKey = "HiddenWindowTransparency"
    var hiddenWindowTransparency: CGFloat {
        didSet {
            UserDefaults.standard.set(Double(hiddenWindowTransparency), forKey: Self.transparencyDefaultsKey)
            veil.transparency = hiddenWindowTransparency
            pinner.alpha = 1 - hiddenWindowTransparency
            // Crossing zero starts/stops the veil's capture; any other change
            // is just an alpha tweak on the existing overlays.
            if (oldValue > 0) != (hiddenWindowTransparency > 0) { refreshVeil() }
        }
    }
    private let veil = HiddenWindowVeil()
    private var veilGeneration = 0

    /// Hidden windows pinned on top, click-through (session-only state).
    private(set) var isPinned = false
    private let pinner = WindowPinner()

    private var outputWindow: NSWindow?
    private let contentLayer = CALayer()
    private lazy var relay = FrameRelay(layer: contentLayer)
    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "app.screeninscreen.presenter", qos: .userInitiated)

    override init() {
        UserDefaults.standard.register(defaults: [Self.transparencyDefaultsKey: 0.3])
        let stored = CGFloat(UserDefaults.standard.double(forKey: Self.transparencyDefaultsKey))
        hiddenWindowTransparency = min(max(stored, 0), Self.maxHiddenWindowTransparency)
        super.init()
        veil.transparency = hiddenWindowTransparency
        pinner.alpha = 1 - hiddenWindowTransparency
        // A window parked or returned: the veil must stop/start covering it,
        // and the new overlay must be swept into the capture exclusions.
        pinner.onChange = { [weak self] in self?.refreshCaptureFilters() }
        contentLayer.contentsGravity = .resize
        contentLayer.magnificationFilter = .trilinear
        contentLayer.minificationFilter = .trilinear
        contentLayer.actions = ["contents": NSNull(), "bounds": NSNull(),
                                "position": NSNull(), "frame": NSNull()]
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: lifecycle
    func start(on displayID: CGDirectDisplayID) {
        guard !isActive else { return }
        guard let source = DisplayHelper.builtin, displayID != source,
              let screen = DisplayHelper.screen(for: displayID) else {
            presentAlert("Presenter Mode needs an external display",
                         """
                         Connect the external monitor in *extended* mode (not \
                         mirrored), then enable Presenter Mode again.
                         """)
            return
        }
        isActive = true
        outputDisplayID = displayID
        makeOutputWindow(on: screen)
        Task { await startStream() }
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        outputDisplayID = nil
        outputWindow?.orderOut(nil)
        outputWindow = nil
        Task { await stopStream() }
    }

    /// User picked a different display in the menu while presenting.
    func moveOutput(to displayID: CGDirectDisplayID) {
        guard isActive, displayID != outputDisplayID,
              displayID != DisplayHelper.builtin,
              let screen = DisplayHelper.screen(for: displayID) else { return }
        outputDisplayID = displayID
        outputWindow?.setFrame(screen.frame, display: true)
        layoutContentLayer()
        reconfigure()
    }

    // MARK: hidden windows
    func setHidden(_ ids: Set<CGWindowID>) {
        guard ids != hiddenWindowIDs else { return }
        hiddenWindowIDs = ids
        if isPinned { pinner.setTargets(ids) }   // newly ticked windows pin too
        refreshCaptureFilters()
    }

    /// Pin the hidden windows on top, click-through — or put them back.
    func setPinned(_ pinned: Bool) {
        isPinned = pinned
        pinner.setTargets(pinned ? hiddenWindowIDs : [])
    }

    /// Rebuild the veil's and the audience stream's filters from the current
    /// window set (our own windows, incl. fresh overlays, are excluded).
    private func refreshCaptureFilters() {
        refreshVeil()
        guard isActive, let s = stream else { return }
        Task { [weak self] in
            guard let self, let filter = await self.makeFilter() else { return }
            do { try await s.updateContentFilter(filter) }
            catch { await self.startStream() }   // stream died — rebuild it
        }
    }

    /// Bring the see-through overlays in line with the current state. The
    /// overlays are created synchronously, *before* any capture filter is
    /// built, so the filters' "exclude our own windows" sweep covers them.
    ///
    /// Deliberately independent of `isActive`: a ticked window looks
    /// see-through as soon as it's ticked, so the user can see what *will*
    /// be hidden before presenting (and without a monitor attached).
    ///
    /// Parked (pinned) windows are skipped — their pinned copy carries the
    /// transparency instead.
    private func refreshVeil() {
        let targets = hiddenWindowTransparency > 0 ? hiddenWindowIDs.subtracting(pinner.parkedIDs) : []
        veil.setTargets(targets)
        veilGeneration += 1
        guard !targets.isEmpty else { return }
        let generation = veilGeneration
        Task { [weak self] in
            guard let self, let filter = await self.makeFilter() else { return }
            await MainActor.run {
                // A newer refresh overtook this one — its filter is stale.
                guard generation == self.veilGeneration else { return }
                self.veil.apply(filter)
            }
        }
    }

    // MARK: output window
    private func makeOutputWindow(on screen: NSScreen) {
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                         backing: .buffered, defer: false)
        w.backgroundColor = .black
        w.isOpaque = true
        w.isReleasedWhenClosed = false
        w.ignoresMouseEvents = true   // stray clicks fall through, never trapped
        // Every display gets its own translucent system menu bar, drawn above
        // .floating windows — only the shielding level (kiosk apps use it)
        // covers the whole screen including that menu bar.
        w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.sharingType = .none         // uncapturable — no hall-of-mirrors, ever

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.layer?.addSublayer(contentLayer)
        w.contentView = view
        outputWindow = w
        layoutContentLayer()
        w.orderFrontRegardless()
    }

    /// Aspect-fit the built-in screen's image on the output display, snapped
    /// to its pixel grid (same crispness rules as the preview mirror).
    private func layoutContentLayer() {
        guard let view = outputWindow?.contentView,
              let source = DisplayHelper.builtin else { return }
        let native = DisplayHelper.pixelSize(of: source)
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }

        let fit = min(bounds.width / native.width, bounds.height / native.height)
        let raw = NSRect(x: bounds.midX - native.width * fit / 2,
                         y: bounds.midY - native.height * fit / 2,
                         width: native.width * fit, height: native.height * fit)
        let s = outputWindow?.screen?.backingScaleFactor ?? 1
        contentLayer.frame = NSRect(x: (raw.minX * s).rounded() / s,
                                    y: (raw.minY * s).rounded() / s,
                                    width: (raw.width * s / 2).rounded() * 2 / s,
                                    height: (raw.height * s / 2).rounded() * 2 / s)
        // Frames get Lanczos-resampled to exactly the layer's pixel size, so
        // the final composite is a 1:1 blit onto the output's pixel grid.
        relay.setTargetPixelSize(CGSize(width: contentLayer.frame.width * s,
                                        height: contentLayer.frame.height * s))
    }

    // MARK: stream
    private func makeFilter() async -> SCContentFilter? {
        guard let source = DisplayHelper.builtin,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
              let disp = content.displays.first(where: { $0.displayID == source })
        else { return nil }

        // Fetched with onScreenWindowsOnly:false so a hidden window that is
        // currently minimised stays excluded when it comes back.
        let pid = ProcessInfo.processInfo.processIdentifier
        let excluded = content.windows.filter { w in
            hiddenWindowIDs.contains(w.windowID) || w.owningApplication?.processID == pid
        }
        return SCContentFilter(display: disp, excludingWindows: excluded)
    }

    private func makeConfiguration() -> SCStreamConfiguration {
        let cfg = SCStreamConfiguration()
        let size = captureSize()
        cfg.width = size.width
        cfg.height = size.height
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.queueDepth = 3
        cfg.showsCursor = true        // the audience should see the pointer
        return cfg
    }

    /// Capture at the built-in screen's full native resolution: asking the
    /// capture pipeline for a pre-shrunk frame hands the scaling to its
    /// mediocre scaler. The relay's Lanczos pass does the one downscale to
    /// the output's pixel grid instead, which keeps text crisp.
    private func captureSize() -> (width: Int, height: Int) {
        guard let source = DisplayHelper.builtin else { return (1920, 1080) }
        let native = DisplayHelper.pixelSize(of: source)
        return (Int(native.width) & ~1, Int(native.height) & ~1)
    }

    private func startStream() async {
        await stopStream()
        guard isActive, let filter = await makeFilter() else { return }
        let s = SCStream(filter: filter, configuration: makeConfiguration(), delegate: self)
        do {
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            try await s.startCapture()
            stream = s
        } catch {
            NSLog("ScreenInScreen: presenter stream error — %@", error.localizedDescription)
        }
    }

    private func stopStream() async {
        guard let s = stream else { return }
        stream = nil
        try? await s.stopCapture()
        relay.clear()
    }

    private func reconfigure() {
        guard let s = stream else { return }
        let cfg = makeConfiguration()
        Task { [weak self] in
            if #available(macOS 14.0, *) {
                try? await s.updateConfiguration(cfg)
            } else {
                await self?.startStream()
            }
        }
    }

    /// Output display unplugged or resolutions changed.
    @objc private func screensChanged() {
        // The built-in screen's resolution may have changed — rebuild the
        // veil's capture from scratch (rare event, simplest correct path).
        veil.setTargets([])
        refreshVeil()

        guard isActive else { return }
        guard let out = outputDisplayID,
              let screen = DisplayHelper.screen(for: out),
              DisplayHelper.builtin != nil else {
            stop()
            return
        }
        outputWindow?.setFrame(screen.frame, display: true)
        layoutContentLayer()
        reconfigure()
    }

    // MARK: SCStreamOutput / delegate
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        relay.handle(sb)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("ScreenInScreen: presenter stream stopped — %@", error.localizedDescription)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.stream = nil
        }
    }

    private func presentAlert(_ message: String, _ info: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

// MARK: – Hidden-window veil --------------------------------------------------

/// Makes windows hidden from the audience look see-through on the presenter's
/// own (built-in) screen, so it's obvious at a glance what the room can't see.
///
/// macOS offers no public way to change another app's window alpha, so the
/// effect is composited: a click-through overlay sits *directly* above each
/// hidden window and shows, at partial opacity, what lies behind it — taken
/// from a capture of the built-in screen that already excludes the hidden
/// windows. Blending "window" with "what's behind the window" is exactly what
/// translucency looks like. All main-thread except the sample handler.
final class HiddenWindowVeil: NSObject, SCStreamOutput, SCStreamDelegate {
    var transparency: CGFloat = 0 {
        didSet { overlays.values.forEach { $0.window.alphaValue = transparency } }
    }

    private final class Overlay {
        let window: NSWindow
        /// Shows the whole built-in screen, positioned so that the part under
        /// the hidden window lines up; the window's bounds clip the rest.
        let backdrop = CALayer()

        init(alpha: CGFloat, surface: IOSurface?) {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                              styleMask: .borderless, backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true   // every click lands on the real window
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            window.sharingType = .none         // never in any capture — no feedback loop
            window.alphaValue = alpha
            window.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]

            let view = NSView()
            view.wantsLayer = true
            view.layer?.masksToBounds = true
            backdrop.contentsGravity = .resize
            backdrop.actions = ["contents": NSNull(), "bounds": NSNull(),
                                "position": NSNull(), "frame": NSNull()]
            backdrop.contents = surface
            view.layer?.addSublayer(backdrop)
            window.contentView = view
        }
    }

    private var overlays: [CGWindowID: Overlay] = [:]
    private var stream: SCStream?
    private var trackTimer: Timer?
    private var surface: IOSurface?   // newest backdrop frame (main thread)

    private let sampleQueue = DispatchQueue(label: "app.screeninscreen.veil", qos: .userInitiated)
    private lazy var relay = SurfaceRelay { [weak self] next in
        guard let self, self.stream != nil else { return }
        self.surface = next
        self.overlays.values.forEach { $0.backdrop.contents = next }
    }

    // MARK: targets

    /// Windows to veil. Empty stops everything. Overlays exist as soon as this
    /// returns, so a capture filter built afterwards excludes them.
    func setTargets(_ ids: Set<CGWindowID>) {
        for (id, overlay) in overlays where !ids.contains(id) {
            overlay.window.orderOut(nil)
            overlays[id] = nil
        }
        for id in ids where overlays[id] == nil {
            overlays[id] = Overlay(alpha: transparency, surface: surface)
        }
        if overlays.isEmpty { stop() } else { startTracking() }
    }

    /// Capture filter of the built-in screen minus the hidden windows (and
    /// minus our own windows) — what's *behind* every hidden window.
    func apply(_ filter: SCContentFilter) {
        guard !overlays.isEmpty else { return }
        if let s = stream {
            s.updateContentFilter(filter) { [weak self] error in
                guard error != nil else { return }
                DispatchQueue.main.async {   // stream died — rebuild it
                    guard let self, self.stream === s else { return }
                    self.stream = nil
                    self.apply(filter)
                }
            }
            return
        }
        guard let source = DisplayHelper.builtin else { return }
        let s = SCStream(filter: filter, configuration: makeConfiguration(for: source), delegate: self)
        do {
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        } catch {
            NSLog("ScreenInScreen: veil stream error — %@", error.localizedDescription)
            return
        }
        stream = s
        s.startCapture { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    NSLog("ScreenInScreen: veil capture failed — %@", error.localizedDescription)
                    if self.stream === s { self.stream = nil }
                } else if self.stream !== s {
                    s.stopCapture { _ in }   // stopped while starting up
                }
            }
        }
    }

    private func stop() {
        trackTimer?.invalidate()
        trackTimer = nil
        overlays.values.forEach { $0.window.orderOut(nil) }
        overlays = [:]
        surface = nil
        if let s = stream {
            stream = nil
            s.stopCapture { _ in }
        }
    }

    private func makeConfiguration(for display: CGDirectDisplayID) -> SCStreamConfiguration {
        let cfg = SCStreamConfiguration()
        // Native pixels, so the backdrop maps 1:1 onto the real screen.
        let native = DisplayHelper.pixelSize(of: display)
        cfg.width = Int(native.width) & ~1
        cfg.height = Int(native.height) & ~1
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        // The display's own colour space: the backdrop must match the pixels
        // around it exactly, or the window's outline would show as a tint.
        if let name = CGDisplayCopyColorSpace(display).name {
            cfg.colorSpaceName = name
        }
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.queueDepth = 4
        cfg.showsCursor = false   // the real cursor is right there already
        return cfg
    }

    // MARK: tracking

    private func startTracking() {
        guard trackTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.track() }
        RunLoop.main.add(t, forMode: .common)
        trackTimer = t
        track()
    }

    /// Follow each hidden window's position, level, Space and stacking order.
    private func track() {
        guard let source = DisplayHelper.builtin else { return }
        let d = CGDisplayBounds(source)
        let mainHeight = primaryDisplayHeight
        let displayRect = NSRect(x: d.minX, y: mainHeight - d.maxY, width: d.width, height: d.height)

        for (id, overlay) in overlays {
            let w = overlay.window
            guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?.first,
                  (info[kCGWindowIsOnscreen as String] as? Bool) == true,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else {
                // Closed, minimised or on another Space.
                if w.isVisible { w.orderOut(nil) }
                continue
            }
            let frame = NSRect(x: b.minX, y: mainHeight - b.maxY, width: b.width, height: b.height)
            guard frame.intersects(displayRect) else {
                if w.isVisible { w.orderOut(nil) }
                continue
            }

            if w.frame != frame { w.setFrame(frame, display: false) }
            let backdropFrame = displayRect.offsetBy(dx: -frame.minX, dy: -frame.minY)
            if overlay.backdrop.frame != backdropFrame { overlay.backdrop.frame = backdropFrame }

            let level = NSWindow.Level(rawValue: info[kCGWindowLayer as String] as? Int ?? 0)
            if w.level != level { w.level = level }
            // Left behind on another Space: re-ordering in moves it to this one.
            if w.isVisible && !w.isOnActiveSpace { w.orderOut(nil) }
            if !w.isVisible || !isDirectlyAbove(CGWindowID(w.windowNumber), id) {
                w.order(.above, relativeTo: Int(id))
            }
        }
    }

    /// True when `target` is the very next on-screen window below `overlay`.
    /// Anything in between (the user clicked another window, or the hidden
    /// window was raised) means the overlay would be drawn over the wrong
    /// window — or under the right one.
    private func isDirectlyAbove(_ overlay: CGWindowID, _ target: CGWindowID) -> Bool {
        guard let below = CGWindowListCopyWindowInfo([.optionOnScreenBelowWindow, .excludeDesktopElements],
                                                     overlay) as? [[String: Any]],
              let next = below.first?[kCGWindowNumber as String] as? Int
        else { return false }
        return CGWindowID(next) == target
    }

    // MARK: SCStreamOutput / delegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        relay.handle(sb)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("ScreenInScreen: veil stream stopped — %@", error.localizedDescription)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.stream = nil
        }
    }
}

// MARK: – Window pinning ------------------------------------------------------

/// Private but long-stable (Rectangle, yabai, AeroSpace rely on it): the only
/// reliable bridge from an Accessibility window element to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Pins windows "on top, click-through": the window stays visible where it
/// was, floats above everything, and every click lands on whatever is behind
/// it — as if it weren't there.
///
/// No public API can raise another app's window to a floating level or make
/// it ignore the mouse, so the pinned window is a *live copy*: a floating,
/// click-through overlay of ours shows a capture of the real window, while
/// the real window is parked in a screen corner (all but one point off-screen)
/// out of the way of clicks. Unpinning moves it back. Main thread only.
final class WindowPinner {
    var alpha: CGFloat = 1 {
        didSet { pins.values.forEach { $0.overlay.alphaValue = alpha } }
    }
    /// Fired whenever a window was parked or came back.
    var onChange: () -> Void = {}

    /// Windows currently parked behind a pinned copy.
    var parkedIDs: Set<CGWindowID> { Set(pins.filter { $0.value.isParked }.keys) }

    private var pins: [CGWindowID: Pin] = [:]

    /// Windows to pin. Windows not on screen right now (minimised, other
    /// Space) are skipped; anything dropped from the set is put back.
    func setTargets(_ ids: Set<CGWindowID>) {
        var changed = false
        for (id, pin) in pins where !ids.contains(id) {
            changed = changed || pin.isParked
            pin.release()
            pins[id] = nil
        }
        for id in ids where pins[id] == nil {
            guard let pin = Pin(windowID: id, alpha: alpha) else { continue }
            pin.onParked = { [weak self] in self?.onChange() }
            pin.onGone = { [weak self, weak pin] in
                guard let self, let pin, self.pins[id] === pin else { return }
                self.pins[id] = nil
                self.onChange()
            }
            pins[id] = pin
        }
        if changed { onChange() }
    }
}

private final class Pin: NSObject, SCStreamOutput, SCStreamDelegate {
    let windowID: CGWindowID
    let overlay: NSWindow
    private(set) var isParked = false
    var onParked: () -> Void = {}
    var onGone: () -> Void = {}

    private let element: AXUIElement
    private let home: CGPoint          // original top-left, CG global coordinates
    private let size: CGSize
    private let content = CALayer()
    private var stream: SCStream?
    private var released = false
    private let sampleQueue = DispatchQueue(label: "app.screeninscreen.pin", qos: .userInitiated)
    private lazy var relay = SurfaceRelay { [weak self] surface in self?.show(surface) }

    init?(windowID: CGWindowID, alpha: CGFloat) {
        guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]])?.first,
              (info[kCGWindowIsOnscreen as String] as? Bool) == true,
              let pid = info[kCGWindowOwnerPID as String] as? pid_t,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
              let element = Self.axWindow(pid: pid, windowID: windowID)
        else { return nil }

        self.windowID = windowID
        self.element = element
        home = bounds.origin
        size = bounds.size
        // An app that hangs must not freeze us for AX's default 6 s.
        AXUIElementSetMessagingTimeout(element, 1)

        let frame = NSRect(x: bounds.minX, y: primaryDisplayHeight - bounds.maxY,
                           width: bounds.width, height: bounds.height)
        overlay = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        overlay.isOpaque = false
        overlay.backgroundColor = .clear       // rounded corners stay rounded
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true      // the whole point: clicks go behind
        overlay.isReleasedWhenClosed = false
        overlay.animationBehavior = .none
        overlay.sharingType = .none            // still hidden from the audience
        overlay.level = .floating              // above whatever becomes active
        overlay.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        overlay.alphaValue = alpha

        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        content.frame = view.bounds
        content.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        content.contentsGravity = .resize
        content.actions = ["contents": NSNull(), "bounds": NSNull(),
                           "position": NSNull(), "frame": NSNull()]
        view.layer?.addSublayer(content)
        overlay.contentView = view

        super.init()
        startCapture(scale: NSScreen.screens.first { $0.frame.intersects(frame) }?.backingScaleFactor ?? 2)
    }

    private static func axWindow(pid: pid_t, windowID: CGWindowID) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first { w in
            var id: CGWindowID = 0
            return _AXUIElementGetWindow(w, &id) == .success && id == windowID
        }
    }

    // MARK: capture

    private func startCapture(scale: CGFloat) {
        Task { @MainActor [weak self] in
            let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let self, !self.released else { return }
            guard let scWindow = content?.windows.first(where: { $0.windowID == self.windowID }) else {
                self.fail("window not capturable")
                return
            }
            let cfg = SCStreamConfiguration()
            cfg.width = Int((self.size.width * scale).rounded())
            cfg.height = Int((self.size.height * scale).rounded())
            cfg.scalesToFit = true
            cfg.pixelFormat = kCVPixelFormatType_32BGRA   // keeps the corners' alpha
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            cfg.queueDepth = 4
            cfg.showsCursor = false
            if #available(macOS 14.0, *) {
                cfg.ignoreShadowsSingleWindow = true      // frame == window bounds
                cfg.captureResolution = .best
            }
            let s = SCStream(filter: SCContentFilter(desktopIndependentWindow: scWindow),
                             configuration: cfg, delegate: self)
            do {
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.sampleQueue)
                self.stream = s
                try await s.startCapture()
            } catch {
                self.fail(error.localizedDescription)
                return
            }
            if self.released { try? await s.stopCapture() }
        }
    }

    /// First frame: put the copy exactly over the real window, *then* move
    /// the real one away — the swap is invisible.
    private func show(_ surface: IOSurface) {
        guard !released, stream != nil else { return }
        content.contents = surface
        guard !isParked else { return }
        overlay.orderFrontRegardless()
        guard move(to: Self.parkingOrigin(for: size)) else {
            fail("could not move window")
            return
        }
        isParked = true
        onParked()
    }

    /// Bottom-right (else bottom-left) corner of a display where the parked
    /// window overlaps no *other* display. macOS won't let a window leave the
    /// screens entirely; the remaining one-point sliver also keeps the app
    /// treating the window as visible, so it keeps rendering — and the copy
    /// stays live.
    private static func parkingOrigin(for size: CGSize) -> CGPoint {
        let displays = DisplayHelper.active.map { CGDisplayBounds($0) }
        let preferred = DisplayHelper.builtin.map { [CGDisplayBounds($0)] } ?? []
        for d in preferred + displays {
            for origin in [CGPoint(x: d.maxX - 1, y: d.maxY - 1),
                           CGPoint(x: d.minX - size.width + 1, y: d.maxY - 1)] {
                let rect = CGRect(origin: origin, size: size)
                if !displays.contains(where: { $0 != d && $0.intersects(rect) }) { return origin }
            }
        }
        let d = displays.first ?? .zero
        return CGPoint(x: d.maxX - 1, y: d.maxY - 1)
    }

    private func move(to point: CGPoint) -> Bool {
        var p = point
        guard let value = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
    }

    // MARK: teardown

    /// Put the real window back and drop the copy.
    func release() {
        guard !released else { return }
        released = true
        if let s = stream {
            stream = nil
            s.stopCapture { _ in }
        }
        if isParked {
            isParked = false
            _ = move(to: home)
        }
        // A beat later, so the real window has redrawn under the copy.
        let overlay = self.overlay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { overlay.orderOut(nil) }
    }

    private func fail(_ reason: String) {
        NSLog("ScreenInScreen: could not pin window %u — %@", windowID, reason)
        release()
        onGone()
    }

    // MARK: SCStreamOutput / delegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        relay.handle(sb)
    }

    /// Typically: the window was closed.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.stream = nil
            self.fail(error.localizedDescription)
        }
    }
}

// MARK: – Window picker -------------------------------------------------------

/// Button (checkbox) that reacts to the first click while its window is not key.
/// The picker is a non-activating panel, which never becomes key for a
/// button click — a stock NSButton would swallow that click doing nothing.
private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { false }
}

/// Same first-click story as `FirstMouseButton`, for the transparency slider.
private final class FirstMouseSlider: NSSlider {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { false }
}

/// Row cell that can be updated in place. Rebuilding cells (reloadData) while
/// the user is clicking kills the click mid-tracking — cells must be reused
/// and mutated, never replaced, when the row set hasn't changed.
private final class WindowCellView: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("WindowCellView")
    let check = FirstMouseButton()
    private let appIcon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseID
        check.setButtonType(.switch)
        check.title = ""
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 12)

        // Fully determined layout: checkbox and icon keep their natural size,
        // the label absorbs all remaining width and truncates. With any slack
        // (e.g. a "≤" trailing pin) Auto Layout resolves an overlong title by
        // breaking the *leading* pin instead — shifting the checkbox out of
        // its clickable position.
        check.setContentCompressionResistancePriority(.required, for: .horizontal)
        check.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [check, appIcon, label])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            appIcon.widthAnchor.constraint(equalToConstant: 18),
            appIcon.heightAnchor.constraint(equalToConstant: 18),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(with entry: WindowPickerController.Entry, hidden: Bool,
                   target: AnyObject?, action: Selector) {
        // The window ID travels on the button itself — resolving the row at
        // action time is fragile once rows have moved or reloaded.
        check.tag = Int(entry.windowID)
        check.target = target
        check.action = action
        let wanted: NSControl.StateValue = hidden ? .on : .off
        if check.state != wanted { check.state = wanted }
        appIcon.image = entry.icon
        let text = entry.isOnScreen ? "\(entry.appName) — \(entry.title)"
                                    : "\(entry.appName) — \(entry.title)  (not on screen)"
        if label.stringValue != text { label.stringValue = text }
        label.textColor = entry.isOnScreen ? .labelColor : .secondaryLabelColor
    }
}

/// Floating checklist of the windows on screen; ticked ones are hidden from
/// the presenter mirror. The panel itself is non-activating (clicks don't
/// yank focus from the app being presented) and uncapturable.
final class WindowPickerController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    struct Entry {
        let windowID: CGWindowID
        let appName: String
        let title: String
        let icon: NSImage?
        let isOnScreen: Bool   // false: minimised or on another Space
    }

    var isHidden: (CGWindowID) -> Bool = { _ in false }
    var onToggle: (CGWindowID, Bool) -> Void = { _, _ in }
    var transparency: () -> CGFloat = { 0 }
    var onTransparencyChange: (CGFloat) -> Void = { _ in }
    /// The stored pin-on-top shortcut, if any.
    var pinShortcut: () -> KeyShortcut? = { nil }
    /// New shortcut (nil: cleared). Returns false if it couldn't be bound.
    var onPinShortcutChange: (KeyShortcut?) -> Bool = { _ in true }
    /// The global hotkey must be off while recording, or pressing the current
    /// combination would trigger it instead of being recorded.
    var onRecordingShortcut: (Bool) -> Void = { _ in }

    private var entries: [Entry] = []
    private let table = NSTableView()
    private let transparencySlider = FirstMouseSlider()
    private let transparencyValue = NSTextField(labelWithString: "")
    private let shortcutButton = FirstMouseButton()
    private var recordingMonitor: Any?
    private var refreshTimer: Timer?
    private var panelBuilt = false

    private lazy var panel: NSPanel = {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 440),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.title = "Hidden Windows"
        p.isReleasedWhenClosed = false
        // Above the .floating preview window: if the preview overlapped the
        // panel, clicks in the overlap would hit the preview and be forwarded
        // to the monitor instead of ticking the checkbox.
        p.level = .modalPanel
        p.sharingType = .none   // never visible to the audience
        p.delegate = self
        p.minSize = NSSize(width: 300, height: 240)

        let label = NSTextField(wrappingLabelWithString:
            "Ticked windows are hidden from the audience and look see-through on your screen. The list refreshes automatically.")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        // How see-through hidden windows look on *your* screen. The audience
        // is unaffected either way — for them the windows are simply gone.
        let sliderTitle = NSTextField(labelWithString: "See-through on your screen:")
        sliderTitle.font = .systemFont(ofSize: 11)
        sliderTitle.setContentHuggingPriority(.required, for: .horizontal)
        sliderTitle.setContentCompressionResistancePriority(.required, for: .horizontal)
        transparencySlider.minValue = 0
        transparencySlider.maxValue = Double(PresenterController.maxHiddenWindowTransparency)
        transparencySlider.isContinuous = true
        transparencySlider.controlSize = .small
        transparencySlider.target = self
        transparencySlider.action = #selector(transparencyChanged(_:))
        transparencySlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        transparencyValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        transparencyValue.textColor = .secondaryLabelColor
        transparencyValue.alignment = .right
        let sliderRow = NSStackView(views: [sliderTitle, transparencySlider, transparencyValue])
        sliderRow.orientation = .horizontal
        sliderRow.spacing = 8
        sliderRow.translatesAutoresizingMaskIntoConstraints = false

        // Shortcut that pins the hidden windows on top, click-through.
        let shortcutTitle = NSTextField(labelWithString: "Pin on top, click-through:")
        shortcutTitle.font = .systemFont(ofSize: 11)
        shortcutTitle.setContentHuggingPriority(.required, for: .horizontal)
        shortcutButton.bezelStyle = .rounded
        shortcutButton.controlSize = .small
        shortcutButton.font = .systemFont(ofSize: 11)
        shortcutButton.target = self
        shortcutButton.action = #selector(shortcutButtonClicked)
        shortcutButton.toolTip = "Click, then press the shortcut. ⌫ removes it, Esc cancels."
        let shortcutRow = NSStackView(views: [shortcutTitle, shortcutButton, NSView()])
        shortcutRow.orientation = .horizontal
        shortcutRow.spacing = 8
        shortcutRow.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("window"))
        // The single column must always span the table, whatever the panel
        // width — cells are laid out against the column width, not the panel.
        column.resizingMask = .autoresizingMask
        column.minWidth = 120
        column.maxWidth = 100_000
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.headerView = nil
        table.rowHeight = 26
        table.style = .inset
        table.dataSource = self
        table.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(label)
        content.addSubview(sliderRow)
        content.addSubview(shortcutRow)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            sliderRow.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            sliderRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            sliderRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            transparencyValue.widthAnchor.constraint(equalToConstant: 34),
            shortcutRow.topAnchor.constraint(equalTo: sliderRow.bottomAnchor, constant: 6),
            shortcutRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            shortcutRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            shortcutButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),
            scroll.topAnchor.constraint(equalTo: shortcutRow.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        p.contentView = content
        if !p.setFrameUsingName("ScreenInScreenPicker") { p.center() }
        p.setFrameAutosaveName("ScreenInScreenPicker")
        panelBuilt = true
        return p
    }()

    func show() {
        panel.orderFront(nil)
        transparencySlider.doubleValue = Double(transparency())
        updateTransparencyLabel()
        updateShortcutButton()
        refresh()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func close() { if panelBuilt { panel.close() } }

    func windowWillClose(_ n: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        stopRecording()
    }

    func windowDidResignKey(_ n: Notification) { stopRecording() }

    // MARK: shortcut recording

    private var isRecording: Bool { recordingMonitor != nil }

    @objc private func shortcutButtonClicked() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        onRecordingShortcut(true)
        // A non-activating panel can still take keyboard focus — without
        // pulling the presented app out of the foreground.
        panel.makeKey()
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.record(event)
            return nil   // swallow: nothing else should react while recording
        }
        updateShortcutButton()
    }

    private func record(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch Int(event.keyCode) {
        case kVK_Escape:
            stopRecording()
        case kVK_Delete where flags.isEmpty, kVK_ForwardDelete where flags.isEmpty:
            _ = onPinShortcutChange(nil)
            stopRecording()
        default:
            // Plain keys would hijack normal typing system-wide.
            guard let shortcut = KeyShortcut(event: event), onPinShortcutChange(shortcut) else {
                NSSound.beep()
                return   // keep listening for a usable combination
            }
            stopRecording()
        }
    }

    private func stopRecording() {
        guard let monitor = recordingMonitor else { return }
        NSEvent.removeMonitor(monitor)
        recordingMonitor = nil
        onRecordingShortcut(false)
        updateShortcutButton()
    }

    private func updateShortcutButton() {
        shortcutButton.title = isRecording ? "Type shortcut…" : (pinShortcut()?.display ?? "Set Shortcut")
    }

    // MARK: list
    private func refresh() {
        // Never move rows around under the user's hands: skip the periodic
        // refresh while a mouse button is down or the cursor is over the
        // panel (except the very first population).
        if !entries.isEmpty {
            if NSEvent.pressedMouseButtons != 0 { return }
            if panel.isVisible, panel.frame.contains(NSEvent.mouseLocation) { return }
        }

        Task { @MainActor [weak self] in
            guard let self,
                  // All windows, not just visible ones — a minimised window
                  // must be hideable *before* it reappears on stage.
                  let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            else { return }

            let pid = ProcessInfo.processInfo.processIdentifier
            var fresh: [Entry] = []
            for w in content.windows {
                // Real, user-facing windows only: no menu bar items, no system
                // chrome (layer ≠ 0), no untitled utility surfaces, not us.
                guard let app = w.owningApplication, app.processID != pid,
                      w.windowLayer == 0,
                      let title = w.title, !title.isEmpty,
                      w.frame.width >= 60, w.frame.height >= 40 else { continue }
                let running = NSRunningApplication(processIdentifier: app.processID)
                // Off-screen windows are noisy (apps keep invisible titled
                // windows around) — list them only for ordinary Dock apps.
                if !w.isOnScreen, running?.activationPolicy != .regular { continue }
                fresh.append(Entry(windowID: w.windowID,
                                   appName: app.applicationName,
                                   title: title,
                                   icon: running?.icon,
                                   isOnScreen: w.isOnScreen))
            }
            fresh.sort {
                $0.appName == $1.appName ? $0.title < $1.title
                                         : $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
            }

            let sameRows = fresh.map(\.windowID) == self.entries.map(\.windowID)
            self.entries = fresh
            if sameRows {
                // Title/icon updates only — mutate cells in place so clicks
                // being tracked and the scroll position survive untouched.
                for (row, entry) in fresh.enumerated() {
                    if let cell = self.table.view(atColumn: 0, row: row, makeIfNecessary: false) as? WindowCellView {
                        cell.configure(with: entry, hidden: self.isHidden(entry.windowID),
                                       target: self, action: #selector(self.checkboxToggled(_:)))
                    }
                }
            } else {
                self.table.reloadData()
            }
        }
    }

    // MARK: table
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < entries.count else { return nil }
        let cell = tableView.makeView(withIdentifier: WindowCellView.reuseID, owner: nil) as? WindowCellView
            ?? WindowCellView()
        cell.configure(with: entries[row], hidden: isHidden(entries[row].windowID),
                       target: self, action: #selector(checkboxToggled(_:)))
        return cell
    }

    @objc private func checkboxToggled(_ sender: NSButton) {
        onToggle(CGWindowID(sender.tag), sender.state == .on)
    }

    @objc private func transparencyChanged(_ sender: NSSlider) {
        // Snap to whole percent so the label and the stored value agree.
        let value = (sender.doubleValue * 100).rounded() / 100
        onTransparencyChange(CGFloat(value))
        updateTransparencyLabel()
    }

    private func updateTransparencyLabel() {
        let percent = Int((transparencySlider.doubleValue * 100).rounded())
        transparencyValue.stringValue = percent == 0 ? "Off" : "\(percent)%"
    }
}
