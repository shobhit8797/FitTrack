import SwiftUI

// The dashboard focal element (spec §7.1, §14). Consumed vs the user's own
// target. VoiceOver-described; Reduce-Motion-aware.

struct CalorieRing: View {
    let consumed: Int
    let target: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var progress: Double {
        guard target > 0 else { return 0 }
        return min(Double(consumed) / Double(target), 1.0)
    }
    private var remaining: Int { max(target - consumed, 0) }
    private var over: Bool { consumed > target }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.15), lineWidth: 18)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    over ? Theme.protein : Theme.accentTeal,
                    style: StrokeStyle(lineWidth: 18, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: progress)
            VStack(spacing: 2) {
                Text("\(consumed)")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text(over ? "\(consumed - target) over" : "\(remaining) left")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("of \(target) kcal")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 200, height: 200)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Calories")
        .accessibilityValue("\(consumed) of \(target) kilocalories, \(over ? "\(consumed - target) over target" : "\(remaining) remaining")")
    }
}

/// Macro progress bar (protein highlighted). Pairs color with a text label.
struct MacroBar: View {
    let name: String
    let current: Double
    let target: Int
    let color: Color

    private var progress: Double {
        guard target > 0 else { return 0 }
        return min(current / Double(target), 1.0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                Text(name).font(.caption).fontWeight(.medium)
                Spacer()
                Text("\(Int(current)) / \(target) g")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.18))
                    Capsule().fill(color).frame(width: geo.size.width * progress)
                }
            }
            .frame(height: 8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name): \(Int(current)) of \(target) grams")
    }
}
