import Foundation

enum AccountStoreError: Error {
    case alreadyExists
    case notFound
    case keychainFailure(Int32, String)
    case decodeFailure
}

enum AccountStore {
    static let serviceNamePrefix = "ClaudeDock Account "
    static let claudeCodeService = "Claude Code-credentials"

    static func service(forLabel label: String) -> String {
        serviceNamePrefix + label
    }

    // MARK: - List

    static func listStoredLabels() -> [String] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["dump-keychain"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return [] }
        proc.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        var labels: [String] = []
        for line in out.split(separator: "\n") {
            if let range = line.range(of: "\"svce\"<blob>=\"") {
                let tail = line[range.upperBound...]
                if let endQuote = tail.range(of: "\"") {
                    let service = String(tail[..<endQuote.lowerBound])
                    if service.hasPrefix(serviceNamePrefix) {
                        labels.append(String(service.dropFirst(serviceNamePrefix.count)))
                    }
                }
            }
        }
        return labels.sorted()
    }

    // MARK: - Bundle I/O

    static func loadBundle(label: String) throws -> String {
        try readPassword(service: service(forLabel: label))
    }

    static func saveBundle(label: String, blob: String, overwrite: Bool = false) throws {
        if !overwrite {
            if (try? readPassword(service: service(forLabel: label))) != nil {
                throw AccountStoreError.alreadyExists
            }
        }
        try writePassword(
            service: service(forLabel: label),
            account: "ClaudeDock",
            blob: blob
        )
    }

    static func rename(from oldLabel: String, to newLabel: String) throws {
        let blob = try loadBundle(label: oldLabel)
        try saveBundle(label: newLabel, blob: blob, overwrite: false)
        try deleteBundle(label: oldLabel)
    }

    static func deleteBundle(label: String) throws {
        try deletePassword(service: service(forLabel: label))
    }

    // MARK: - Claude Code slot

    static func readClaudeCodeBlob() throws -> (acct: String, blob: String) {
        let acct = readAccountAttr(service: claudeCodeService) ?? NSUserName()
        let blob = try readPassword(service: claudeCodeService)
        return (acct, blob)
    }

    static func writeClaudeCodeBlob(acct: String, blob: String) throws {
        try writePassword(service: claudeCodeService, account: acct, blob: blob)
    }

    // MARK: - security CLI helpers

    private static func readPassword(service: String) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", service, "-w"]
        let pipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = errPipe
        do { try proc.run() } catch {
            throw AccountStoreError.keychainFailure(-1, "launch failed")
        }
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if err.contains("could not be found") {
                throw AccountStoreError.notFound
            }
            throw AccountStoreError.keychainFailure(proc.terminationStatus, err)
        }
        let raw = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { throw AccountStoreError.notFound }
        if raw.allSatisfy({ $0.isHexDigit }), let decoded = hexDecode(raw) {
            return decoded
        }
        return raw
    }

    private static func readAccountAttr(service: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", service]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        for line in out.split(separator: "\n") {
            if let range = line.range(of: "\"acct\"<blob>=\"") {
                let tail = line[range.upperBound...]
                if let endQuote = tail.range(of: "\"") {
                    return String(tail[..<endQuote.lowerBound])
                }
            }
        }
        return nil
    }

    // Note: `security add-generic-password -w <blob>` passes the blob via argv,
    // which is briefly visible to `ps` for the duration of the child process
    // (~milliseconds). Acceptable for this app's threat model — the blob is
    // already readable from keychain by any process running as this user.
    // Upgrading to SecItemAdd via the Security framework would close even
    // this window and is listed as a future improvement.
    private static func writePassword(service: String, account: String, blob: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = [
            "add-generic-password",
            "-s", service,
            "-a", account,
            "-U",
            "-w", blob
        ]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = FileHandle.nullDevice
        do { try proc.run() } catch {
            throw AccountStoreError.keychainFailure(-1, "launch failed")
        }
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw AccountStoreError.keychainFailure(proc.terminationStatus, err)
        }
    }

    private static func deletePassword(service: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["delete-generic-password", "-s", service]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch {
            throw AccountStoreError.keychainFailure(-1, "launch failed")
        }
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            throw AccountStoreError.notFound
        }
    }

    private static func hexDecode(_ hex: String) -> String? {
        var bytes: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let next = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let b = UInt8(hex[i..<next], radix: 16) {
                bytes.append(b)
            }
            i = next
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}
