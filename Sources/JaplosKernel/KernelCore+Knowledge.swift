import Foundation
import JaplosProtocol

/// Knowledge operations, moved out of the dispatch switch so `KernelCore`
/// only gates policy and routes. Behaviour is unchanged.
extension KernelCore {
    func handleKnowledgeOperations(_ request: KernelRequest) async throws -> KernelResponse {
        let requestID = request.id
        switch request.operation {
            case .knowledgeDocumentsList:
                let limit = request.arguments["limit"]?.intValue ?? 50
                let library = request.arguments["library"]?.stringValue
                let query = request.arguments["query"]?.stringValue ?? ""
                if !query.isEmpty || (library != nil && library != "all" && !(library?.isEmpty ?? true)) {
                    return .success(
                        .array(try store.searchKnowledgeDocuments(query: query, library: library, limit: limit)),
                        requestID: requestID
                    )
                }
                return .success(.array(try store.listKnowledgeDocuments(limit: limit)), requestID: requestID)
            case .knowledgeDocumentsUpsert:
                guard let title = request.arguments["title"]?.stringValue, !title.isEmpty else {
                    return .failure(.invalidArgument("title is required"), requestID: requestID)
                }
                let id = request.arguments["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                let docID = (id?.isEmpty == false) ? id! : UUID().uuidString
                var recordObject = request.arguments["record"]?.objectValue ?? ["title": .string(title)]
                recordObject["title"] = .string(title)
                if let body = request.arguments["body"]?.stringValue ?? request.arguments["text"]?.stringValue {
                    recordObject["body"] = .string(body)
                }
                if let library = request.arguments["library"]?.stringValue, !library.isEmpty {
                    recordObject["library"] = .string(library)
                } else if recordObject["library"] == nil {
                    recordObject["library"] = .string("all")
                }
                if let fileType = request.arguments["fileType"]?.stringValue {
                    recordObject["fileType"] = .string(fileType)
                }
                if let sourcePath = request.arguments["sourcePath"]?.stringValue {
                    recordObject["sourcePath"] = .string(sourcePath)
                }
                if let extractStatus = request.arguments["extractStatus"]?.stringValue {
                    recordObject["extractStatus"] = .string(extractStatus)
                }
                if let extractNote = request.arguments["extractNote"]?.stringValue {
                    recordObject["extractNote"] = .string(extractNote)
                }
                let record = JSONValue.object(recordObject)
                try store.upsertKnowledgeDocument(id: docID, title: title, record: record)
                return .success(.object(["id": .string(docID), "saved": .bool(true)]), requestID: requestID)
            case .knowledgeDocumentsDelete:
                guard let id = request.arguments["id"]?.stringValue, !id.isEmpty else {
                    return .failure(.invalidArgument("id is required"), requestID: requestID)
                }
                try store.deleteKnowledgeDocument(id: id)
                return .success(.object(["id": .string(id), "deleted": .bool(true)]), requestID: requestID)

        default:
            return .failure(.notFound("Unhandled knowledge operation \(request.operation.rawValue)"), requestID: requestID)
        }
    }
}
