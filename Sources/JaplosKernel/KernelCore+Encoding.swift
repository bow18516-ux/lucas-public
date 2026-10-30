import Foundation
import JaplosProtocol

extension KernelCore {

    public static func encode(turn: ChatTurn) -> JSONValue {
        func dateString(_ date: Date) -> JSONValue { .string(ISO8601.string(from: date)) }
        return .object([
            "id": .string(turn.id),
            "sessionID": .string(turn.sessionID),
            "role": .string(turn.role.rawValue),
            "text": .string(turn.text),
            "createdAt": dateString(turn.createdAt),
            "toolCalls": .array(turn.toolCalls.map { call in
                .object([
                    "id": .string(call.id),
                    "name": .string(call.name),
                    "arguments": call.arguments,
                ])
            }),
            "toolCallID": turn.toolCallID.map(JSONValue.string) ?? .null,
            "toolName": turn.toolName.map(JSONValue.string) ?? .null,
        ])
    }

    public static func encode(session: ChatSession) -> JSONValue {
        .object([
            "id": .string(session.id),
            "title": .string(session.title),
            "createdAt": .string(ISO8601.string(from: session.createdAt)),
            "updatedAt": .string(ISO8601.string(from: session.updatedAt)),
        ])
    }

    public static func encode(tool: ToolDefinition) -> JSONValue {
        .object([
            "name": .string(tool.name),
            "title": .string(tool.title),
            "summary": .string(tool.summary),
            "inputSchema": tool.inputSchema,
            "capability": .string(tool.capability),
            "risk": .string(tool.risk.rawValue),
            "provider": .string(tool.provider),
        ])
    }

    public static func encode(execution: ToolExecution) -> JSONValue {
        .object([
            "call": .object([
                "id": .string(execution.call.id),
                "name": .string(execution.call.name),
                "arguments": execution.call.arguments,
            ]),
            "ok": .bool(execution.ok),
            "output": execution.output,
            "error": execution.error.map(JSONValue.string) ?? .null,
            "durationMilliseconds": .number(execution.durationMilliseconds),
        ])
    }
}
