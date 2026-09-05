import Foundation

/// Accumulates only playing time so pausing never resets the label's angle.
struct VinylRotation {
    private var accumulatedDegrees: Double = 0
    private var startedAt: Date?

    func degrees(at date: Date) -> Double {
        let elapsed = startedAt.map { max(0, date.timeIntervalSince($0)) } ?? 0
        return (accumulatedDegrees + elapsed * 24).truncatingRemainder(dividingBy: 360)
    }

    mutating func setSpinning(_ spinning: Bool, at date: Date) {
        accumulatedDegrees = degrees(at: date)
        startedAt = spinning ? date : nil
    }
}

/// Row insets follow the circle at their visible scroll position, including row height.
enum VinylQueueArc {
    static func leadingInset(rowMidY: CGFloat, diameter: CGFloat) -> CGFloat {
        let radius = diameter / 2
        let nearestY = max(0, abs(rowMidY - radius) - 26)
        let edge = sqrt(max(0, radius * radius - nearestY * nearestY))
        return max(8, radius + edge + 18 - diameter * 0.62)
    }
}

