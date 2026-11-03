import SwiftUI
import OnBudgetCore

@main
struct OnBudgetApp: App {
    @State private var model = AppModel(onSnapshot: { snapshot in
        if let snapshot { WidgetCache.save(snapshot) } else { WidgetCache.clear() }
    })
    var body: some Scene {
        WindowGroup {
            RootView().environment(model).tint(Brand.blue)
        }
    }
}
