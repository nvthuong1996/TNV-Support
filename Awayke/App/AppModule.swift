//
//  AppModule.swift
//  TNV Support
//
//  A module is one self-contained feature of the app (keep awake, sensor
//  readouts, ...). Each module owns its own menu bar item and system
//  resources; the host only starts and stops it and supplies the shared
//  services in `ModuleContext`.
//

import AppKit

/// Services the host app offers every running module.
protocol ModuleContext: AnyObject {
    /// Items every module appends to the bottom of its menu: the module
    /// list, Uninstall and Quit. Build a fresh set for each menu.
    func appMenuItems() -> [NSMenuItem]

    var notifier: Notifier { get }
}

protocol AppModule: AnyObject {
    /// Called once, on the main thread. Create the menu bar item and start
    /// observing here.
    func start(context: ModuleContext)

    /// Undo every system-level change the module made and remove its menu
    /// bar item. Call `completion` on the main thread once it is safe for
    /// the module to be released or the app to quit. Called once.
    func stop(completion: @escaping () -> Void)
}

struct ModuleDescriptor {
    /// Stable identifier, used as the persistence key.
    let id: String
    /// Name shown in the Modules menu.
    let title: String
    /// Builds a fresh instance each time the module is turned on.
    let make: () -> AppModule
    /// Removes anything the module installed outside the app bundle, even
    /// when the module is currently turned off.
    var uninstall: () -> Void = {}
}
