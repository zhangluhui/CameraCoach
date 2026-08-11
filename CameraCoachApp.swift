//
//  CameraCoachApp.swift
//  CameraCoach
//

import SwiftUI

@main
struct CameraCoachApp: App {

    struct Selection {
        let backend: CoachingBackend
        let config: PersonalModelConfig
    }

    @State private var selection: Selection?

    var body: some Scene {
        WindowGroup {
            if let selection {
                ContentView(backend: selection.backend, personalConfig: selection.config)
            } else {
                BackendPickerView { backend, config in
                    selection = Selection(backend: backend, config: config)
                }
            }
        }
    }
}
