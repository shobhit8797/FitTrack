import SwiftUI
import UIKit

// Calm, data-forward design system (spec §14). One health-leaning accent (teal),
// generous whitespace, rounded cards. Charts pair color with shape/label so they
// stay color-blind-safe — never color alone.
//
// Everything here is built on Apple's semantic colors + materials so light/dark,
// Increase Contrast, and Dynamic Type come for free.

enum Theme {
    // Brand accent. The teal is the single source of truth (the old asset-catalog
    // "Accent" reference was dead — there's no .xcassets in this project).
    static let accentTeal = Color(red: 0.0, green: 0.62, blue: 0.55)
    static var accent: Color { accentTeal }
    /// Subtle top-lit gradient for the ring / hero accents.
    static let accentGradient = LinearGradient(
        colors: [Color(red: 0.10, green: 0.74, blue: 0.66), accentTeal],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static let protein = Color(red: 0.91, green: 0.30, blue: 0.24) // warm
    static let carbs = Color(red: 0.95, green: 0.61, blue: 0.07)   // amber
    static let fat = Color(red: 0.40, green: 0.49, blue: 0.92)     // blue

    // 8pt grid (spec §14). Names are stable — views reference these directly.
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let sm: CGFloat = 12
        static let m: CGFloat = 16
        static let ml: CGFloat = 20
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
    }

    static let cardRadius: CGFloat = 20
    static let minTapTarget: CGFloat = 44
}

extension MealType {
    var icon: String {
        switch self {
        case .breakfast: return "sunrise.fill"
        case .lunch:     return "sun.max.fill"
        case .dinner:    return "moon.stars.fill"
        case .snack:     return "carrot.fill"
        }
    }
}

// MARK: - Haptics

/// Centralized, intent-named haptics (ios-app-design: "haptics with intent").
/// Thin wrapper over UIKit generators so non-View code (view models) can fire too;
/// in Views prefer `.sensoryFeedback` directly where it reads cleanly.
enum Haptics {
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func error()   { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
    static func tap(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}

// MARK: - Cards & surfaces

/// Rounded card container used across screens. Material gives layered depth;
/// a hairline stroke + soft shadow keep it crisp on both light and dark.
struct Card<Content: View>: View {
    var padding: CGFloat = Theme.Spacing.m
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.05), radius: 8, y: 4)
    }
}

/// Lightweight section header — a tighter, more deliberate alternative to a bare
/// `.headline` Text, with optional trailing accessory.
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.semibold))
            Spacer(minLength: Theme.Spacing.s)
            trailing
        }
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Buttons

/// The app's single primary CTA style — full-width, branded gradient, springy
/// press feedback + selection haptic. Use for the one obvious action on a screen.
struct PrimaryButtonStyle: ButtonStyle {
    var enabled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .frame(minHeight: Theme.minTapTarget)
            .foregroundStyle(.white)
            .background(
                Theme.accentGradient.opacity(enabled ? 1 : 0.4),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - States

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
                .font(.system(size: 46))
                .foregroundStyle(Theme.accentTeal.gradient)
                .symbolRenderingMode(.hierarchical)
            VStack(spacing: Theme.Spacing.xs) {
                Text(title).font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(actionTitle) {
                    Haptics.tap()
                    action()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accentTeal)
                .controlSize(.large)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity)
    }
}

/// Skeleton placeholder line — pair with `.redacted(reason:.placeholder)` to
/// stand in for content while it loads (ios-app-design: skeletons over spinners).
struct SkeletonBar: View {
    var width: CGFloat? = nil
    var height: CGFloat = 14
    var body: some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(Color.primary.opacity(0.08))
            .frame(width: width, height: height)
    }
}
