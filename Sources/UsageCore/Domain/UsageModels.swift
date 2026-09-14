import Foundation
public enum UsageCalibrationStatus: String, Codable, Sendable { case localLive, calibrated, partiallyCalibrated, stale, unavailable }
public struct QuotaSnapshot: Codable, Equatable, Sendable { public let limitID:String; public let usedPercent:Double; public let windowDurationMinutes:Int; public let startsAt:Date; public let resetsAt:Date; public let fetchedAt:Date; public init(limitID:String,usedPercent:Double,windowDurationMinutes:Int,startsAt:Date,resetsAt:Date,fetchedAt:Date){self.limitID=limitID;self.usedPercent=usedPercent;self.windowDurationMinutes=windowDurationMinutes;self.startsAt=startsAt;self.resetsAt=resetsAt;self.fetchedAt=fetchedAt}; public var remainingPercent:Double{min(100,max(0,100-usedPercent))} }
public struct UsageDay: Codable, Equatable, Sendable { public let day:LocalDay; public let localUsage:TokenBreakdown; public let officialTokens:Int64?; public let displayedTokens:Int64; public let status:UsageCalibrationStatus; public let quotaConsumedPercent:Double?; public let quotaSegments:[QuotaConsumptionSegment]?; public let recordedQuotaConsumedPercent:Double?; public init(day:LocalDay,localUsage:TokenBreakdown,officialTokens:Int64?,displayedTokens:Int64,status:UsageCalibrationStatus,quotaConsumedPercent:Double?=nil,quotaSegments:[QuotaConsumptionSegment]?=nil,recordedQuotaConsumedPercent:Double?=nil){self.day=day;self.localUsage=localUsage;self.officialTokens=officialTokens;self.displayedTokens=displayedTokens;self.status=status;self.quotaConsumedPercent=quotaConsumedPercent;self.quotaSegments=quotaSegments;self.recordedQuotaConsumedPercent=recordedQuotaConsumedPercent} }
public struct QuotaCycle: Codable, Equatable, Sendable { public let startsAt:Date; public let endsAt:Date; public let usage:TokenBreakdown; public let displayedTokens:Int64; public let status:UsageCalibrationStatus; public let boundaryIsEstimated:Bool; public let quotaUsedPercent:Double?; public let lastRecordedQuota:QuotaSnapshot?; public init(startsAt:Date,endsAt:Date,usage:TokenBreakdown,displayedTokens:Int64,status:UsageCalibrationStatus,boundaryIsEstimated:Bool,quotaUsedPercent:Double?=nil,lastRecordedQuota:QuotaSnapshot?=nil){self.startsAt=startsAt;self.endsAt=endsAt;self.usage=usage;self.displayedTokens=displayedTokens;self.status=status;self.boundaryIsEstimated=boundaryIsEstimated;self.quotaUsedPercent=quotaUsedPercent;self.lastRecordedQuota=lastRecordedQuota} }
public struct UsageSnapshot: Codable, Equatable, Sendable { public let quota:QuotaSnapshot?; public let today:UsageDay; public let currentCycle:QuotaCycle?; public let recentDays:[UsageDay]; public let cycleHistory:[QuotaCycle]; public let lastUpdatedAt:Date; public let status:UsageCalibrationStatus; public init(quota:QuotaSnapshot?,today:UsageDay,currentCycle:QuotaCycle?,recentDays:[UsageDay],cycleHistory:[QuotaCycle],lastUpdatedAt:Date,status:UsageCalibrationStatus){self.quota=quota;self.today=today;self.currentCycle=currentCycle;self.recentDays=recentDays;self.cycleHistory=cycleHistory;self.lastUpdatedAt=lastUpdatedAt;self.status=status} }

public struct QuotaConsumptionSegment: Codable, Equatable, Sendable {
    public let startsAt: Date
    public let endsAt: Date
    public let consumedPercent: Double?
    public let startsWithReset: Bool
    public let recordedConsumedPercent: Double?

    public init(startsAt: Date, endsAt: Date, consumedPercent: Double?, startsWithReset: Bool, recordedConsumedPercent: Double? = nil) {
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.consumedPercent = consumedPercent
        self.startsWithReset = startsWithReset
        self.recordedConsumedPercent = recordedConsumedPercent
    }
}
