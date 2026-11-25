/// What an App Intent tells the person (spoken by Siri, or shown in the UI) when the backend
/// says no. Every sentence is built from what the outcome guarantees **for this attempt**:
/// a shed request never ran, so "this request didn't go through" is true; a handler failure
/// guarantees nothing, so the message says to check. The presenter never claims an earlier
/// attempt of the same intent did nothing, because it can't know that.
public struct UserFacingFallback: Sendable, Equatable {
    public let spoken: String
    public let visual: String
    /// Whole seconds to suggest waiting, rounded up, or `nil` when retrying won't help.
    public let retryAfterSeconds: Int?
    /// About **this attempt** only: `false` when the outcome proves it ran nothing, `true` when
    /// the work is still in progress elsewhere and will run, `nil` when the outcome can't tell.
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
            let seconds = wholeSeconds(retryAfterMillis)
            let wait = waitPhrase(seconds)
            switch kind {
            case .write:
                return UserFacingFallback(
                    spoken: "I couldn't \(action) right now because the service is busy, so this request didn't go through. \(wait).",
                    visual: "Busy — this request didn't go through. \(wait).",
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
        case let .inProgress(retryAfterMillis):
            let seconds = wholeSeconds(retryAfterMillis)
            return UserFacingFallback(
                spoken: "I'm still working on that. Ask me again in a few seconds and I'll tell you how it went. It won't be done twice.",
                visual: "Still in progress — check again shortly. It won't run twice.",
                retryAfterSeconds: seconds,
                mayHaveExecuted: true
            )
        case .denied(.expired), .denied(.unknownToken):
            return UserFacingFallback(
                spoken: "My permission to \(action) has expired. Open the app to refresh it.",
                visual: "Permission expired — open the app to refresh it.",
                retryAfterSeconds: nil,
                mayHaveExecuted: false
            )
        case .denied:
            return UserFacingFallback(
                spoken: "I'm not allowed to \(action) from here. Open the app to do it there.",
                visual: "Not allowed from here. Open the app.",
                retryAfterSeconds: nil,
                mayHaveExecuted: false
            )
        case .rejected(.missingIdempotencyKey):
            return UserFacingFallback(
                spoken: "I couldn't \(action) because the request was incomplete, so it didn't go through.",
                visual: "Request incomplete — it didn't go through.",
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

    private static func wholeSeconds(_ millis: Int64) -> Int? {
        guard millis > 0 else { return nil }
        return Saturating.int(Saturating.ceilDivide(millis, 1_000) ?? 1)
    }

    private static func waitPhrase(_ seconds: Int?) -> String {
        seconds.map { "Try again in about \($0) second\($0 == 1 ? "" : "s")" } ?? "Try again in a moment"
    }
}
