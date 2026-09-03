import AppKit

@main
enum CodexUsageWatcherMain {
    @MainActor
    static func main() {
        let watcher = CodexApplicationWatcher()
        watcher.start()
        RunLoop.main.run()
        withExtendedLifetime(watcher) {}
    }
}
