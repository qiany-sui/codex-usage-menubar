import Foundation
import XCTest
@testable import CodexUsage

func temporaryAppDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "CodexUsageAppTests-" + UUID().uuidString,
            isDirectory: true
        )
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true
    )
    return url
}

func validCodexHome() throws -> URL {
    let root = try temporaryAppDirectory()
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("sessions", isDirectory: true),
        withIntermediateDirectories: true
    )
    return root
}

func fixedDate(_ text: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let value = formatter.date(from: text) {
        return value
    }

    formatter.formatOptions = [.withInternetDateTime]
    return try XCTUnwrap(formatter.date(from: text))
}
