import Foundation
import JaplosProtocol

public final class PolicyEngine {
    private let store: KernelStore

    public init(store: KernelStore) {
        self.store = store
    }

    /// Any process running as the socket owner is treated as the local user.
    /// The bootstrap grant mirrors the original `kernel.bootstrap.local-user.root`.
    public func bootstrap() throws {
        let grant = PermissionGrant(
            id: "kernel.bootstrap.local-user.root",
            principal: Principal.localUser,
            capability: Capability.root,
            resourcePattern: "*"
        )
        try store.insertGrant(grant)
    }

    public func evaluate(principal: String, capability: String, resource: String) throws -> PolicyDecision {
        if let grant = try store.matchingGrant(principal: principal, capability: capability, resource: resource) {
            return PolicyDecision(
                outcome: .allow,
                principal: principal,
                capability: capability,
                resource: resource,
                reasonCode: "granted",
                message: "Granted by \(grant.id)",
                grantID: grant.id
            )
        }
        return PolicyDecision(
            outcome: .deny,
            principal: principal,
            capability: capability,
            resource: resource,
            reasonCode: "no_matching_grant",
            message: "No grant matches principal, capability, and resource"
        )
    }
}
