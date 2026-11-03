import SwiftUI
import OnBudgetCore

@main
struct OnBudgetApp: App {
    @State private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            RootView().environment(model).tint(Brand.blue)
        }
    }
}
