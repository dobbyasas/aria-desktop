import Foundation

extension TimeInterval {
    var ariaDurationText: String {
        guard isFinite, self > 0 else { return "--:--" }
        return ariaClockText
    }

    var ariaClockText: String {
        guard isFinite, self > 0 else { return "0:00" }

        let totalSeconds = Int(self.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return "\(hours):\(String(format: "%02d", minutes)):\(String(format: "%02d", seconds))"
        }

        return "\(minutes):\(String(format: "%02d", seconds))"
    }
}
