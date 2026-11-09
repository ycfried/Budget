import SwiftUI

/// Placeholder home view. Replaced screen by screen by the screen
/// builders — see ios-clone/PROGRESS.md for the build order.
/// First real screen: Home (stacked Charity above Extra Fund).
struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("OnBudget")
                .font(.largeTitle)
                .bold()
            Text("Native iOS clone — scaffold")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
