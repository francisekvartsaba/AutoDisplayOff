//
// AutoDisplayOff
//
// Menu-bar utility for macOS that lets you choose which display is ON when an
// external monitor is connected to a MacBook:
//
//   * "Ноутбук / Laptop"  – only the built-in display is on (external ones off)
//   * "Монитор / Monitor" – only the external display(s) are on (built-in off)
//   * "Оба / Both"        – everything is on
//
// "Off" means really disabled at the WindowServer level (like clamshell mode),
// not just black or dimmed. The lid can stay open and the keyboard and
// trackpad keep working.
//
// In automatic mode the app switches to "Monitor" whenever a new external
// display is connected. Click the menu-bar icon to open the window with the
// screen selector and the automatic-mode switch.
//
// HOW IT WORKS
// ------------
// macOS has no public API for "disable this one display". The mechanism used
// here — SLSConfigureDisplayEnabled / CGSConfigureDisplayEnabled — is a
// *private*, undocumented API from SkyLight.framework. Being private:
//   * it needs no special entitlement or code signature to call,
//   * but Apple can change or remove it in any macOS release,
//   * and it is not eligible for Mac App Store distribution.
//
// SAFETY
// ------
// The app must never leave the user without a working display. To guard
// against that:
//   1. Every switch first turns the needed displays ON and only then turns
//      the others OFF, and it never turns off the last display that is on.
//   2. If the built-in display is off and no external display is left (the
//      monitor was unplugged), everything is switched back on (after ~1.5 s).
//   3. On quit (Quit button, SIGTERM from `pkill`, logout) everything is
//      switched back on.
//   4. The list of displays switched off by the app is saved to
//      ~/Library/Application Support/AutoDisplayOff/state.json and restored on
//      the next launch, so even after a crash or `kill -9` simply starting
//      the app again brings the displays back.
//   5. A background check every 15 s re-evaluates the situation.
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

private func onlineDisplayIDs() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    guard count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    return ids
}

// MARK: - Persisted state (crash recovery)

private struct SavedState: Codable {
    var internalID: UInt32?
    var offByUs: [UInt32]
}

private enum StateStore {
    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("AutoDisplayOff", isDirectory: true)
            .appendingPathComponent("state.json")
    }

    static func load() -> SavedState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SavedState.self, from: data)
    }

    static func save(_ state: SavedState) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: url, options: .atomic)
        }
    }
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

// MARK: - Screen mode

enum ScreenMode: String, CaseIterable, Identifiable {
    case laptopOnly
    case externalOnly
    case both

    var id: String { rawValue }

    var title: String {
        switch self {
        case .laptopOnly: return "Ноутбук"
        case .externalOnly: return "Монитор"
        case .both: return "Оба"
        }
    }
}

// MARK: - Controller

final class DisplayController: ObservableObject {
    /// The mode the user (or the automatic mode) asked for.
    @Published private(set) var mode: ScreenMode = .both
    /// Number of external displays that are connected (including ones this app switched off).
    @Published private(set) var externalCount = 0
    /// True when the built-in display is currently not showing anything.
    @Published private(set) var internalIsOff = false
    @Published private(set) var lastError: String? = nil

    /// When on, a newly connected external display automatically becomes the
    /// only active screen.
    @Published var autoModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoModeEnabled, forKey: "AutoModeEnabled")
            if autoModeEnabled && externalCount > 0 && mode == .both {
                select(.externalOnly)
            }
        }
    }

    private struct Snapshot {
        var internalOn: Bool
        var externalsOn: [CGDirectDisplayID]
        var externalsOff: [CGDirectDisplayID]

        /// The mode that matches what the displays are doing right now.
        var derivedMode: ScreenMode {
            if !internalOn && !externalsOn.isEmpty { return .externalOnly }
            if internalOn && externalsOn.isEmpty && !externalsOff.isEmpty { return .laptopOnly }
            return .both
        }
    }

    private var internalID: CGDirectDisplayID?
    /// Displays this app has switched off (persisted for crash recovery).
    private var offByUs = Set<CGDirectDisplayID>()
    /// External displays seen at the last check, to detect newly connected ones.
    private var knownExternals = Set<CGDirectDisplayID>()
    private var lastApply = Date.distantPast
    private var pendingWork: DispatchWorkItem?
    private var safetyTimer: DispatchSourceTimer?
    private var isSleeping = false
    private var observers: [NSObjectProtocol] = []

    init() {
        self.autoModeEnabled = UserDefaults.standard.object(forKey: "AutoModeEnabled") as? Bool ?? true
    }

    // MARK: Lifecycle

    func start() {
        recoverFromPreviousSession()

        let observer = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback(reconfigurationCallback, observer)

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isSleeping = true
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isSleeping = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.evaluate() }
        })

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in self?.evaluate() }
        timer.resume()
        safetyTimer = timer

        evaluate()
    }

    func stop() {
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRemoveReconfigurationCallback(reconfigurationCallback, observer)
        for token in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        observers.removeAll()
        safetyTimer?.cancel()
        pendingWork?.cancel()
        restoreAll()
    }

    /// If a previous run was killed while some display was switched off,
    /// switch it back on before doing anything else.
    private func recoverFromPreviousSession() {
        guard let saved = StateStore.load() else { return }
        internalID = saved.internalID
        for id in saved.offByUs {
            setDisplay(id, enabled: true)
        }
        StateStore.save(SavedState(internalID: internalID, offByUs: []))
    }

    private func persist() {
        StateStore.save(SavedState(internalID: internalID, offByUs: Array(offByUs)))
    }

    // MARK: Public actions

    /// Called by the UI: apply the chosen mode right away.
    func select(_ newMode: ScreenMode) {
        pendingWork?.cancel()
        pendingWork = nil
        let s = snapshot()
        knownExternals = Set(s.externalsOn + s.externalsOff)
        mode = newMode
        lastError = nil
        act()
    }

    /// Called on every display change and every 15 s. Debounced: the real work
    /// happens ~1.5 s after the last event, once macOS has settled.
    func evaluate() {
        refreshStatus()
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.act() }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    // MARK: Core logic

    private func act() {
        pendingWork = nil
        guard !isSleeping else { return }
        let s = snapshot()

        // 1. Safety net: built-in is off but no external display is left.
        if let id = internalID, offByUs.contains(id), s.externalsOn.isEmpty {
            NSLog("AutoDisplayOff: no external display left, restoring all displays")
            restoreAll()
            mode = .both
            lastError = nil
            knownExternals = []
            refreshStatus()
            return
        }

        // 2. A new external display appeared.
        let newOnes = Set(s.externalsOn).subtracting(knownExternals)
        knownExternals = Set(s.externalsOn + s.externalsOff)
        if !newOnes.isEmpty {
            mode = autoModeEnabled ? .externalOnly : .both
        }

        // 3. Make the displays match the wanted mode.
        if mode != s.derivedMode {
            apply(mode, from: s)
        }
        refreshStatus()
    }

    /// Switches displays so that they match `target`. Always turns displays ON
    /// first and OFF afterwards, and never turns off the last working display.
    private func apply(_ target: ScreenMode, from s: Snapshot) {
        guard let internalID = internalID else {
            lastError = "Встроенный экран не найден"
            mode = s.derivedMode
            return
        }
        var failed = false
        var touched = false
        var enabledNow = Set<CGDirectDisplayID>()

        // Step 1: turn ON what must be on.
        let candidates: [CGDirectDisplayID]
        switch target {
        case .both: candidates = Array(offByUs)
        case .laptopOnly: candidates = [internalID]
        case .externalOnly: candidates = Array(offByUs.filter { $0 != internalID })
        }
        let toEnable = candidates
            .filter { id in
                guard offByUs.contains(id) else { return false }
                return id == internalID ? !s.internalOn : !s.externalsOn.contains(id)
            }
            .sorted { a, b in a == internalID && b != internalID }

        for id in toEnable {
            touched = true
            if setDisplay(id, enabled: true) {
                offByUs.remove(id)
                enabledNow.insert(id)
            } else if id == internalID {
                failed = true
            } else {
                // Probably the monitor was unplugged while it was switched off.
                offByUs.remove(id)
            }
        }

        // Step 2: turn OFF what must be off — only if something else stays on.
        let internalOnNow = s.internalOn || enabledNow.contains(internalID)
        let externalsOnNow = Set(s.externalsOn).union(enabledNow.filter { $0 != internalID })

        switch target {
        case .both:
            break
        case .laptopOnly:
            if internalOnNow {
                for id in s.externalsOn {
                    touched = true
                    if setDisplay(id, enabled: false) {
                        offByUs.insert(id)
                    } else {
                        failed = true
                    }
                }
            } else {
                failed = true
            }
        case .externalOnly:
            if externalsOnNow.isEmpty {
                lastError = "Внешний монитор не найден"
                failed = true
            } else if internalOnNow {
                touched = true
                if setDisplay(internalID, enabled: false) {
                    offByUs.insert(internalID)
                } else {
                    failed = true
                }
            }
        }

        if touched { lastApply = Date() }
        if target == .both && !failed { offByUs.removeAll() }
        persist()

        if failed {
            mode = s.derivedMode
            if lastError == nil { lastError = "Не удалось переключить экран" }
        } else {
            lastError = nil
        }
    }

    /// Switches every display this app has turned off back on.
    private func restoreAll() {
        let ids = offByUs.sorted { a, b in a == internalID && b != internalID }
        for id in ids {
            setDisplay(id, enabled: true)
        }
        offByUs.removeAll()
        lastApply = Date()
        persist()
    }

    // MARK: Snapshot / status

    private func isOn(_ id: CGDirectDisplayID, online: [CGDirectDisplayID]) -> Bool {
        guard online.contains(id) else { return false }
        guard offByUs.contains(id) else { return true }
        // Switched off by us: only believe "active" once things have settled
        // (macOS itself turns displays back on, e.g. after wake).
        return CGDisplayIsActive(id) != 0 && Date().timeIntervalSince(lastApply) > 3
    }

    private func snapshot() -> Snapshot {
        let online = onlineDisplayIDs()
        if let builtin = online.first(where: { CGDisplayIsBuiltin($0) != 0 }), builtin != internalID {
            internalID = builtin
            persist()
        }
        let internalOn = internalID.map { isOn($0, online: online) } ?? false
        let externalsOn = online.filter { CGDisplayIsBuiltin($0) == 0 && isOn($0, online: online) }
        let externalsOff = Array(offByUs.filter { $0 != internalID && !isOn($0, online: online) })
        return Snapshot(internalOn: internalOn, externalsOn: externalsOn, externalsOff: externalsOff)
    }

    private func refreshStatus() {
        let s = snapshot()
        externalCount = s.externalsOn.count + s.externalsOff.count
        internalIsOff = !s.internalOn
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
                    .fill(controller.internalIsOff ? Color.red : Color.green)
                    .frame(width: 8, height: 8)
                Text(controller.internalIsOff ? "Экран ноутбука выключен" : "Экран ноутбука включён")
                    .font(.subheadline)
            }

            Text(controller.externalCount > 0
                 ? "Внешних мониторов подключено: \(controller.externalCount)"
                 : "Внешний монитор не подключён")
                .font(.caption)
                .foregroundColor(.secondary)

            Divider()

            Text("Какой экран использовать")
                .font(.subheadline)

            Picker("", selection: Binding(
                get: { controller.mode },
                set: { controller.select($0) }
            )) {
                ForEach(ScreenMode.allCases) { screenMode in
                    Text(screenMode.title).tag(screenMode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(controller.externalCount == 0)

            if controller.externalCount == 0 {
                Text("Подключите внешний монитор, чтобы выбрать экран.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = controller.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle(isOn: Binding(
                get: { controller.autoModeEnabled },
                set: { controller.autoModeEnabled = $0 }
            )) {
                Text("При подключении монитора переключаться на него")
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.switch)

            Divider()

            Button("Выйти", action: onQuit)
                .frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(width: 300)
    }
}

// MARK: - App delegate / menu bar UI

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let controller = DisplayController()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var cancellables = Set<AnyCancellable>()
    private var signalSources: [DispatchSourceSignal] = []

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
        popover.contentSize = NSSize(width: 300, height: 300)
        popover.contentViewController = hosting

        controller.$mode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
        controller.$internalIsOff
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)

        installSignalHandlers()
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }

    /// `pkill`, logout and launchd send SIGTERM: quit properly so that
    /// every display is switched back on.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            _ = signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "display", accessibilityDescription: "AutoDisplayOff")
        image?.isTemplate = true
        button.image = image
        switch controller.mode {
        case .externalOnly: button.contentTintColor = .systemRed
        case .laptopOnly: button.contentTintColor = .systemOrange
        case .both: button.contentTintColor = nil
        }
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
