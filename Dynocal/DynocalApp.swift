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
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: CompletedTaskRecord.self)
    }
}
