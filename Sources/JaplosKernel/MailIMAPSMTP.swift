import Foundation
import JaplosProtocol

enum MailHeader {
    static func rejectLineBreak(_ value: String, field: String) throws {
        if value.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) {
            throw MailError.invalidArgument("\(field) contains a line break")
        }
    }

    static func requireAddress(_ value: String, field: String) throws {
        try rejectLineBreak(value, field: field)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let address: String
        if let open = trimmed.lastIndex(of: "<"), trimmed.hasSuffix(">"), open < trimmed.index(before: trimmed.endIndex) {
            let start = trimmed.index(after: open)
            let end = trimmed.index(before: trimmed.endIndex)
            address = String(trimmed[start..<end])
        } else {
            address = trimmed
        }
        let pattern = #"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#
        guard address.range(of: pattern, options: .regularExpression) != nil else {
            throw MailError.invalidArgument("\(field) is not an email address")
        }
    }
}

/// Thin IMAP client over MailTLSClient.
final class IMAPSession {
    private let client: MailTLSClient
    private var tagCounter = 0

    static func connect(host: String, port: Int, timeout: TimeInterval) throws -> IMAPSession {
        let tls = try MailTLSClient(host: host, port: port, timeout: timeout)
        let greet = try tls.readLine(timeout: timeout)
        guard greet.uppercased().hasPrefix("* OK") else {
            tls.close()
            throw MailError.protocolFailure("IMAP greeting: \(String(greet.prefix(120)))")
        }
        return IMAPSession(client: tls)
    }

    private init(client: MailTLSClient) {
        self.client = client
    }

    func close() { client.close() }

    private func nextTag() -> String {
        tagCounter += 1
        return "A\(tagCounter)"
    }

    private static func quoted(_ s: String) throws -> String {
        try MailHeader.rejectLineBreak(s, field: "IMAP")
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    func login(user: String, password: String) throws {
        let tag = nextTag()
        try client.writeLine("\(tag) LOGIN \(try Self.quoted(user)) \(try Self.quoted(password))")
        let lines = try client.readUntil { $0.hasPrefix(tag + " ") }
        guard let last = lines.last, last.uppercased().contains("\(tag) OK") else {
            throw MailError.protocolFailure("IMAP LOGIN failed: \(lines.last ?? "")")
        }
    }

    func select(mailbox: String) throws {
        let tag = nextTag()
        try client.writeLine("\(tag) SELECT \(try Self.quoted(mailbox))")
        let lines = try client.readUntil { $0.hasPrefix(tag + " ") }
        guard let last = lines.last, last.uppercased().contains("\(tag) OK") else {
            throw MailError.protocolFailure("IMAP SELECT failed: \(lines.last ?? "")")
        }
    }

    func searchUIDs(unreadOnly: Bool) throws -> [Int] {
        let tag = nextTag()
        let crit = unreadOnly ? "UNSEEN" : "ALL"
        try client.writeLine("\(tag) UID SEARCH \(crit)")
        let lines = try client.readUntil { $0.hasPrefix(tag + " ") }
        guard let last = lines.last, last.uppercased().contains("\(tag) OK") else {
            throw MailError.protocolFailure("IMAP SEARCH failed: \(lines.last ?? "")")
        }
        var uids: [Int] = []
        for line in lines where line.uppercased().hasPrefix("* SEARCH") {
            for p in line.split(separator: " ").dropFirst(2) {
                if let n = Int(p) { uids.append(n) }
            }
        }
        return uids
    }

    func fetchHeaders(uid: Int) throws -> [String: String] {
        let tag = nextTag()
        try client.writeLine("\(tag) UID FETCH \(uid) (BODY.PEEK[HEADER.FIELDS (FROM TO SUBJECT DATE MESSAGE-ID)])")
        var headerText = ""
        var literalLeft = 0
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if literalLeft > 0 {
                let chunk = try client.readExact(count: literalLeft, timeout: max(0.1, deadline.timeIntervalSinceNow))
                headerText += String(decoding: chunk, as: UTF8.self)
                literalLeft = 0
                continue
            }
            let line = try client.readLine(timeout: max(0.1, deadline.timeIntervalSinceNow))
            if line.hasPrefix(tag + " ") {
                if !line.uppercased().contains("\(tag) OK") {
                    return [:]
                }
                break
            }
            if let open = line.range(of: "{"),
               let close = line.range(of: "}", range: open.upperBound..<line.endIndex),
               let n = Int(line[open.upperBound..<close.lowerBound]), n > 0 {
                literalLeft = n
                continue
            }
        }
        return MailMIME.parseHeaders(headerText)
    }

    func fetchRFC822(uid: Int) throws -> String {
        let tag = nextTag()
        try client.writeLine("\(tag) UID FETCH \(uid) (BODY.PEEK[])")
        var body = Data()
        var literalLeft = 0
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if literalLeft > 0 {
                let chunk = try client.readExact(count: literalLeft, timeout: max(0.1, deadline.timeIntervalSinceNow))
                body.append(chunk)
                literalLeft = 0
                continue
            }
            let line = try client.readLine(timeout: max(0.1, deadline.timeIntervalSinceNow))
            if line.hasPrefix(tag + " ") {
                if line.uppercased().contains("\(tag) OK") {
                    return String(decoding: body, as: UTF8.self)
                }
                throw MailError.notFound("FETCH uid \(uid) failed: \(line)")
            }
            if let open = line.range(of: "{"),
               let close = line.range(of: "}", range: open.upperBound..<line.endIndex),
               let n = Int(line[open.upperBound..<close.lowerBound]), n > 0 {
                literalLeft = n
                continue
            }
        }
        throw MailError.protocolFailure("FETCH timeout")
    }

    func logout() {
        let tag = nextTag()
        try? client.writeLine("\(tag) LOGOUT")
        _ = try? client.readUntil(timeout: 5) {
            $0.hasPrefix(tag + " ") || $0.uppercased().contains("BYE")
        }
    }
}

/// Minimal SMTP over implicit TLS (port 465).
enum SMTPClient {
    static func send(
        host: String,
        port: Int,
        user: String,
        password: String,
        from: String,
        recipients: [String],
        data: Data,
        timeout: TimeInterval
    ) throws {
        try MailHeader.requireAddress(from, field: "from")
        for rcpt in recipients {
            let trimmed = rcpt.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            try MailHeader.requireAddress(trimmed, field: "to")
        }
        let client = try MailTLSClient(host: host, port: port, timeout: timeout)
        defer { client.close() }

        func expect(_ codes: [String], label: String) throws -> String {
            let line = try client.readLine(timeout: timeout)
            // Handle multi-line 250- …
            var last = line
            while last.count >= 4, last[last.index(last.startIndex, offsetBy: 3)] == "-" {
                last = try client.readLine(timeout: timeout)
            }
            let ok = codes.contains { last.hasPrefix($0) }
            guard ok else {
                throw MailError.protocolFailure("SMTP \(label): \(last.prefix(160))")
            }
            return last
        }

        _ = try expect(["220"], label: "greeting")
        try client.writeLine("EHLO lucas.local")
        _ = try expect(["250"], label: "EHLO")

        try client.writeLine("AUTH LOGIN")
        _ = try expect(["334"], label: "AUTH")
        try client.writeLine(Data(user.utf8).base64EncodedString())
        _ = try expect(["334"], label: "AUTH user")
        try client.writeLine(Data(password.utf8).base64EncodedString())
        _ = try expect(["235"], label: "AUTH pass")

        try client.writeLine("MAIL FROM:<\(from)>")
        _ = try expect(["250"], label: "MAIL FROM")
        for rcpt in recipients {
            let r = rcpt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !r.isEmpty else { continue }
            try client.writeLine("RCPT TO:<\(r)>")
            _ = try expect(["250", "251"], label: "RCPT")
        }
        try client.writeLine("DATA")
        _ = try expect(["354"], label: "DATA")
        // Dot-stuff lines starting with .
        var payload = data
        if let text = String(data: data, encoding: .utf8) {
            let stuffed = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                let raw = line.hasSuffix("\r") ? String(line.dropLast()) : String(line)
                if raw.hasPrefix(".") { return "." + raw }
                return raw
            }.joined(separator: "\r\n")
            payload = Data((stuffed + "\r\n.\r\n").utf8)
        } else {
            payload.append(Data("\r\n.\r\n".utf8))
        }
        try client.write(payload, timeout: timeout)
        _ = try expect(["250"], label: "DATA end")
        try client.writeLine("QUIT")
        _ = try? expect(["221"], label: "QUIT")
    }
}

enum MailMIME {
    static func parseHeaders(_ raw: String) -> [String: String] {
        var headers: [String: String] = [:]
        var currentKey: String?
        for line in raw.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            if s.isEmpty { break }
            if s.first?.isWhitespace == true, let key = currentKey {
                headers[key, default: ""] += " " + s.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let colon = s.firstIndex(of: ":") else { continue }
            let key = String(s[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(s[s.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = decodeRFC2047(value)
            currentKey = key
        }
        return headers
    }

    static func parse(_ rfc822: String) -> (from: String, to: String, subject: String, date: String, text: String) {
        let normalized = rfc822.replacingOccurrences(of: "\r\n", with: "\n")
        let parts = normalized.split(separator: "\n\n", maxSplits: 1, omittingEmptySubsequences: false)
        let headerPart = parts.first.map(String.init) ?? ""
        let bodyPart = parts.count > 1 ? String(parts[1]) : ""
        let headers = parseHeaders(headerPart)
        let text = extractText(body: bodyPart, contentType: headers["content-type"] ?? "text/plain")
        return (
            from: headers["from"] ?? "",
            to: headers["to"] ?? "",
            subject: headers["subject"] ?? "",
            date: headers["date"] ?? "",
            text: String(text.prefix(20_000))
        )
    }

    static func build(from: String, to: String, cc: String?, subject: String, body: String) -> Data {
        var lines: [String] = [
            "From: \(from)",
            "To: \(to)",
        ]
        if let cc, !cc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Cc: \(cc)")
        }
        lines.append("Subject: \(subject)")
        lines.append("MIME-Version: 1.0")
        lines.append("Content-Type: text/plain; charset=utf-8")
        lines.append("Content-Transfer-Encoding: 8bit")
        lines.append("Date: \(rfc2822Date(Date()))")
        lines.append("Message-ID: <\(UUID().uuidString)@lucas.local>")
        lines.append("")
        lines.append(body)
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    private static func extractText(body: String, contentType: String) -> String {
        let lower = contentType.lowercased()
        if lower.contains("multipart/") {
            // Best-effort: find first text/plain part.
            if let range = body.range(of: "Content-Type: text/plain", options: .caseInsensitive) {
                let rest = body[range.lowerBound...]
                if let blank = rest.range(of: "\n\n") {
                    var text = String(rest[blank.upperBound...])
                    if let next = text.range(of: "\n--") {
                        text = String(text[..<next.lowerBound])
                    }
                    return text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        if lower.contains("text/html") {
            return body
                .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeRFC2047(_ value: String) -> String {
        // Pass through; full RFC2047 is optional for v1.
        value
    }

    private static func rfc2822Date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss +0000"
        return formatter.string(from: date)
    }
}
