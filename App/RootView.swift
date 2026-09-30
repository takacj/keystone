import SwiftUI

/// Top-level content: onboarding until `az` and an account are available, then the main window.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.azureStatus == .checking {
                ProgressView("Looking for Azure CLI…")
            } else if model.needsOnboarding {
                OnboardingView()
            } else {
                MainView()
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .task { await model.bootstrap() }
    }
}
