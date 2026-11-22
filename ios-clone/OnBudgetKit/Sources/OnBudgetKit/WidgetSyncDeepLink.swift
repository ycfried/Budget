// OnBudgetKit — WidgetSyncDeepLink.swift
//
// Build 54 (owner, Nov 21, 2026): the fallback deep link for the
// widget sync button — onbudget://widget-sync. The button's primary
// path is RefreshWidgetIntent (in place, no app open), but the
// owner's iPad tap never reached the intent, so the app now also
// handles this URL: opening the app through it runs a snapshot
// refresh + timeline reload (OnBudgetApp.onOpenURL). The widget's
// whole-widget link is onbudget://home; this one is sync-specific.

import Foundation

public enum WidgetSyncDeepLink {
    public static let scheme = "onbudget"
    public static let host = "widget-sync"

    public static var url: URL { URL(string: "\(scheme)://\(host)")! }

    /// Whether `url` is the widget-sync fallback link.
    public static func isWidgetSync(_ url: URL) -> Bool {
        url.scheme == scheme && url.host == host
    }
}
