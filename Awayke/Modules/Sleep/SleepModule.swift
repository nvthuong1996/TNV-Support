//
//  SleepModule.swift
//  TNV Support
//
//  Keep-awake module: prevents sleep with the lid closed by toggling
//  `pmset disablesleep`, with timed and until-lid-reopens sessions and
//  battery auto-off. Left-click its menu bar icon to toggle, right-click
//  for the menu.
//

import AppKit

final class SleepModule: NSObject, AppModule {
    private weak var context: ModuleContext?
    private var statusItem: NSStatusItem?
    private let powerManager = PowerManager()
    private let helper = HelperManager.shared
    private let displayKeeper = DisplayWakeKeeper()
    private let batteryMonitor = BatteryMonitor()
    private let autoOffTimer = AutoOffTimer()
    private let lidMonitor = LidMonitor()
    private let lidSession = LidSessionTracker()

    private let thresholdDefaultsKey = "autoOffThreshold"
    private let thresholdOptions = [0, 10, 20, 30]
    private let durationOptions = [15, 30, 60, 120]

    /// The user's intent: do they want keep-awake on?
    private var intent = false
    /// Battery auto-off is currently holding keep-awake off.
    private var suspendedForBattery = false
    /// The user turned keep-awake on while already below the floor. Auto-off
    /// stands down until the machine next reaches AC.
    private var overrideBattery = false
    /// Most recent battery reading, for re-evaluating on threshold change.
    private var lastSnapshot: BatterySnapshot?
    /// A pmset round-trip is outstanding. Guards against overlapping
    /// calls - on the osascript fallback path each one is a separate
    /// admin password prompt.
    private var powerChangeInFlight = false
    /// A session can end while a battery-driven pmset change is still in
    /// flight. Remember that event so it is not lost.
    private var pendingSessionEnd: SessionEndReason?
    /// Set once `stop` runs. Completions of pmset calls issued before that
    /// must not re-disable sleep or re-take the display assertion after
    /// cleanup restored the system.
    private var isStopped = false

    private enum SessionEndReason {
        case timer
        case lidReopened

        var notificationBody: String {
            switch self {
            case .timer: return "Timer finished."
            case .lidReopened: return "The lid was reopened."
            }
        }
    }

    /// Low-battery floor; 0 disables the feature. Persisted.
    private var threshold: Int {
        get { UserDefaults.standard.integer(forKey: thresholdDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: thresholdDefaultsKey) }
    }

    /// What is actually applied to the system.
    private var effectiveActive: Bool { intent && !suspendedForBattery }

    // MARK: - AppModule

    func start(context: ModuleContext) {
        self.context = context
        helper.register()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Tightens the horizontal slot around the icon.
        item.length = 14
        statusItem = item

        if let button = item.button {
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        refreshStatusItem()

        // Recovery from crash / force-kill: pmset disablesleep is a
        // persistent system setting, so a previous instance that died
        // without running its quit cleanup leaves SleepDisabled = 1.
        // Silently reset it via the helper. Skipped if the helper isn't
        // approved (no password prompt for cleanup the user didn't ask for).
        if helper.isUsable {
            powerManager.disableSleep(false) { _ in }
        }

        if threshold > 0 {
            context.notifier.requestAuthorization()
        }

        batteryMonitor.onChange = { [weak self] snapshot in
            self?.handleBattery(snapshot)
        }
        batteryMonitor.start()

        autoOffTimer.onExpire = { [weak self] in self?.handleTimerExpired() }
        // Keeps the tooltip's remaining-time readout live.
        autoOffTimer.onTick = { [weak self] in self?.refreshStatusItem() }

        lidMonitor.onChange = { [weak self] closed in
            guard let self else { return }
            if self.lidSession.handle(lidClosed: closed) {
                self.endSession(reason: .lidReopened)
            }
        }
        lidMonitor.start()
    }

    func stop(completion: @escaping () -> Void) {
        isStopped = true
        batteryMonitor.onChange = nil
        batteryMonitor.stop()
        lidMonitor.onChange = nil
        lidMonitor.stop()
        autoOffTimer.onExpire = nil
        autoOffTimer.onTick = nil
        autoOffTimer.cancel()
        lidSession.cancel()
        pendingSessionEnd = nil

        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil

        // Never leave the system with sleep disabled. Hold the caller
        // (module turn-off or app termination) until the helper or the
        // osascript fallback finishes flipping pmset back off. A change
        // still in flight may be about to disable sleep, so restore in
        // that case too.
        guard effectiveActive || powerChangeInFlight else {
            displayKeeper.allow()
            completion()
            return
        }

        powerManager.disableSleep(false) { _ in
            DispatchQueue.main.async {
                self.intent = false
                self.displayKeeper.allow()
                completion()
            }
        }
    }

    /// Removes the privileged helper from System Settings. Safe to call
    /// while the module is turned off.
    static func uninstall() {
        HelperManager.shared.unregister()
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            setIntent(!effectiveActive)
        }
    }

    // MARK: - State application

    /// Manual on/off. Always clears any battery suspension - the user
    /// overrides the auto-off machine.
    ///
    /// - Parameters:
    ///   - timerMinutes: Arms the auto-off countdown for this many minutes.
    ///   - untilLidReopens: Ends after a lid close/open cycle.
    ///
    /// With neither session option, turning on is indefinite.
    private func setIntent(_ on: Bool,
                           timerMinutes: Int? = nil,
                           untilLidReopens: Bool = false) {
        guard !isStopped, !powerChangeInFlight else { return }
        powerChangeInFlight = true

        powerManager.disableSleep(on) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !self.isStopped else { return }
                self.powerChangeInFlight = false
                switch result {
                case .success:
                    self.intent = on
                    self.suspendedForBattery = false
                    // Only an "on" issued while already below the floor
                    // counts as an override. Turning on at a healthy
                    // charge leaves auto-off armed for the discharge.
                    self.overrideBattery = on && self.isBelowFloor
                    if on, untilLidReopens {
                        self.autoOffTimer.cancel()
                        self.lidSession.start(lidClosed: self.lidMonitor.isClosed)
                    } else if on, let minutes = timerMinutes {
                        self.lidSession.cancel()
                        self.autoOffTimer.start(minutes: minutes)
                    } else {
                        self.autoOffTimer.cancel()
                        self.lidSession.cancel()
                    }
                    self.syncDisplayKeeper()
                    self.refreshStatusItem()
                case .failure(let error):
                    self.presentError(error)
                }
                self.processPendingSessionEnd()
            }
        }
    }

    /// Latest reading is on battery and under the configured floor.
    private var isBelowFloor: Bool {
        guard threshold > 0, let snapshot = lastSnapshot else { return false }
        return !snapshot.onAC && snapshot.percent < threshold
    }

    /// The countdown ran out. Same end state as a manual "Turn Off".
    private func handleTimerExpired() {
        endSession(reason: .timer)
    }

    /// Ends either kind of bounded session. This is intentionally shared by
    /// timer and lid sessions so both interact identically with battery
    /// suspension and in-flight helper calls.
    private func endSession(reason: SessionEndReason) {
        guard !isStopped else { return }
        autoOffTimer.cancel()
        lidSession.cancel()
        guard intent else { return }

        // Battery auto-off already re-enabled sleep, so there is nothing
        // to undo at the system level - just clear the state. Avoids a
        // redundant pmset round-trip (and an admin prompt on the
        // osascript fallback path).
        guard !suspendedForBattery else {
            intent = false
            suspendedForBattery = false
            overrideBattery = false
            syncDisplayKeeper()
            refreshStatusItem()
            notify(title: "Keep Awake turned off", body: reason.notificationBody)
            return
        }

        guard !powerChangeInFlight else {
            pendingSessionEnd = reason
            return
        }
        powerChangeInFlight = true

        powerManager.disableSleep(false) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !self.isStopped else { return }
                self.powerChangeInFlight = false
                switch result {
                case .success:
                    self.intent = false
                    self.overrideBattery = false
                    self.syncDisplayKeeper()
                    self.refreshStatusItem()
                    self.notify(title: "Keep Awake turned off", body: reason.notificationBody)
                case .failure(let error):
                    // Do not claim the session ended if pmset could not be
                    // restored. The icon remains active and the error makes
                    // the failed safety action visible to the user.
                    //
                    // LidSessionTracker.handle already cleared itself when it
                    // reported the reopen, so without this the session is gone
                    // and nothing can ever end it. Re-arm so the next
                    // close/open cycle retries. A timer deadline has genuinely
                    // passed and has no duration to restore, so it does not
                    // re-arm.
                    if case .lidReopened = reason {
                        self.lidSession.start(lidClosed: self.lidMonitor.isClosed)
                    }
                    self.refreshStatusItem()
                    self.presentError(error)
                }
            }
        }
    }

    private func processPendingSessionEnd() {
        guard !powerChangeInFlight, let reason = pendingSessionEnd else { return }
        pendingSessionEnd = nil
        endSession(reason: reason)
    }

    private func syncDisplayKeeper() {
        guard !isStopped else { return }
        if effectiveActive { displayKeeper.prevent() } else { displayKeeper.allow() }
    }

    private func handleBattery(_ snapshot: BatterySnapshot) {
        guard !isStopped else { return }
        lastSnapshot = snapshot
        overrideBattery = AutoOffPolicy.shouldKeepOverride(overrideBattery, onAC: snapshot.onAC)

        let action = AutoOffPolicy.decide(
            intent: intent,
            suspended: suspendedForBattery,
            overridden: overrideBattery,
            percent: snapshot.percent,
            onAC: snapshot.onAC,
            threshold: threshold
        )
        guard action != .none else { return }

        // Power notifications arrive faster than a pmset round-trip
        // completes. Drop this one - the in-flight completion
        // re-evaluates against the newest reading.
        guard !powerChangeInFlight else { return }
        powerChangeInFlight = true

        let suspending = (action == .suspend)
        powerManager.disableSleep(!suspending) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !self.isStopped else { return }
                self.powerChangeInFlight = false
                guard case .success = result else {
                    self.processPendingSessionEnd()
                    return
                }

                self.suspendedForBattery = suspending
                self.syncDisplayKeeper()
                self.refreshStatusItem()
                if suspending {
                    self.notify(title: "Keep Awake turned off",
                                body: "Battery dropped below \(self.threshold)%.")
                } else {
                    self.notify(title: "Keep Awake back on",
                                body: "Charging - sleep prevention resumed.")
                }

                self.processPendingSessionEnd()

                // State moved on; re-check against anything that arrived
                // while we were waiting. Terminates because each pass
                // flips `suspendedForBattery`.
                if let latest = self.lastSnapshot {
                    self.handleBattery(latest)
                }
            }
        }
    }

    // MARK: - Menu

    private func showMenu() {
        let menu = NSMenu()

        let stateTitle: String
        if suspendedForBattery {
            stateTitle = "Paused (low battery)"
        } else if effectiveActive, lidSession.isActive {
            stateTitle = lidSession.isWaitingForClose
                ? "Active - waiting for lid to close"
                : "Active - until lid reopens"
        } else if effectiveActive, let remaining = autoOffTimer.remaining {
            stateTitle = "Active - \(formatRemaining(remaining)) left"
        } else {
            stateTitle = effectiveActive ? "Active" : "Inactive"
        }
        let stateItem = NSMenuItem(title: stateTitle, action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)

        menu.addItem(.separator())

        menu.addItem(keepAwakeSubmenuItem())
        menu.addItem(autoOffSubmenuItem())

        if let helperRow = helperStatusMenuItem() {
            menu.addItem(.separator())
            menu.addItem(helperRow)
        }

        for item in menu.items where item.action != nil {
            item.target = self
        }

        // Shared app items (module list, Uninstall, Quit) carry their own target.
        for item in context?.appMenuItems() ?? [] {
            menu.addItem(item)
        }

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    private func keepAwakeSubmenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Keep awake for", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let lidSessionItem = NSMenuItem(
            title: "Until lid is reopened",
            action: #selector(menuKeepAwakeUntilLidReopens),
            keyEquivalent: ""
        )
        lidSessionItem.target = self
        lidSessionItem.state = (effectiveActive && lidSession.isActive) ? .on : .off
        submenu.addItem(lidSessionItem)

        submenu.addItem(.separator())

        for value in durationOptions {
            let item = NSMenuItem(title: durationLabel(value),
                                  action: #selector(menuKeepAwakeFor(_:)), keyEquivalent: "")
            item.target = self
            item.tag = value
            submenu.addItem(item)
        }

        submenu.addItem(.separator())

        // Tag 0 means "no countdown" - on until turned off.
        let indefinite = NSMenuItem(title: "Indefinitely",
                                    action: #selector(menuKeepAwakeFor(_:)), keyEquivalent: "")
        indefinite.target = self
        indefinite.tag = 0
        indefinite.state = (effectiveActive && !autoOffTimer.isRunning && !lidSession.isActive) ? .on : .off
        submenu.addItem(indefinite)

        parent.submenu = submenu
        return parent
    }

    private func durationLabel(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) minutes" }
        let hours = minutes / 60
        let rest = minutes % 60
        let hourPart = hours == 1 ? "1 hour" : "\(hours) hours"
        return rest == 0 ? hourPart : "\(hourPart) \(rest) min"
    }

    /// Rounded up to the next whole minute, so a live countdown never
    /// reads "0m" while keep-awake is still on.
    private func formatRemaining(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    private func autoOffSubmenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Auto-off on low battery", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let current = threshold
        for value in thresholdOptions {
            let label = value == 0 ? "Off" : "At \(value)%"
            let item = NSMenuItem(title: label, action: #selector(menuSetThreshold(_:)), keyEquivalent: "")
            item.target = self
            item.tag = value
            item.state = (value == current) ? .on : .off
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    private func helperStatusMenuItem() -> NSMenuItem? {
        switch helper.state {
        case .enabled:
            return nil
        case .awaitingApproval:
            return NSMenuItem(title: "Approve helper in System Settings…", action: #selector(menuApproveHelper), keyEquivalent: "")
        case .notRegistered:
            let item = NSMenuItem(title: "Installing helper…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        case .notFound:
            let item = NSMenuItem(title: "Helper not found (using fallback)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        }
    }

    @objc private func menuKeepAwakeFor(_ sender: NSMenuItem) {
        let minutes = sender.tag
        if minutes > 0 {
            context?.notifier.requestAuthorization()
        }

        // Already on: just (re)arm the countdown. Skipping the pmset
        // round-trip keeps the osascript fallback from asking for an
        // admin password to set a state the system is already in.
        guard effectiveActive else {
            setIntent(true, timerMinutes: minutes > 0 ? minutes : nil)
            return
        }

        if minutes > 0 {
            lidSession.cancel()
            autoOffTimer.start(minutes: minutes)
        } else {
            autoOffTimer.cancel()
            lidSession.cancel()
        }
        refreshStatusItem()
    }

    @objc private func menuKeepAwakeUntilLidReopens() {
        context?.notifier.requestAuthorization()

        guard effectiveActive else {
            setIntent(true, untilLidReopens: true)
            return
        }

        autoOffTimer.cancel()
        lidSession.start(lidClosed: lidMonitor.isClosed)
        refreshStatusItem()
    }

    @objc private func menuSetThreshold(_ sender: NSMenuItem) {
        threshold = sender.tag
        if threshold > 0 {
            context?.notifier.requestAuthorization()
        }
        // Re-evaluate against the latest reading so a newly-set threshold
        // that is already breached suspends immediately.
        if let snapshot = lastSnapshot {
            handleBattery(snapshot)
        }
    }

    @objc private func menuApproveHelper() { helper.revealInSystemSettings() }

    private func notify(title: String, body: String) {
        context?.notifier.post(title: title, body: body)
    }

    // MARK: - Status item rendering

    private func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        guard let base = NSImage(named: "StatusIcon") else { return }
        base.size = NSSize(width: 16, height: 14)

        if effectiveActive {
            button.image = orangeTinted(base)
        } else {
            base.isTemplate = true
            button.image = base
        }
        button.contentTintColor = nil
        button.title = ""
        if suspendedForBattery {
            button.toolTip = "Keep Awake paused - battery below \(threshold)%. Plug in to resume."
        } else if effectiveActive, lidSession.isActive {
            button.toolTip = lidSession.isWaitingForClose
                ? "Keep Awake is on - it will turn off after the lid is closed and reopened."
                : "Keep Awake is on - it will turn off when the lid is reopened."
        } else if effectiveActive, let remaining = autoOffTimer.remaining {
            button.toolTip = "Keep Awake is on - turning off in \(formatRemaining(remaining))."
        } else {
            button.toolTip = effectiveActive ? "Keep Awake is on!" : "Keep Awake is off. Click to turn it on."
        }
    }

    private func orangeTinted(_ source: NSImage) -> NSImage {
        let image = source.copy() as! NSImage
        image.isTemplate = false
        image.lockFocus()
        NSColor(red: 1, green: 0.6, blue: 0.1, alpha: 1).set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        image.unlockFocus()
        return image
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "TNV Support couldn't toggle sleep."
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
