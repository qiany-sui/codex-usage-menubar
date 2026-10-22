import Foundation

struct QuotaHistoryReading {
    let quota: QuotaSnapshot
    let isFromSession: Bool
}

func mergingSessionQuotaHistory(_ readings: [QuotaHistoryReading]) -> [QuotaSnapshot] {
    let official = readings.filter { !$0.isFromSession }.map(\.quota)
    guard let latest = official.last else { return [] }
    let resetStarts = CycleTracker().observedResetStarts(quota: latest, history: official)
    let cycleStarts = Set(resetStarts.values).sorted()
    let nextStarts = Dictionary(uniqueKeysWithValues: zip(cycleStarts, cycleStarts.dropFirst()))
    var groups: [Date: [QuotaHistoryReading]] = [:]
    var sessionStarts: [Date: Date] = [:]

    for reading in readings {
        let quota = reading.quota
        let start: Date
        if !reading.isFromSession {
            start = resetStarts[quota.startsAt] ?? quota.startsAt
        } else {
            // 日志会重复携带旧额度；只补充已由主动读取确认的周期和时间范围。
            guard quota.fetchedAt <= latest.fetchedAt else { continue }
            if let mapped = sessionStarts[quota.startsAt] {
                start = mapped
            } else {
                guard let anchor = official.min(by: {
                    abs($0.startsAt.timeIntervalSince(quota.startsAt))
                        < abs($1.startsAt.timeIntervalSince(quota.startsAt))
                }), anchor.windowDurationMinutes == quota.windowDurationMinutes,
                    abs(anchor.startsAt.timeIntervalSince(quota.startsAt)) <= 60 else { continue }
                start = resetStarts[anchor.startsAt] ?? anchor.startsAt
                sessionStarts[quota.startsAt] = start
            }
            guard start.timeIntervalSince(quota.fetchedAt) <= 60,
                  quota.fetchedAt < (nextStarts[start] ?? .distantFuture) else { continue }
        }
        groups[start, default: []].append(reading)
    }

    var result: [QuotaSnapshot] = []
    for (start, group) in groups {
        let ordered = group.sorted { $0.quota.fetchedAt < $1.quota.fetchedAt }
        // 最近一次后续主动读取是上界，后来的清零不能追溯否定已确认的历史。
        var upperBounds = [Double?](repeating: nil, count: ordered.count)
        var upper: Double?
        for index in ordered.indices.reversed() {
            let reading = ordered[index]
            if !reading.isFromSession {
                upper = reading.quota.usedPercent
            }
            upperBounds[index] = upper
        }
        var highWater: Double?
        for (index, reading) in ordered.enumerated() {
            let quota = reading.quota
            if reading.isFromSession {
                guard quota.usedPercent >= (highWater ?? 0),
                      upperBounds[index].map({ quota.usedPercent <= $0 }) ?? true else { continue }
            }
            // 主动读取中的真实下降照常保留，由统计层标记异常，不能静默抹平。
            highWater = max(highWater ?? quota.usedPercent, quota.usedPercent)
            result.append(reading.isFromSession ? QuotaSnapshot(
                limitID: quota.limitID, usedPercent: quota.usedPercent,
                windowDurationMinutes: quota.windowDurationMinutes, startsAt: start,
                resetsAt: quota.resetsAt, fetchedAt: quota.fetchedAt
            ) : quota)
        }
    }
    return result.sorted { $0.fetchedAt < $1.fetchedAt }
}
