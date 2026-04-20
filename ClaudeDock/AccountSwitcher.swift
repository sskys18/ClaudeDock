import Foundation

enum SwitcherError: Error, LocalizedError {
    case duplicateLabel
    case notFound
    case keychainFailure(String)
    case noActiveLogin

    var errorDescription: String? {
        switch self {
        case .duplicateLabel: return "A saved login with that label already exists."
        case .notFound: return "Account not found."
        case .noActiveLogin: return "No active Claude Code login detected. Run /login first."
        case .keychainFailure(let msg): return "Keychain error: \(msg)"
        }
    }
}

struct AccountSwitcher {

    static func saveCurrentAs(label: String, config: inout AppConfig) throws {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SwitcherError.duplicateLabel }
        if config.accounts.contains(where: { $0.label == trimmed }) {
            throw SwitcherError.duplicateLabel
        }

        let current: (acct: String, blob: String)
        do {
            current = try AccountStore.readClaudeCodeBlob()
        } catch AccountStoreError.notFound {
            throw SwitcherError.noActiveLogin
        } catch {
            throw SwitcherError.keychainFailure("read active: \(error)")
        }

        do {
            try AccountStore.saveBundle(label: trimmed, blob: current.blob, overwrite: false)
        } catch AccountStoreError.alreadyExists {
            throw SwitcherError.duplicateLabel
        } catch {
            throw SwitcherError.keychainFailure("save bundle: \(error)")
        }

        let ref = AccountRef(id: idFromLabel(trimmed), label: trimmed, kind: .claude)
        config.accounts.append(ref)
        config.activeAccountId = ref.id
    }

    static func switchTo(accountId: String, config: inout AppConfig) throws {
        guard let ref = config.accounts.first(where: { $0.id == accountId }) else {
            throw SwitcherError.notFound
        }
        let blob: String
        do {
            blob = try AccountStore.loadBundle(label: ref.label)
        } catch {
            throw SwitcherError.keychainFailure("load bundle: \(error)")
        }
        let acct = (try? AccountStore.readClaudeCodeBlob().acct) ?? NSUserName()
        do {
            try AccountStore.writeClaudeCodeBlob(acct: acct, blob: blob)
        } catch {
            throw SwitcherError.keychainFailure("write active: \(error)")
        }

        mirrorFileFallbackIfPresent(blob: blob)

        config.activeAccountId = accountId
    }

    static func rename(accountId: String, to newLabel: String,
                       config: inout AppConfig) throws {
        let trimmed = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SwitcherError.duplicateLabel }
        guard let idx = config.accounts.firstIndex(where: { $0.id == accountId }) else {
            throw SwitcherError.notFound
        }
        if config.accounts.contains(where: { $0.label == trimmed && $0.id != accountId }) {
            throw SwitcherError.duplicateLabel
        }
        let old = config.accounts[idx]
        if old.label == trimmed { return }
        do {
            try AccountStore.rename(from: old.label, to: trimmed)
        } catch {
            throw SwitcherError.keychainFailure("rename: \(error)")
        }
        config.accounts[idx].label = trimmed
    }

    static func delete(accountId: String, config: inout AppConfig) throws {
        guard let idx = config.accounts.firstIndex(where: { $0.id == accountId }) else {
            throw SwitcherError.notFound
        }
        let ref = config.accounts[idx]
        try? AccountStore.deleteBundle(label: ref.label)
        config.accounts.remove(at: idx)
        if config.activeAccountId == accountId {
            config.activeAccountId = nil
        }
    }

    private static func idFromLabel(_ label: String) -> String {
        let lowered = label.lowercased().replacingOccurrences(of: " ", with: "-")
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")
        let cleaned = String(lowered.filter { allowed.contains($0) })
        return cleaned.isEmpty ? "account-\(Int.random(in: 1000...9999))" : cleaned
    }

    private static func mirrorFileFallbackIfPresent(blob: String) {
        let path = NSHomeDirectory() + "/.claude/.credentials.json"
        guard FileManager.default.fileExists(atPath: path) else { return }
        do {
            try blob.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: path
            )
        } catch {
            // Non-fatal; keychain write already succeeded.
        }
    }
}
