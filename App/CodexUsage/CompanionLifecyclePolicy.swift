enum CompanionLifecycleEvent: Equatable {
    case initialState(codexRunning: Bool)
    case codexLaunched
    case terminationCheck(codexRunning: Bool)
}

enum CompanionLifecycleAction: Equatable {
    case none
    case launchUsage
    case terminateUsage
}

enum CompanionLifecyclePolicy {
    static func action(
        for event: CompanionLifecycleEvent
    ) -> CompanionLifecycleAction {
        switch event {
        case .initialState(codexRunning: true), .codexLaunched:
            return .launchUsage
        case .terminationCheck(codexRunning: false):
            return .terminateUsage
        case .initialState(codexRunning: false),
             .terminationCheck(codexRunning: true):
            return .none
        }
    }
}
