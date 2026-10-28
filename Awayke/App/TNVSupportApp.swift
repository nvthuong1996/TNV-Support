//
//  TNVSupportApp.swift
//  TNV Support
//

import SwiftUI

@main
struct TNVSupportApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
