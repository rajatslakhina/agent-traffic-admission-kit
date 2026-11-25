import Foundation

/// One thing a skill may do: an operation kind on a named resource, e.g. `orders` / `.write`.
public struct Capability: Hashable, Sendable, Codable, CustomStringConvertible {
    public let resource: String
    public let kind: OperationKind

    public init(_ resource: String, _ kind: OperationKind) {
        self.resource = resource
        self.kind = kind
    }

    public var description: String { "\(resource).\(kind.rawValue)" }
}

/// What a token was issued for. The server reads the caller class from here, not from the request.
public struct SkillGrant: Sendable, Equatable {
    public let skillID: String
    public let caller: CallerClass
    public let capabilities: Set<Capability>
    public let expiresAtMillis: Int64

    public init(skillID: String, caller: CallerClass, capabilities: Set<Capability>, expiresAtMillis: Int64) {
        self.skillID = skillID
        self.caller = caller
        self.capabilities = capabilities
        self.expiresAtMillis = expiresAtMillis
    }
}

/// An opaque bearer handle. It carries no claims; everything lives server-side in the grant.
public struct ScopeToken: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    /// Never print the token itself.
    public var description: String { "ScopeToken(…\(rawValue.suffix(4)))" }
}

public enum AuthorizationFailure: Error, Sendable, Equatable {
    case unknownToken
    case expired
    case capabilityNotGranted(Capability)
    /// The request claimed a different entry point than the token was issued for. Denied rather
    /// than silently corrected, so a misrouted token shows up in development, not in production
    /// priority inversions.
    case callerClassMismatch(claimed: CallerClass, granted: CallerClass)
}

public enum GrantIssueFailure: Error, Sendable, Equatable {
    case tooManyGrants
    case alreadyExpired
    case emptyCapabilities
}

/// Server-side store of skill grants: least privilege per skill, bound to one caller class,
/// time-limited and revocable.
///
/// Honest limit: binding the class to the token stops an honest-but-buggy client (or a
/// confused-deputy agent path) from borrowing UI priority or another skill's capabilities. It
/// does not stop a malicious client that holds a UI token from replaying it on the agent path;
/// that needs device attestation, which is out of scope.
public struct ScopeAuthority: Sendable {
    public let maxGrants: Int
    private var grants: [ScopeToken: SkillGrant] = [:]

    public init(maxGrants: Int = 10_000) {
        self.maxGrants = max(1, maxGrants)
    }

    public var grantCount: Int { grants.count }

    /// - Parameter makeToken: token source; the default is a UUID (122 random bits).
    public mutating func issue(
        _ grant: SkillGrant,
        now: Int64,
        makeToken: () -> String = { UUID().uuidString }
    ) -> Result<ScopeToken, GrantIssueFailure> {
        guard !grant.capabilities.isEmpty else { return .failure(.emptyCapabilities) }
        guard now < grant.expiresAtMillis else { return .failure(.alreadyExpired) }
        if grants.count >= maxGrants { purgeExpired(now: now) }
        guard grants.count < maxGrants else { return .failure(.tooManyGrants) }
        var token = ScopeToken(rawValue: makeToken())
        // A colliding token source must never overwrite (and so re-scope) a live grant.
        var attempts = 0
        while grants[token] != nil {
            attempts += 1
            guard attempts < 8 else { return .failure(.tooManyGrants) }
            token = ScopeToken(rawValue: makeToken() + "-\(attempts)")
        }
        grants[token] = grant
        return .success(token)
    }

    public mutating func revoke(_ token: ScopeToken) {
        grants[token] = nil
    }

    public func authorize(
        _ token: ScopeToken,
        capability: Capability,
        claimedCaller: CallerClass,
        now: Int64
    ) -> Result<SkillGrant, AuthorizationFailure> {
        guard let grant = grants[token] else { return .failure(.unknownToken) }
        guard now < grant.expiresAtMillis else { return .failure(.expired) }
        guard grant.caller == claimedCaller else {
            return .failure(.callerClassMismatch(claimed: claimedCaller, granted: grant.caller))
        }
        guard grant.capabilities.contains(capability) else {
            return .failure(.capabilityNotGranted(capability))
        }
        return .success(grant)
    }

    public mutating func purgeExpired(now: Int64) {
        grants = grants.filter { now < $0.value.expiresAtMillis }
    }
}
