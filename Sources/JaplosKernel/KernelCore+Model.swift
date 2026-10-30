import Foundation
import JaplosProtocol

/// Model operations, moved out of the dispatch switch so `KernelCore`
/// only gates policy and routes. Behaviour is unchanged.
extension KernelCore {
    func handleModelOperations(_ request: KernelRequest) async throws -> KernelResponse {
        let requestID = request.id
        switch request.operation {
            case .modelRoutesList:
                return .success(.array(try store.listCustomModelRoutes()), requestID: requestID)
            case .modelRoutesSet:
                guard let routeID = request.arguments["routeID"]?.stringValue, !routeID.isEmpty else {
                    return .failure(.invalidArgument("routeID is required"), requestID: requestID)
                }
                let record = request.arguments["record"] ?? .object([:])
                try store.upsertCustomModelRoute(routeID: routeID, record: record, createdBy: request.principal)
                return .success(.object(["routeID": .string(routeID), "saved": .bool(true)]), requestID: requestID)
            case .modelRoutesDelete:
                guard let routeID = request.arguments["routeID"]?.stringValue, !routeID.isEmpty else {
                    return .failure(.invalidArgument("routeID is required"), requestID: requestID)
                }
                try store.deleteCustomModelRoute(routeID: routeID)
                return .success(.object(["routeID": .string(routeID), "deleted": .bool(true)]), requestID: requestID)
            case .speechProfilesList:
                return .success(.array(try store.listSpeechProfiles()), requestID: requestID)
            case .speechProfilesSet:
                guard let profileID = request.arguments["profileID"]?.stringValue, !profileID.isEmpty else {
                    return .failure(.invalidArgument("profileID is required"), requestID: requestID)
                }
                let providerID = request.arguments["providerID"]?.stringValue ?? "system"
                let isDefault = request.arguments["isDefault"]?.boolValue ?? false
                let record = request.arguments["record"] ?? .object([:])
                try store.upsertSpeechProfile(
                    profileID: profileID,
                    providerID: providerID,
                    isDefault: isDefault,
                    record: record
                )
                return .success(.object([
                    "profileID": .string(profileID),
                    "saved": .bool(true),
                    "isDefault": .bool(isDefault),
                ]), requestID: requestID)
            case .modelTest, .modelCatalog:
                let handler = modelHandlerClosure
                guard let handler else {
                    return .failure(.internalError("Model runtime is not configured"), requestID: requestID)
                }
                return await handler(request)


        default:
            return .failure(.notFound("Unhandled model operation \(request.operation.rawValue)"), requestID: requestID)
        }
    }
}
