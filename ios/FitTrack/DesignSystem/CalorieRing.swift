import SwiftUI

// The dashboard focal element (spec §7.1, §14). The hero number is what's LEFT
// (the number the user actually acts on when deciding the next meal); consumed
// and target read from the flanking stats + subtitle. VoiceOver-described;
// Reduce-Motion-aware; springs on change and gives a success haptic the moment
// the goal is reached.

struct CalorieRing: View {
    let consumed: Int
    let target: Int
    var diameter: CGFloat = 210
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var progress: Double {
        guard target > 0 else { return 0 }
        return min(Double(consumed) / Double(target), 1.0)
    }
    private var remaining: Int { max(target - consumed, 0) }
    private var over: Bool { consumed > target }
    private var ringStyle: AnyShapeStyle {
        over ? AnyShapeStyle(Theme.protein.gradient) : AnyShapeStyle(Theme.accentGradient)
    }
    private var lineWidth: CGFloat { diameter * 0.088 }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(ringStyle, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.8), value: progress)
            VStack(spacing: 0) {
                Text("\(over ? consumed - target : remaining)")
                    .font(.system(size: diameter * 0.21, weight: .bold, design: .rounded))
                    .foregroundStyle(over ? Theme.protein : Color.primary)
                    .contentTransition(.numericText(value: Double(over ? consumed - target : remaining)))
                    .animation(reduceMotion ? nil : .snappy, value: consumed)
                Text(over ? "kcal over" : "kcal left")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(over ? Theme.protein : Color.secondary)
                Text("of \(target)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        }
        .frame(width: diameter, height: diameter)
        // Success haptic the instant the goal is reached — fires once when the
        // running total first crosses the target, not on every subsequent meal.
        .sensoryFeedback(.success, trigger: target > 0 && consumed >= target)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Calories")
        .accessibilityValue("\(consumed) of \(target) kilocalories eaten, \(over ? "\(consumed - target) over target" : "\(remaining) remaining")")
    }
}

/// Macro progress bar (protein highlighted). Pairs color with a text label, and
/// springs to its new width so totals animate when a meal lands.
struct MacroBar: View {
    let name: String
    let current: Double
    let target: Int
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var progress: Double {
        guard target > 0 else { return 0 }
        return min(current / Double(target), 1.0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                Text(name).font(.subheadline).fontWeight(.medium)
                Spacer()
                Text("\(Int(current)) / \(target) g")
                    .font(.caption).foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: current))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.18))
                    Capsule().fill(color.gradient)
                        .frame(width: max(0, geo.size.width * progress))
                        .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.85), value: progress)
                }
            }
            .frame(height: 8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name): \(Int(current)) of \(target) grams")
    }
}
