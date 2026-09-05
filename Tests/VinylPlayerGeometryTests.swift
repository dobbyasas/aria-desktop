import Foundation

/// Compile with VinylPlayerGeometry.swift to run without launching the app.
@main
struct VinylPlayerGeometryTests {
    static func main() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var record = VinylRotation()
        assert(record.degrees(at: start.addingTimeInterval(10)) == 0, "An idle record must remain still")
        record.setSpinning(true, at: start)
        let playingAngle = record.degrees(at: start.addingTimeInterval(3))
        assert(playingAngle > 0 && playingAngle < 360, "Playback must advance the label")
        record.setSpinning(false, at: start.addingTimeInterval(3))
        assert(record.degrees(at: start.addingTimeInterval(30)) == playingAngle, "Pausing must preserve the angle")
        record.setSpinning(true, at: start.addingTimeInterval(30))
        assert(record.degrees(at: start.addingTimeInterval(30)) == playingAngle, "Resuming must not jump")
        record.setSpinning(false, at: start.addingTimeInterval(33))
        assert(abs(record.degrees(at: start.addingTimeInterval(60)) - 2 * playingAngle) < 0.001, "Only playing time should accumulate")
        record.setSpinning(true, at: start.addingTimeInterval(60))
        let longRunningAngle = record.degrees(at: start.addingTimeInterval(86_400))
        assert(longRunningAngle.isFinite && (0..<360).contains(longRunningAngle))

        // Check the full vertical footprint of every visible row, across window sizes and scroll offsets.
        for diameter in stride(from: CGFloat(220), through: 480, by: 20) {
            for midY in stride(from: CGFloat(-52), through: diameter + 52, by: 3) {
                let inset = VinylQueueArc.leadingInset(rowMidY: midY, diameter: diameter)
                assert(inset.isFinite && inset >= 0)
                let rowLeft = diameter * 0.62 + inset
                for y in stride(from: midY - 26, through: midY + 26, by: 2) where y >= 0 && y <= diameter {
                    let radius = diameter / 2
                    let circleEdge = radius + sqrt(max(0, radius * radius - pow(y - radius, 2)))
                    assert(rowLeft >= circleEdge + 17.9, "Queue rows must clear the vinyl at every scroll position")
                }
            }
        }
        print("Vinyl pause/resume and curved queue clearance checks passed.")
    }
}
