import Charts
import SwiftUI

// Progress & charts (spec §7.6): weight trend + 7-day MA, calories vs target,
// macro adherence, workout heatmap. Range selector, color-blind-safe palette,
// VoiceOver. This wires the weight trend; other series follow the same shape.
struct ProgressDashboardView: View {
    @Environment(Repository.self) private var repo
    @State private var weights: [WeightEntry] = []
    @State private var range: ChartRange = .month

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    Picker("Range", selection: $range) {
                        ForEach(ChartRange.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    Card {
                        VStack(alignment: .leading) {
                            Text("Weight").font(.headline)
                            if filteredWeights.isEmpty {
                                EmptyStateView(systemImage: "scalemass", title: "No weight data",
                                               message: "Log your weight to see trends.")
                            } else {
                                weightChart
                            }
                        }
                    }
                }
                .padding(Theme.Spacing.m)
            }
            .navigationTitle("Progress")
            .task {
                do { for try await w in repo.weightStream() { weights = w } } catch {}
            }
        }
    }

    private var filteredWeights: [WeightEntry] {
        guard let cutoff = range.cutoff else { return weights }
        return weights.filter { $0.date >= cutoff }
    }

    private var weightChart: some View {
        Chart {
            ForEach(filteredWeights) { entry in
                LineMark(x: .value("Date", entry.date), y: .value("kg", entry.weightKg))
                    .foregroundStyle(Theme.accentTeal)
                    .symbol(.circle) // shape + color for color-blind safety
            }
            ForEach(movingAverage(), id: \.0) { date, avg in
                LineMark(x: .value("Date", date), y: .value("7-day avg", avg))
                    .foregroundStyle(Theme.fat)
                    .lineStyle(StrokeStyle(dash: [4, 3]))
            }
        }
        .frame(height: 220)
        .chartYScale(domain: .automatic(includesZero: false))
        .accessibilityLabel("Weight trend with 7-day moving average")
    }

    private func movingAverage(window: Int = 7) -> [(Date, Double)] {
        let sorted = filteredWeights.sorted { $0.date < $1.date }
        guard sorted.count >= window else { return [] }
        var result: [(Date, Double)] = []
        for i in (window - 1)..<sorted.count {
            let slice = sorted[(i - window + 1)...i]
            let avg = slice.reduce(0) { $0 + $1.weightKg } / Double(window)
            result.append((sorted[i].date, avg))
        }
        return result
    }
}

enum ChartRange: String, CaseIterable, Identifiable {
    case week, month, quarter, year, all
    var id: String { rawValue }
    var label: String {
        switch self {
        case .week: return "1W"; case .month: return "1M"; case .quarter: return "3M"
        case .year: return "1Y"; case .all: return "All"
        }
    }
    var cutoff: Date? {
        let cal = Calendar.current
        switch self {
        case .week: return cal.date(byAdding: .day, value: -7, to: Date())
        case .month: return cal.date(byAdding: .month, value: -1, to: Date())
        case .quarter: return cal.date(byAdding: .month, value: -3, to: Date())
        case .year: return cal.date(byAdding: .year, value: -1, to: Date())
        case .all: return nil
        }
    }
}
