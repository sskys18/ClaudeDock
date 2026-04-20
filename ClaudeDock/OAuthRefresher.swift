import Foundation

enum OAuthRefreshError: Error {
    case noRefreshToken
    case endpointUnknown
    case decodeFailure
    case server(Int, String)
}

struct RefreshedBundle {
    let rawBlob: String
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
}

enum OAuthRefresher {
    // If/when Claude Code's OAuth client_id is known, drop it here
    // and the rest of the refresh path starts working. Until then
    // refresh always fails cleanly and the usage loop falls through
    // to `needsReLogin`.
    static var clientId: String = ""

    static let candidateEndpoints: [URL] = [
        URL(string: "https://console.anthropic.com/v1/oauth/token")!,
        URL(string: "https://api.anthropic.com/v1/oauth/token")!
    ]

    static func refresh(blob: String) async -> Result<RefreshedBundle, OAuthRefreshError> {
        guard let parsed = ClaudeOAuthBlob.parse(blob),
              let refresh = parsed.refreshToken,
              !refresh.isEmpty else {
            return .failure(.noRefreshToken)
        }

        let form = encodeForm([
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": clientId
        ])

        for endpoint in candidateEndpoints {
            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 10
            req.httpBody = form.data(using: .utf8)

            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse else { continue }
                if http.statusCode == 404 { continue }
                if !(200...299).contains(http.statusCode) {
                    return .failure(.server(http.statusCode,
                        String(data: data, encoding: .utf8) ?? ""))
                }
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let newAccess = obj["access_token"] as? String else {
                    return .failure(.decodeFailure)
                }
                let newRefresh = (obj["refresh_token"] as? String) ?? refresh
                var newExp: Date?
                if let expIn = obj["expires_in"] as? Double {
                    newExp = Date().addingTimeInterval(expIn)
                }
                let newBlob = rewriteBlob(
                    original: blob,
                    accessToken: newAccess,
                    refreshToken: newRefresh,
                    expiresAt: newExp
                )
                return .success(RefreshedBundle(
                    rawBlob: newBlob,
                    accessToken: newAccess,
                    refreshToken: newRefresh,
                    expiresAt: newExp
                ))
            } catch {
                continue
            }
        }
        return .failure(.endpointUnknown)
    }

    private static func encodeForm(_ fields: [String: String]) -> String {
        var comps = URLComponents()
        comps.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        return comps.percentEncodedQuery ?? ""
    }

    private static func rewriteBlob(
        original: String,
        accessToken: String,
        refreshToken: String,
        expiresAt: Date?
    ) -> String {
        guard let data = original.data(using: .utf8),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var oauth = json["claudeAiOauth"] as? [String: Any] else {
            return original
        }
        oauth["accessToken"] = accessToken
        oauth["refreshToken"] = refreshToken
        if let exp = expiresAt {
            oauth["expiresAt"] = exp.timeIntervalSince1970 * 1000
        }
        json["claudeAiOauth"] = oauth
        guard let out = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
              let str = String(data: out, encoding: .utf8) else {
            return original
        }
        return str
    }
}
