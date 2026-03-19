import Foundation
import Security

enum KeychainReader {
    private static let accessTokenPattern = try! NSRegularExpression(
        pattern: #""accessToken"\s*:\s*"(sk-ant-[^"]+)""#
    )

    static func getCredentials() -> String? {
        if let token = readFromKeychain() {
            return token
        }
        return readFromFile()
    }

    private static func readFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        if let str = String(data: data, encoding: .utf8) {
            if let token = extractToken(from: str) {
                return token
            }
            if let hexDecoded = hexDecode(str.trimmingCharacters(in: .whitespacesAndNewlines)) {
                if let token = extractToken(from: hexDecoded) {
                    return token
                }
            }
        }
        return nil
    }

    private static func readFromFile() -> String? {
        let path = NSHomeDirectory() + "/.claude/.credentials.json"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let perms = attrs[.posixPermissions] as? Int else {
            return nil
        }
        if perms & 0o077 != 0 {
            return nil
        }
        guard let data = FileManager.default.contents(atPath: path),
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return extractToken(from: str)
    }

    private static func extractToken(from raw: String) -> String? {
        if let data = raw.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauth = json["claudeAiOauth"] as? [String: Any],
           let token = oauth["accessToken"] as? String,
           token.hasPrefix("sk-ant-") {
            return token
        }

        let range = NSRange(raw.startIndex..., in: raw)
        if let match = accessTokenPattern.firstMatch(in: raw, range: range) {
            if let tokenRange = Range(match.range(at: 1), in: raw) {
                return String(raw[tokenRange])
            }
        }
        return nil
    }

    private static func hexDecode(_ hex: String) -> String? {
        guard hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let byte = UInt8(hex[index..<nextIndex], radix: 16) {
                bytes.append(byte)
            }
            index = nextIndex
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}
