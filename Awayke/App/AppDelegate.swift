//
//  AppDelegate.swift
//  TNV Support
//
//  Module host. Starts the enabled modules, lets the user turn modules on
//  and off from any module's menu, and gives every module a chance to
//  clean up before the app quits.
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, ModuleContext {

    let notifier = Notifier()

    /// Every module the app ships, in menu order. Add new modules here.
    private let descriptors: [ModuleDescriptor] = [
        ModuleDescriptor(id: "sleep", title: "Keep Awake",
                         make: { SleepModule() },
                         uninstall: { SleepModule.uninstall() }),
        ModuleDescriptor(id: "sensors", title: "Temperature & Fans",
                         make: { SensorsModule() }),
    ]

    private var running: [String: AppModule] = [:]
    /// Modules turned off whose cleanup has not finished yet. Holds them
    /// alive until it does.
    private var stopping: [String: AppModule] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        for descriptor in descriptors where isEnabled(descriptor) {
            startModule(descriptor)
        }
        // With every module off there would be no menu bar item left to
        // turn one back on or quit from.
        if running.isEmpty, let first = descriptors.first {
            setEnabled(true, for: first)
            startModule(first)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !running.isEmpty else { return .terminateNow }

        // Defer termination until every module has restored the system
        // (for example re-enabling sleep), so the main run loop stays alive
        // for any auth UI that cleanup may need to show.
        let group = DispatchGroup()
        for module in running.values {
            group.enter()
            module.stop { group.leave() }
        }
        running.removeAll()
        group.notify(queue: .main) {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - Module lifecycle

    private func enabledDefaultsKey(_ descriptor: ModuleDescriptor) -> String {
        "module.\(descriptor.id).enabled"
    }

    /// Modules default to on.
    private func isEnabled(_ descriptor: ModuleDescriptor) -> Bool {
        UserDefaults.standard.object(forKey: enabledDefaultsKey(descriptor)) as? Bool ?? true
    }

    private func setEnabled(_ enabled: Bool, for descriptor: ModuleDescriptor) {
        UserDefaults.standard.set(enabled, forKey: enabledDefaultsKey(descriptor))
    }

    private func startModule(_ descriptor: ModuleDescriptor) {
        guard running[descriptor.id] == nil, stopping[descriptor.id] == nil else { return }
        let module = descriptor.make()
        running[descriptor.id] = module
        module.start(context: self)
    }

    private func stopModule(_ descriptor: ModuleDescriptor) {
        guard let module = running.removeValue(forKey: descriptor.id) else { return }
        stopping[descriptor.id] = module
        module.stop { [weak self] in
            self?.stopping[descriptor.id] = nil
        }
    }

    // MARK: - Shared menu items

    func appMenuItems() -> [NSMenuItem] {
        let modulesItem = NSMenuItem(title: "Modules", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for descriptor in descriptors {
            let isRunning = running[descriptor.id] != nil
            let item = NSMenuItem(title: descriptor.title,
                                  action: #selector(menuToggleModule(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = descriptor.id
            item.state = isRunning ? .on : .off
            // Keep at least one module running so the app stays reachable.
            // A module still cleaning up can't be turned back on yet.
            if (isRunning && running.count == 1) || stopping[descriptor.id] != nil {
                item.action = nil
            }
            submenu.addItem(item)
        }
        modulesItem.submenu = submenu

        let uninstall = NSMenuItem(title: "Uninstall TNV Support…", action: #selector(menuUninstall), keyEquivalent: "")
        uninstall.target = self
        let quit = NSMenuItem(title: "Quit TNV Support", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self

        return [.separator(), modulesItem, uninstall, .separator(), quit]
    }

    @objc private func menuToggleModule(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let descriptor = descriptors.first(where: { $0.id == id }) else { return }

        if running[id] != nil {
            guard running.count > 1 else { return }
            setEnabled(false, for: descriptor)
            stopModule(descriptor)
        } else {
            setEnabled(true, for: descriptor)
            startModule(descriptor)
        }
    }

    @objc private func menuQuit() { NSApp.terminate(nil) }

    @objc private func menuUninstall() {
        let alert = NSAlert()
        alert.messageText = "Uninstall TNV Support?"
        alert.informativeText = "This will remove TNV Support's background helper from System Settings and quit the app. You can then move TNV Support.app to the Trash."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        for descriptor in descriptors {
            descriptor.uninstall()
        }
        NSApp.terminate(nil)
    }
}
