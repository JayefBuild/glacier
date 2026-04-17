// BonsplitBridge.swift
// Adapts Glacier's AppState (tab content/identity) to Bonsplit (pane layout/drag).
//
// Ownership split:
//   - AppState owns Glacier Tab objects (file/terminal/gitGraph, Tab.id UUID)
//   - Bonsplit owns the pane tree, per-pane tab ordering, focus, split/drag gestures
//   - This bridge maps Glacier Tab.id (UUID) <-> Bonsplit TabID and forwards
//     lifecycle events.

import SwiftUI
@preconcurrency import Bonsplit

@MainActor
final class BonsplitBridge: NSObject, @preconcurrency BonsplitDelegate {

    // MARK: - Bonsplit state

    let controller: BonsplitController

    // MARK: - ID mapping (Glacier UUID <-> Bonsplit TabID)

    private var glacierToBonsplit: [UUID: TabID] = [:]
    private var bonsplitToGlacier: [TabID: UUID] = [:]

    // MARK: - Preview items (per Bonsplit pane)

    private(set) var previewItems: [PaneID: FileItem] = [:]

    // MARK: - AppState backref (set after construction to break init cycle)

    weak var appState: AppState?

    // MARK: - Init

    init(appState: AppState? = nil) {
        let config = BonsplitConfiguration(
            allowSplits: true,
            allowCloseTabs: true,
            allowCloseLastPane: true, // we manage the empty state ourselves
            allowTabReordering: true,
            allowCrossPaneTabMove: true,
            autoCloseEmptyPanes: true,
            contentViewLifecycle: .keepAllAlive, // preserves editor scroll/state
            newTabPosition: .current
        )
        self.controller = BonsplitController(configuration: config)
        self.appState = appState
        super.init()
        self.controller.delegate = self
        // Bonsplit seeds an internal "Welcome" tab on init. We own empty-state
        // rendering (Glacier's WelcomeView appears when tabs.isEmpty), so strip
        // any bonsplit-created tabs we don't know about.
        for tabID in controller.allTabIds {
            if bonsplitToGlacier[tabID] == nil {
                controller.closeTab(tabID)
            }
        }
    }

    // MARK: - Public API used by AppState

    /// Add a Glacier tab to the focused Bonsplit pane (or a specified pane).
    /// Returns the resulting Bonsplit TabID for internal reference.
    @discardableResult
    func addTab(_ tab: Tab, inPane pane: PaneID? = nil) -> TabID? {
        if let existingBonsplitID = glacierToBonsplit[tab.id] {
            controller.selectTab(existingBonsplitID)
            return existingBonsplitID
        }

        guard let bonsplitID = controller.createTab(
            title: tab.title,
            icon: tab.icon,
            isDirty: tab.isModified,
            inPane: pane
        ) else {
            return nil
        }

        glacierToBonsplit[tab.id] = bonsplitID
        bonsplitToGlacier[bonsplitID] = tab.id
        return bonsplitID
    }

    func removeTab(glacierID: UUID) {
        guard let bonsplitID = glacierToBonsplit[glacierID] else { return }
        controller.closeTab(bonsplitID)
    }

    func selectTab(glacierID: UUID) {
        guard let bonsplitID = glacierToBonsplit[glacierID] else { return }
        controller.selectTab(bonsplitID)
    }

    func glacierTabID(for bonsplitID: TabID) -> UUID? {
        bonsplitToGlacier[bonsplitID]
    }

    func bonsplitTabID(for glacierID: UUID) -> TabID? {
        glacierToBonsplit[glacierID]
    }

    /// Glacier Tab.id for the focused pane's selected tab, if any.
    var focusedGlacierTabID: UUID? {
        guard let paneID = controller.focusedPaneId,
              let selected = controller.selectedTab(inPane: paneID) else {
            return nil
        }
        return bonsplitToGlacier[selected.id]
    }

    /// Glacier Tab for the focused pane's selected tab, looked up in AppState.
    var focusedGlacierTab: Tab? {
        guard let id = focusedGlacierTabID else { return nil }
        return appState?.tab(with: id)
    }

    /// Which Bonsplit pane, if any, currently displays the given Glacier tab.
    func pane(for glacierID: UUID) -> PaneID? {
        guard let bonsplitID = glacierToBonsplit[glacierID] else { return nil }
        for paneID in controller.allPaneIds {
            if controller.tabs(inPane: paneID).contains(where: { $0.id == bonsplitID }) {
                return paneID
            }
        }
        return nil
    }

    // MARK: - Preview items

    func setPreview(_ item: FileItem?, inPane paneID: PaneID) {
        if let item {
            previewItems[paneID] = item
        } else {
            previewItems.removeValue(forKey: paneID)
        }
    }

    func preview(inPane paneID: PaneID) -> FileItem? {
        previewItems[paneID]
    }

    func clearAllPreviews() {
        previewItems.removeAll()
    }

    // MARK: - Sync tab metadata back to Bonsplit

    /// Push latest title / isDirty from a Glacier Tab into Bonsplit.
    func syncTabMetadata(_ tab: Tab) {
        guard let bonsplitID = glacierToBonsplit[tab.id] else { return }
        controller.updateTab(bonsplitID, title: tab.title, icon: .some(tab.icon), isDirty: tab.isModified)
    }

    // MARK: - BonsplitDelegate

    func splitTabBar(_ controller: BonsplitController, shouldCloseTab tab: Bonsplit.Tab, inPane pane: PaneID) -> Bool {
        guard let glacierID = bonsplitToGlacier[tab.id],
              let appState,
              let glacierTab = appState.tab(with: glacierID) else { return true }
        // Let AppState run its save-confirmation pipeline; if the user cancels,
        // the Glacier tab still exists and we need to veto the Bonsplit close.
        return appState.confirmBonsplitTabClose(glacierTab)
    }

    func splitTabBar(_ controller: BonsplitController, didCloseTab tabId: TabID, fromPane pane: PaneID) {
        guard let glacierID = bonsplitToGlacier.removeValue(forKey: tabId) else { return }
        glacierToBonsplit.removeValue(forKey: glacierID)
        appState?.handleBonsplitTabClosed(glacierID: glacierID)
    }

    func splitTabBar(_ controller: BonsplitController, didSelectTab tab: Bonsplit.Tab, inPane pane: PaneID) {
        guard let glacierID = bonsplitToGlacier[tab.id] else { return }
        // Clear preview for this pane when a real tab is selected
        setPreview(nil, inPane: pane)
        appState?.handleBonsplitTabSelected(glacierID: glacierID, inPane: pane)
    }

    func splitTabBar(_ controller: BonsplitController, didMoveTab tab: Bonsplit.Tab, fromPane source: PaneID, toPane destination: PaneID) {
        // Nothing to do: Bonsplit handles the move internally. AppState just
        // queries Bonsplit for "where is this tab" when it needs to.
    }

    func splitTabBar(_ controller: BonsplitController, didFocusPane pane: PaneID) {
        appState?.handleBonsplitPaneFocused(pane)
    }

    func splitTabBar(_ controller: BonsplitController, didClosePane paneId: PaneID) {
        previewItems.removeValue(forKey: paneId)
    }
}
