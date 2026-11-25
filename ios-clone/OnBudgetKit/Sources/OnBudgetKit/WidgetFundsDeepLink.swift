// OnBudgetKit — WidgetFundsDeepLink.swift
//
// Background task (owner, Nov 25, 2026): the widget's Tzedaka
// side opens the Tzedaka fund — onbudget://funds. The widget's
// whole-widget link stays onbudget://home; this one is
// Tzedaka-specific: it always lands on the charity fund (the
// Funds tab, Tzedaka card expanded), never on another fund.
// Handled in OnBudgetApp.onOpenURL → AppViewModel.goTzedakaFund().

import Foundation

public enum WidgetFundsDeepLink {
    public static let scheme = "onbudget"
    public static let host = "funds"

    public static var url: URL { URL(string: "\(scheme)://\(host)")! }

    /// Whether `url` is the widget Funds link.
    public static func isFunds(_ url: URL) -> Bool {
        url.scheme == scheme && url.host == host
    }
}
