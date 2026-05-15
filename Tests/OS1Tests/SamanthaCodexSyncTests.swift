import Foundation
import Testing

struct SamanthaCodexSyncTests {
    @Test
    func syncScriptParsesAsBash() throws {
        let script = try syncScriptPath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["bash", "-n", script.path]

        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let errorText = String(
            data: (try? stderr.fileHandleForReading.readToEnd()) ?? Data(),
            encoding: .utf8
        ) ?? ""

        #expect(process.terminationStatus == 0, "bash -n failed: \(errorText)")
    }

    @Test
    func syncScriptDocumentsSecretSafeScheduledCodexSync() throws {
        let script = try String(contentsOf: syncScriptPath(), encoding: .utf8)

        #expect(script.contains("SAMANTHA_ORGO_COMPUTER_ID"))
        #expect(script.contains("security find-generic-password"))
        #expect(script.contains("auth.json config.toml version.json plugins skills"))
        #expect(script.contains("does not print tokens"))
        #expect(script.contains("removed_mac_project_sections"))
        #expect(script.contains("removed_mac_source_or_notify_lines"))
        #expect(script.contains("config_has_mac_paths"))
        #expect(script.contains("SAMANTHA_CODEX_SYNC_SMOKE"))
        #expect(script.contains("CODEX_SYNC_OK"))
    }

    private func syncScriptPath() throws -> URL {
        let current = URL(fileURLWithPath: #filePath)
        let repoRoot = current
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = repoRoot.appendingPathComponent("scripts/sync-codex-to-samantha.sh")
        #expect(FileManager.default.fileExists(atPath: script.path))
        return script
    }
}
