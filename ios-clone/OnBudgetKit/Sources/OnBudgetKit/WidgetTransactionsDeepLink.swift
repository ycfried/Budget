// OnBudgetKit — WidgetTransactionsDeepLink.swift
//
// Background task (owner, Nov 25, 2026): the widget's Spending
// side opens the Transactions page — onbudget://transactions.
// The widget's whole-widget link stays onbudget://home; this one
// is Spending-specific. Handled in OnBudgetApp.onOpenURL →
// AppViewModel.goTransactions() (the full list, filters cleared,
// like Home's See All).

import Foundation

public enum WidgetTransactionsDeepLink {
    public static let scheme = "onbudget"
    public static let host = "transactions"

    public static var url: URL { URL(string: "\(scheme)://\(host)")! }

    /// Whether `url` is the widget Transactions link.
    public static func isTransactions(_ url: URL) -> Bool {
        url.scheme == scheme && url.host == host
    }
}
