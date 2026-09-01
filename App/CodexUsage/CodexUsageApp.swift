import AppKit
import SwiftUI
import UsageCore

@main
struct CodexUsageApp: App {
    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 12) {
                Text("Codex Usage")
                    .font(.headline)
                Text("正在准备本机用量数据…")
                    .foregroundStyle(.secondary)
                Divider()
                Button("退出 Codex Usage") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(16)
            .frame(
                width: 410,
                height: 440,
                alignment: .topLeading
            )
            .preferredColorScheme(.dark)
        } label: {
            Text("◔ --")
        }
        .menuBarExtraStyle(.window)
    }
}
