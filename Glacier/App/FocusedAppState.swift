// FocusedAppState.swift
// Exposes the focused window's AppState to menu commands via FocusedValue.

import SwiftUI
import Foundation

struct FocusedAppStateKey: FocusedValueKey {
    typealias Value = AppState
}

extension FocusedValues {
    var appState: AppState? {
        get { self[FocusedAppStateKey.self] }
        set { self[FocusedAppStateKey.self] = newValue }
    }
}

@MainActor
final class AppStateRegistry {
    static let shared = AppStateRegistry()

    private let appStates = NSHashTable<AppState>.weakObjects()

    private init() {}

    func register(_ appState: AppState) {
        guard !appStates.allObjects.contains(where: { $0 === appState }) else { return }
        appStates.add(appState)
    }

    var allAppStates: [AppState] {
        appStates.allObjects
    }
}

@MainActor
final class ActiveAppStateStore {
    static let shared = ActiveAppStateStore()

    weak var appState: AppState?

    private init() {}

    func activate(_ appState: AppState) {
        self.appState = appState
    }

    func deactivate(_ appState: AppState) {
        guard self.appState === appState else { return }
        self.appState = nil
    }
}
