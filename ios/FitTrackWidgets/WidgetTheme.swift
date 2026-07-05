import SwiftUI

/// Widget-local copy of the app's design tokens (DesignSystem/Theme.swift).
/// Theme.swift isn't compiled into the extension because it pulls in
/// app-only UIKit APIs; keep these values in sync with the app.
enum WidgetTheme {
    static let accentTeal = Color(red: 0.0, green: 0.62, blue: 0.55)
    static let accentGradient = LinearGradient(
        colors: [Color(red: 0.10, green: 0.74, blue: 0.66), accentTeal],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static let protein = Color(red: 0.91, green: 0.30, blue: 0.24)
    static let carbs = Color(red: 0.95, green: 0.61, blue: 0.07)
    static let fat = Color(red: 0.40, green: 0.49, blue: 0.92)
    static let energy = Color.orange

    /// Mirrors MealType.icon / .color in the app.
    static func mealIcon(_ type: String) -> String {
        switch type {
        case "breakfast": "sunrise.fill"
        case "lunch": "sun.max.fill"
        case "dinner": "moon.stars.fill"
        default: "carrot.fill"
        }
    }

    static func mealColor(_ type: String) -> Color {
        switch type {
        case "breakfast": .orange
        case "lunch": accentTeal
        case "dinner": .indigo
        default: .pink
        }
    }
}
