//
//  DynocalApp.swift
//  Dynocal
//
//  Created by Maddie Smith on 5/22/26.
//

import SwiftUI
import SwiftData

@main
struct DynocalApp: App {
    @StateObject private var preferences = PreferencesStore.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(preferences)
        }
        .modelContainer(for: CompletedTaskRecord.self)
    }
}
