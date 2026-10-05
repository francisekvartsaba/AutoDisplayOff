//
// AutoDisplayOff
//
// Menu-bar utility for macOS that automatically switches the built-in
// display OFF (not just black — actually disabled at the WindowServer
// level, same as real clamshell mode) whenever an external display is
// connected, and switches it back ON when the external display is
// removed. Unlike closing the lid, the keyboard/trackpad keep working
// and the lid can stay open the whole time.
//
// Click the menu-bar icon to open a small window with the current
// status, a switch to turn the automatic behaviour on/off, and a
// manual "toggle now" button.
//
// HOW IT WORKS
// ------------
// macOS has no public API for "disable this one display but keep the
// lid open". The mechanism used here — SLSConfigureDisplayEnabled /
// CGSConfigureDisplayEnabled — is a *private*, undocumented API from
// SkyLight.framework (WindowServer's private framework). It is the same
// primitive that professional display-management utilities have relied
// on for years to fully power down a display's output. Being private:
//   * it needs no special entitlement or code signature to call,
//   * but Apple can change or remove it in any macOS release,
//   * and it is not eligible for Mac App Store distribution.
// This is an accepted, understood trade-off for a personal utility —
// not a bug in this implementation.
//
// SAFETY
// ------
// If we ever disable the internal display and then lose track of the
// external one (crash, quit, cable pulled at the wrong instant), the
// user must not be left staring at a black laptop screen with no way
// to get it back. To guard against that this app:
//   1. Immediately re-enables the internal display the moment the
//      external display count drops to zero.
//   2. Re-enables the internal display on normal or abnormal quit, and
//      whenever the automatic mode is switched off.
//   3. Runs a periodic safety-check timer that force-restores the
//      internal display if it is off but no external display is
//      present (covers races the reconfiguration callback might miss).
//
import AppKit
import SwiftUI
import Combine
import CoreGraphics

// MARK: - Private API bridging

private enum PrivateAPI {
    typealias ConfigureDisplayEnabledFn = @convention(c) (OpaquePointer?, CGDirectDisplayID, Int32) -> CGError

    static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    static let configureDisplayEnabled: ConfigureDisplayEnabledFn? = {
        for name in ["SLSConfigureDisplayEnabled", "CGSConfigureDisplayEnabled"] {
            if let sym = dlsym(skyLight, name) {
                return unsafeBitCast(sym, to: ConfigureDisplayEnabledFn.self)
            }
        }
        return nil
    }()
}

/// Enables or disables one display at the WindowServer level, inside its own
/// display-configuration transaction. Returns true on success.
@discardableResult
private func setDisplay(_ displayID: CGDirectDisplayID, enabled: Bool) -> Bool {
    guard let fn = PrivateAPI.configureDisplayEnabled else {
        NSLog("AutoDisplayOff: private API not available on this macOS version")
        return false
    }
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success else { return false }
    let result = fn(config, displayID, enabled ? 1 : 0)
    guard result == .success else {
        CGCancelDisplayConfiguration(config)
        return false
    }
    return CGCompleteDisplayConfiguration(config, .forSession) == .success
}

// MARK: - Display enumeration helpers

private func onlineDisplayIDs() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    guard count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    return ids
}

private func internalDisplayID() -> CGDirectDisplayID? {
    onlineDisplayIDs().first { CGDisplayIsBuiltin($0) != 0 }
}

private func externalDisplayCount(excluding builtinID: CGDirectDisplayID?) -> Int {
    onlineDisplayIDs().filter { $0 != builtinID && CGDisplayIsBuiltin($0) == 0 }.count
}

// MARK: - Reconfiguration callback (must be a plain C function, not a closure)

private func reconfigurationCallback(
    display: CGDirectDisplayID,
    flags: CGDisplayChangeSummaryFlags,
    userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo else { return }
    let controller = Unmanaged<DisplayController>.fromOpaque(userInfo).takeUnretainedValue()
    // Ignore the "begin configuration" pre-notification; act only once macOS
    // has settled on the new arrangement.
    guard !flags.contains(.beginConfigurationFlag) else { return }
    DispatchQueue.main.async { controller.evaluate() }
}

// MARK: - Controller

final class DisplayController: ObservableObject {
    /// True only while *this app* is the reason the internal display is off,
    /// so we never fight the user if they turn it off some other way.
    @Published private(set) var isInternalDisabled = false
    @Published private(set) var externalCount = 0

    /// User-facing switch. When off, the app never acts automatically —
    /// but manual toggling and the safety net still work.
    @Published var autoModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoModeEnabled, forKey: "AutoModeEnabled")
            if autoModeEnabled {
                evaluate()
            } else if isInternalDisabled {
                enableInternal()
            }
        }
    }

    private var cachedInternalID: CGDirectDisplayID?
    private var pendingWorkItem: DispatchWorkItem?
    private var safetyTimer: DispatchSourceTimer?

    init() {
        self.autoModeEnabled = UserDefaults.standard.object(forKey: "AutoModeEnabled") as? Bool ?? true
    }

    func start() {
        cachedInternalID = internalDisplayID()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback(reconfigurationCallback, observer)
        startSafetyTimer()
        evaluate()
    }

    func stop() {
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRemoveReconfigurationCallback(reconfigurationCallback, observer)
        safetyTimer?.cancel()
        restoreIfNeeded(reason: "quit")
    }

    /// Re-checks the current display arrangement and, if auto mode is on,
    /// disables/enables the internal display accordingly. The safety
    /// restore (external gone -> bring internal back) always runs,
    /// regardless of the auto-mode switch. Safe to call as often as you like.
    func evaluate() {
        guard let internalID = internalDisplayID() ?? cachedInternalID else { return }
        cachedInternalID = internalID
        let externals = externalDisplayCount(excluding: internalID)
        externalCount = externals

        pendingWorkItem?.cancel()

        if externals == 0 && isInternalDisabled {
            enableInternal()
        } else if autoModeEnabled && externals > 0 && !isInternalDisabled {
            // Give macOS ~1.5s to finish settling the new monitor's mode
            // before we pull the internal display out from under it.
            let work = DispatchWorkItem { [weak self] in self?.disableInternal() }
            pendingWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        }
    }

    /// Manual "toggle now" button: works even when auto mode is off, but
    /// still refuses to disable the internal display with no external one.
    func manualToggle() {
        guard let id = internalDisplayID() ?? cachedInternalID else { return }
        cachedInternalID = id
        pendingWorkItem?.cancel()
        if isInternalDisabled {
            enableInternal()
        } else {
            guard externalDisplayCount(excluding: id) > 0 else { return }
            disableInternal()
        }
    }

    private func disableInternal() {
        guard let id = cachedInternalID else { return }
        // Re-check right before acting: the user may have unplugged again
        // during the settle delay.
        guard externalDisplayCount(excluding: id) > 0, !isInternalDisabled else { return }
        if setDisplay(id, enabled: false) {
            isInternalDisabled = true
            NSLog("AutoDisplayOff: internal display disabled")
        } else {
            NSLog("AutoDisplayOff: failed to disable internal display")
        }
    }

    private func enableInternal() {
        guard let id = cachedInternalID else { return }
        if setDisplay(id, enabled: true) {
            NSLog("AutoDisplayOff: internal display re-enabled")
        } else {
            NSLog("AutoDisplayOff: failed to re-enable internal display (will keep retrying)")
        }
        // Always clear the flag even on failure: we'd rather retry "enable"
        // again from a clean slate than get stuck believing it's off.
        isInternalDisabled = false
    }

    /// Safety net: called on quit and every 15s. If we believe the internal
    /// display is off but no external display is actually present, force it
    /// back on so the user is never left with a blank laptop screen.
    private func restoreIfNeeded(reason: String) {
        guard isInternalDisabled, let id = cachedInternalID else { return }
        if externalDisplayCount(excluding: id) == 0 {
            NSLog("AutoDisplayOff: safety restore (\(reason))")
            setDisplay(id, enabled: true)
            isInternalDisabled = false
        }
    }

    private func startSafetyTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in self?.restoreIfNeeded(reason: "periodic safety check") }
        timer.resume()
        safetyTimer = timer
    }
}

// MARK: - SwiftUI content

struct ContentView: View {
    @ObservedObject var controller: DisplayController
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AutoDisplayOff")
                .font(.headline)

            HStack(spacing: 6) {
                Circle()
                    .fill(controller.isInternalDisabled ? Color.red : Color.green)
                    .frame(width: 8, height: 8)
                Text(controller.isInternalDisabled ? "Встроенный экран выключен" : "Встроенный экран включён")
                    .font(.subheadline)
            }

            Text(controller.externalCount > 0
                 ? "Внешних мониторов подключено: \(controller.externalCount)"
                 : "Внешний монитор не подключён")
                .font(.caption)
                .foregroundColor(.secondary)

            Divider()

            Toggle(isOn: Binding(
                get: { controller.autoModeEnabled },
                set: { controller.autoModeEnabled = $0 }
            )) {
                Text("Автовыключение при подключении монитора")
                    .font(.system(size: 13))
            }
            .toggleStyle(.switch)

            Button(controller.isInternalDisabled ? "Включить сейчас" : "Выключить сейчас") {
                controller.manualToggle()
            }
            .disabled(!controller.isInternalDisabled && controller.externalCount == 0)
            .frame(maxWidth: .infinity)

            Divider()

            Button("Выйти", action: onQuit)
                .frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(width: 280)
    }
}

// MARK: - App delegate / menu bar UI

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let controller = DisplayController()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // no Dock icon, menu bar only

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateIcon()

        let hosting = NSHostingController(
            rootView: ContentView(controller: controller, onQuit: { NSApp.terminate(nil) })
        )
        hosting.sizingOptions = .preferredContentSize

        popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 280, height: 260)
        popover.contentViewController = hosting

        controller.$isInternalDisabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)

        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "display", accessibilityDescription: "AutoDisplayOff")
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = controller.isInternalDisabled ? .systemRed : nil
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            controller.evaluate() // refresh counts before showing
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
