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

    static func quotaConsumedPercent(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else {
            return "--"
        }
        if value == 0 { return "0%" }
        if value < 0.1 { return "<0.1%" }
        return String(
            format: value.rounded() == value ? "%.0f%%" : "%.1f%%",
            locale: Locale(identifier: "en_US_POSIX"),
            value
        )
    }

    static func cycleQuotaUsage(_ value: Double?) -> String {
        let percent = quotaConsumedPercent(value)
        return percent == "--" ? "额度记录不足" : "额度已用 " + percent
    }

    static func menuBarTitle(
        remainingPercent: Double?,
        isFatal: Bool
    ) -> String {
        guard !isFatal else {
            return "!"
        }

        return self.remainingPercent(remainingPercent)
    }

    static func tokens(_ value: Int64) -> String {
        let magnitude = abs(Double(value))
        guard magnitude >= 10_000 else {
            return String(value)
        }

        let usesHundredMillions = magnitude >= 100_000_000
        let divisor = usesHundredMillions ? 100_000_000.0 : 10_000.0
        let suffix = usesHundredMillions ? "亿" : "万"
        let scaled = Double(value) / divisor
        let rounded = (scaled * 10)
            .rounded(.toNearestOrAwayFromZero) / 10
        let number = String(
            format: "%.1f",
            locale: Locale(identifier: "en_US_POSIX"),
            rounded
        )
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

    static func resetTime(_ value: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MM/dd · HH:mm"
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
