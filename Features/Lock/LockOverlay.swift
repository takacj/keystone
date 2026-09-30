import SwiftUI

/// Covers content while locked, blurring it and offering an unlock button.
struct LockOverlay: View {
    @Environment(LockModel.self) private var lock

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThickMaterial)
            VStack(spacing: 12) {
                Image(systemName: "lock.fill").font(.system(size: 40))
                Text("Secreter is locked").font(.title2)
                Button("Unlock with Touch ID") { Task { await lock.unlock() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(lock.isAuthenticating)
            }
        }
        .ignoresSafeArea()
        .task { await lock.unlock() }
    }
}

/// Applies blur + cover + lock lifecycle to a window's content.
private struct LockedModifier: ViewModifier {
    @Environment(LockModel.self) private var lock

    func body(content: Content) -> some View {
        content
            .blur(radius: lock.isLocked ? 30 : 0)
            .allowsHitTesting(!lock.isLocked)
            .accessibilityHidden(lock.isLocked)
            .overlay { if lock.isLocked { LockOverlay() } }
            .onAppear { lock.startMonitoring() }
    }
}

extension View {
    func appLock() -> some View { modifier(LockedModifier()) }
}
