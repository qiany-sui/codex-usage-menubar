import Foundation
import UsageCore

enum UsageFormatters {
    static func remainingPercent(_ value: Double?) -> String {
        guard let value else {
            return "--"
        }

        let clamped = min(max(value, 0), 100)
        let rounded = clamped.rounded(.toNearestOrAwayFromZero)
        return "\(Int(rounded))%"
    }

    static func menuBarTitle(
        remainingPercent: Double?,
        isFatal: Bool
    ) -> String {
        guard !isFatal else {
            return "◔ !"
        }

        return "◔ \(self.remainingPercent(remainingPercent))"
    }

    static func tokens(_ value: Int64) -> String {
        let magnitude = abs(Double(value))
        guard magnitude >= 1_000 else {
            return String(value)
        }

        let divisor = magnitude < 1_000_000 ? 1_000.0 : 1_000_000.0
        let suffix = magnitude < 1_000_000 ? "K" : "M"
        let scaled = Double(value) / divisor
        let digits = abs(scaled) < 10 ? 1 : 0
        let roundingFactor = digits == 1 ? 10.0 : 1.0
        let rounded = (scaled * roundingFactor)
            .rounded(.toNearestOrAwayFromZero) / roundingFactor
        var number = String(
            format: "%.*f",
            locale: Locale(identifier: "en_US_POSIX"),
            digits,
            rounded
        )
        if number.hasSuffix(".0") {
            number.removeLast(2)
        }
        return number + suffix
    }

    static func resetCountdown(resetsAt: Date, now: Date) -> String {
        let remainingSeconds = resetsAt.timeIntervalSince(now)
        guard remainingSeconds >= 60 else {
            return "即将重置"
        }

        let totalMinutes = Int(remainingSeconds / 60)
        let totalHours = totalMinutes / 60
        let days = totalHours / 24
        let hours = totalHours % 24

        if days > 0 {
            if hours > 0 {
                return "\(days) 天 \(hours) 小时后重置"
            }
            return "\(days) 天后重置"
        }
        if totalHours > 0 {
            return "\(totalHours) 小时后重置"
        }
        return "\(totalMinutes) 分钟后重置"
    }

    static func lastUpdated(_ date: Date, now: Date) -> String {
        let elapsedSeconds = max(now.timeIntervalSince(date), 0)
        if elapsedSeconds < 60 {
            return "刚刚更新"
        }
        if elapsedSeconds < 60 * 60 {
            return "\(Int(elapsedSeconds / 60)) 分钟前更新"
        }

        return dateTime(
            date,
            timeZone: TimeZone(identifier: "Asia/Shanghai")!,
            locale: Locale(identifier: "zh_CN")
        ) + " 更新"
    }

    static func day(_ value: LocalDay) -> String {
        "\(value.month)/\(value.day)"
    }

    static func dateTime(
        _ value: Date,
        timeZone: TimeZone,
        locale: Locale = Locale(identifier: "zh_CN")
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: value)
    }

    static func cycleRange(
        startsAt: Date,
        endsAt: Date,
        timeZone: TimeZone,
        locale: Locale = Locale(identifier: "zh_CN")
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "M/d"
        return "\(formatter.string(from: startsAt)) – \(formatter.string(from: endsAt))"
    }

    static func calibration(_ status: UsageCalibrationStatus) -> String {
        switch status {
        case .localLive:
            "本机实时"
        case .calibrated:
            "已校准"
        case .partiallyCalibrated:
            "部分校准"
        case .stale:
            "数据可能已过期"
        case .unavailable:
            "暂无数据"
        }
    }
}
