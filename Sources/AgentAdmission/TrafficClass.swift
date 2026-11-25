/// Where a request entered the app. Set by the app's entry point (a SwiftUI action, an
/// `AppIntent.perform()`, a widget timeline provider), **never** trusted by the server on its
/// own: the server takes the effective class from the scope grant the token was issued for
/// (see ``ScopeAuthority``), so a client cannot jump the queue by claiming `.interactiveUI`.
public enum CallerClass: String, CaseIterable, Sendable, Codable, Hashable {
    /// A person tapping in the app's own UI and watching a spinner.
    case interactiveUI
    /// A widget timeline refresh. Background, deferrable, retried by the system.
    case widget
    /// A Shortcuts automation. Agent-shaped: unattended, bursty, retries on its own.
    case shortcut
    /// A Siri AI / App Intents invocation planned by an assistant. Bursty and retry-happy.
    case siriAgent

    /// `true` for traffic an assistant or automation produced rather than a person's tap.
    public var isAgentOriginated: Bool {
        switch self {
        case .siriAgent, .shortcut: return true
        case .interactiveUI, .widget: return false
        }
    }
}

/// Whether the request changes server state. Writes must carry an ``IdempotencyKey``.
public enum OperationKind: String, CaseIterable, Sendable, Codable, Hashable {
    case read
    case write
}

/// The unit admission control reasons about: who is calling and what they want to do.
public struct TrafficClass: Hashable, Sendable, Codable, CustomStringConvertible {
    public let caller: CallerClass
    public let kind: OperationKind

    public init(_ caller: CallerClass, _ kind: OperationKind) {
        self.caller = caller
        self.kind = kind
    }

    /// Shed order under overload. Tier 0 is shed first.
    ///
    /// | tier | traffic | why it goes in this order |
    /// |---|---|---|
    /// | 0 | agent read | the agent can re-ask, reword, or answer from context; nobody is staring at it |
    /// | 1 | widget (read or write) | the system retries timeline reloads; stale-by-a-minute is fine |
    /// | 2 | agent write | a spoken "order my usual" is a real user intent; dropping it costs more than a read |
    /// | 3 | interactive UI | a person is waiting on a spinner; shed last |
    public var shedTier: ShedTier {
        switch (caller, kind) {
        case (.siriAgent, .read), (.shortcut, .read): return .agentRead
        case (.widget, _): return .widget
        case (.siriAgent, .write), (.shortcut, .write): return .agentWrite
        case (.interactiveUI, _): return .interactive
        }
    }

    public var description: String { "\(caller.rawValue).\(kind.rawValue)" }

    /// Every (caller, kind) pair, in a stable order for reports.
    public static let all: [TrafficClass] = CallerClass.allCases.flatMap { caller in
        OperationKind.allCases.map { TrafficClass(caller, $0) }
    }
}

/// Shed tiers, lowest is shed first. `rawValue` doubles as queue priority (higher is served first).
public enum ShedTier: Int, CaseIterable, Sendable, Codable, Comparable, Hashable {
    case agentRead = 0
    case widget = 1
    case agentWrite = 2
    case interactive = 3

    public static func < (lhs: ShedTier, rhs: ShedTier) -> Bool { lhs.rawValue < rhs.rawValue }
}
