import SwiftUI

/// Expiry classification for pills: expired red, ≤30d orange.
enum ExpiryStatus: Equatable {
    case none
    case expired
    case soon(days: Int)
    case ok

    static let window: TimeInterval = 30 * 86400

    static func of(_ date: Date?, now: Date = Date()) -> ExpiryStatus {
        guard let date else { return .none }
        if date < now { return .expired }
        if date <= now.addingTimeInterval(window) {
            return .soon(days: max(1, Int((date.timeIntervalSince(now) / 86400).rounded(.up))))
        }
        return .ok
    }
}

/// Absolute date string used by tooltips.
func absoluteDateString(_ date: Date) -> String {
    date.formatted(date: .long, time: .standard)
}

/// Relative date ("2d ago") with the absolute date as a tooltip.
struct RelativeDateText: View {
    let date: Date?

    var body: some View {
        if let date {
            Text(date, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                .help(absoluteDateString(date))
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }
}

/// Colored expiry pill: red "Expired", orange "in Nd", plain date otherwise.
struct ExpiryPill: View {
    let date: Date?

    var body: some View {
        switch ExpiryStatus.of(date) {
        case .none:
            Text("—").foregroundStyle(.tertiary)
        case .expired:
            pill("Expired", .red)
        case .soon(let days):
            pill("in \(days)d", .orange)
        case .ok:
            if let date {
                Text(date, format: .dateTime.year().month(.abbreviated).day())
                    .foregroundStyle(.secondary)
                    .help(absoluteDateString(date))
            }
        }
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .help(date.map(absoluteDateString) ?? "")
            .accessibilityLabel(text == "Expired" ? "Expired" : "Expires \(text)")
    }
}

/// Pulsing placeholder rows shown while a list loads.
struct SkeletonRows: View {
    var count = 8
    @State private var dim = false

    var body: some View {
        VStack(spacing: 10) {
            ForEach(0..<count, id: \.self) { i in
                HStack(spacing: 12) {
                    bar(width: 120 + CGFloat((i * 37) % 70))
                    Spacer(minLength: 0)
                    bar(width: 50)
                    bar(width: 40)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(dim ? 0.45 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
        .onAppear { dim = true }
        .accessibilityLabel("Loading")
    }

    private func bar(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: width, height: 12)
    }
}

/// Glass capsule toast, shared by palette / copy toasts.
struct ToastLabel: View {
    let text: String
    var systemImage = "checkmark.circle.fill"

    var body: some View {
        Label(text, systemImage: systemImage)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .glassEffect()
            .padding(.bottom, 16)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}
