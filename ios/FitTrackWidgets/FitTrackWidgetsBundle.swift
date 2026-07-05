import SwiftUI
import WidgetKit

@main
struct FitTrackWidgetsBundle: WidgetBundle {
    var body: some Widget {
        MealLogWidget()
        WorkoutLogWidget()
    }
}
