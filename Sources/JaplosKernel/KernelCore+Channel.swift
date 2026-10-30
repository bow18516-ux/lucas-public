import Foundation
import JaplosProtocol

/// Channel operations, moved out of the dispatch switch so `KernelCore`
/// only gates policy and routes. Behaviour is unchanged.
extension KernelCore {
    func handleChannelOperations(_ request: KernelRequest) async throws -> KernelResponse {
        let requestID = request.id
        switch request.operation {
            case .runtimeWeChatStatus:
                return .success(enrichedWeChatStatus(), requestID: requestID)
            case .runtimeWeChatConnect:
                return .success(try await wechat.connect(), requestID: requestID)
            case .runtimeWeChatDisconnect:
                return .success(try wechat.disconnect(), requestID: requestID)
            case .runtimeWeChatVerify:
                let code = request.arguments["code"]?.stringValue
                    ?? request.arguments["verificationCode"]?.stringValue
                    ?? ""
                return .success(try wechat.verify(code: code), requestID: requestID)
            case .wechatConnectionList:
                return .success(try wechat.listConnections(), requestID: requestID)
            case .wechatConnectionRemove:
                let id = request.arguments["id"]?.stringValue
                    ?? request.arguments["connectionID"]?.stringValue
                    ?? ""
                return .success(try wechat.removeConnection(id: id), requestID: requestID)

            // MARK: Feishu
            case .runtimeFeishuStatus:
                return .success(try feishu.status(), requestID: requestID)
            case .runtimeFeishuConnect:
                return .success(try await feishu.connect(), requestID: requestID)
            case .runtimeFeishuDisconnect:
                return .success(try feishu.disconnect(), requestID: requestID)
            case .runtimeFeishuSession:
                return .success(try feishu.session(), requestID: requestID)
            case .runtimeFeishuSendText:
                let text = request.arguments["text"]?.stringValue ?? ""
                let receiveID = request.arguments["receiveID"]?.stringValue
                    ?? request.arguments["receive_id"]?.stringValue
                let receiveType = request.arguments["receiveIDType"]?.stringValue
                    ?? request.arguments["receive_id_type"]?.stringValue
                    ?? "open_id"
                return .success(
                    try await feishu.sendTextAsync(text: text, receiveID: receiveID, receiveIDType: receiveType),
                    requestID: requestID
                )
            case .feishuConfigurationOpen:
                return .success(try feishu.openConfiguration(), requestID: requestID)
            case .feishuConfigurationCancel:
                return .success(try feishu.cancelConfiguration(), requestID: requestID)
            case .feishuConnectionConfigure:
                return .success(try feishu.configure(
                    appID: request.arguments["appId"]?.stringValue ?? request.arguments["app_id"]?.stringValue,
                    appSecret: request.arguments["appSecret"]?.stringValue ?? request.arguments["app_secret"]?.stringValue,
                    verificationToken: request.arguments["verificationToken"]?.stringValue
                        ?? request.arguments["verification_token"]?.stringValue
                ), requestID: requestID)

            // MARK: Mail
            case .runtimeMailStatus:
                return .success(try mail.status(), requestID: requestID)
            case .runtimeMailConfigure:
                let imapPort = request.arguments["imapPort"]?.intValue
                    ?? request.arguments["imap_port"]?.intValue
                let smtpPort = request.arguments["smtpPort"]?.intValue
                    ?? request.arguments["smtp_port"]?.intValue
                return .success(try mail.configure(
                    preset: request.arguments["preset"]?.stringValue,
                    email: request.arguments["email"]?.stringValue,
                    displayName: request.arguments["displayName"]?.stringValue
                        ?? request.arguments["display_name"]?.stringValue,
                    password: request.arguments["password"]?.stringValue
                        ?? request.arguments["appPassword"]?.stringValue
                        ?? request.arguments["app_password"]?.stringValue,
                    imapHost: request.arguments["imapHost"]?.stringValue
                        ?? request.arguments["imap_host"]?.stringValue,
                    imapPort: imapPort,
                    smtpHost: request.arguments["smtpHost"]?.stringValue
                        ?? request.arguments["smtp_host"]?.stringValue,
                    smtpPort: smtpPort
                ), requestID: requestID)
            case .runtimeMailConnect:
                return .success(try await mail.connect(), requestID: requestID)
            case .runtimeMailDisconnect:
                return .success(try mail.disconnect(), requestID: requestID)
            case .runtimeMailClearSecrets:
                return .success(try mail.clearSecrets(), requestID: requestID)
            case .speechSynthesize:
                return await Self.synthesizeSpeech(request: request, store: store)

        default:
            return .failure(.notFound("Unhandled channel operation \(request.operation.rawValue)"), requestID: requestID)
        }
    }
}
