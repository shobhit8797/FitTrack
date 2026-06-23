import SwiftUI

// Calm, data-forward design system (spec §14). One health-leaning accent (teal),
// generous whitespace, rounded cards. Charts pair color with shape/label so they
// stay color-blind-safe — never color alone.

enum Theme {
    static let accent = Color("Accent", bundle: nil) // defined in Assets; falls back below
    static let accentTeal = Color(red: 0.0, green: 0.62, blue: 0.55)
    static let protein = Color(red: 0.91, green: 0.30, blue: 0.24) // warm
    static let carbs = Color(red: 0.95, green: 0.61, blue: 0.07)   // amber
    static let fat = Color(red: 0.40, green: 0.49, blue: 0.92)     // blue

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
    }

    static let cardRadius: CGFloat = 20
    static let minTapTarget: CGFloat = 44
}

/// Rounded card container used across screens.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(Theme.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
    }
}

/// Empty state with a single primary action (spec §14).
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accentTeal)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity)
    }
}
