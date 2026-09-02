import AppKit
import SwiftUI
import UsageCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var prepareToTerminate: (() async -> Void)?

    private var isTerminating = false

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard !isTerminating else {
            return .terminateNow
        }
        isTerminating = true

        Task {
            if let prepareToTerminate {
                await prepareToTerminate()
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct CodexUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel: UsageViewModel

    init() {
        let container = AppContainer.live()
        _viewModel = StateObject(
            wrappedValue: UsageViewModel(
                runtimeBuilder: container,
                bookmarkStore: CodexHomeBookmarkStore(),
                chooseCodexHome: AppContainer.chooseCodexHome
            )
        )
    }

    var body: some Scene {
        MenuBarExtra {
            UsagePopoverView(viewModel: viewModel)
                .onAppear {
                    Task { await viewModel.openPopover() }
                }
        } label: {
            let presentation = viewModel.menuBarPresentation

            HStack(spacing: 2) {
                switch presentation.icon {
                case let .quota(progress):
                    Image(
                        nsImage: MenuBarQuotaImageRenderer.image(
                            progress: progress
                        )
                    )
                    .renderingMode(.template)
                    .frame(width: 13, height: 13)
                case .fatal:
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .symbolRenderingMode(.monochrome)
                }
                Text(presentation.title)
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .offset(y: 0.5)
            }
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(presentation.accessibilityLabel)
                .task {
                    appDelegate.prepareToTerminate = {
                        await viewModel.stop()
                    }
                    await viewModel.start()
                }
                .onReceive(
                    NSWorkspace.shared.notificationCenter.publisher(
                        for: NSWorkspace.didWakeNotification
                    )
                ) { _ in
                    Task { await viewModel.handleWake() }
                }
        }
        .menuBarExtraStyle(.window)
    }
}

enum MenuBarQuotaImageRenderer {
    private static let size = NSSize(width: 13, height: 13)
    private static let lineWidth: CGFloat = 2
    private static let dotSize: CGFloat = 3

    static func image(progress: Double?) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            let radius = min(rect.width, rect.height) / 2 - lineWidth / 2
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let circleRect = NSRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )

            NSColor.black.withAlphaComponent(0.28).setStroke()
            let track = NSBezierPath(ovalIn: circleRect)
            track.lineWidth = lineWidth
            track.stroke()

            guard let progress else {
                return true
            }
            let normalizedProgress = min(max(progress, 0), 1)
            guard normalizedProgress > 0 else {
                return true
            }

            NSColor.black.setStroke()
            let endAngle = 90 - CGFloat(normalizedProgress) * 360
            let arc = NSBezierPath()
            arc.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: 90,
                endAngle: endAngle,
                clockwise: true
            )
            arc.lineWidth = lineWidth
            arc.lineCapStyle = .round
            arc.stroke()

            let radians = endAngle * .pi / 180
            let dotCenter = NSPoint(
                x: center.x + cos(radians) * radius,
                y: center.y + sin(radians) * radius
            )
            NSColor.black.setFill()
            NSBezierPath(
                ovalIn: NSRect(
                    x: dotCenter.x - dotSize / 2,
                    y: dotCenter.y - dotSize / 2,
                    width: dotSize,
                    height: dotSize
                )
            ).fill()

            return true
        }
        image.isTemplate = true
        return image
    }
}
