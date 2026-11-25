/// What an App Intent tells the person (spoken by Siri, or shown in the UI) when the backend
/// says no. Every string is built from what the outcome *guarantees*: a shed request was never
/// executed, so "nothing was changed" is true; a handler failure guarantees nothing, so the
/// message says to check.
public struct UserFacingFallback: Sendable, Equatable {
    public let spoken: String
    public let visual: String
    /// Whole seconds to suggest waiting, rounded up, or `nil` when retrying won't help.
    public let retryAfterSeconds: Int?
    /// `false` when the outcome proves nothing ran; `nil` when the outcome can't tell.
    public let mayHaveExecuted: Bool?
}

public enum FallbackPresenter {
    /// - Parameters:
    ///   - action: a verb phrase, e.g. "place your order" or "check your orders".
    /// - Returns: `nil` for success (there is nothing to fall back from).
    public static func fallback<Value>(for outcome: GatewayOutcome<Value>, kind: OperationKind, action: String) -> UserFacingFallback? {
        switch outcome {
        case .success:
            return nil
        case let .shed(_, retryAfterMillis):
            let seconds = retryAfterMillis > 0 ? Saturating.int(Saturating.ceilDivide(retryAfterMillis, 1_000) ?? 1) : nil
            let wait = seconds.map { "Try again in about \($0) second\($0 == 1 ? "" : "s")" } ?? "Try again in a moment"
            switch kind {
            case .write:
                return UserFacingFallback(
                    spoken: "I couldn't \(action) right now because the service is busy. Nothing was changed. \(wait).",
                    visual: "Busy — nothing was changed. \(wait).",
                    retryAfterSeconds: seconds,
                    mayHaveExecuted: false
                )
            case .read:
                return UserFacingFallback(
                    spoken: "I couldn't \(action) right now. \(wait), or open the app.",
                    visual: "Busy. \(wait).",
                    retryAfterSeconds: seconds,
                    mayHaveExecuted: false
                )
            }
        case .denied:
            return UserFacingFallback(
                spoken: "I'm not allowed to \(action) from here. Open the app to do it there.",
                visual: "Not allowed from here. Open the app.",
                retryAfterSeconds: nil,
                mayHaveExecuted: false
            )
        case .rejected(.missingIdempotencyKey):
            return UserFacingFallback(
                spoken: "I couldn't \(action) because the request was incomplete. Nothing was changed.",
                visual: "Request incomplete — nothing was changed.",
                retryAfterSeconds: nil,
                mayHaveExecuted: false
            )
        case .rejected(.idempotencyConflict):
            return UserFacingFallback(
                spoken: "A different request is already using this confirmation, so this one was not run. Open the app to check.",
                visual: "Conflicting request — this one was not run.",
                retryAfterSeconds: nil,
                mayHaveExecuted: false
            )
        case .failed:
            return UserFacingFallback(
                spoken: "Something went wrong while trying to \(action). It may not have finished, so open the app to check before trying again.",
                visual: "Something went wrong — check before retrying.",
                retryAfterSeconds: nil,
                mayHaveExecuted: nil
            )
        }
    }
}
