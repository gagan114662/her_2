import Foundation
import Testing

struct SamanthaBootstrapTests {
    @Test
    func setupScriptParsesAsBash() throws {
        let script = try setupScriptPath()
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
    func setupScriptIsMacOrchestratedZeroManualBootstrap() throws {
        let script = try String(contentsOf: setupScriptPath(), encoding: .utf8)

        #expect(script.contains("This bootstrap must run on macOS"))
        #expect(script.contains("ai.orgo.mac.api-key"))
        #expect(script.contains("codex.refresh-token"))
        #expect(script.contains("aitoearn.api-key"))
        #expect(script.contains("composio.api-key"))
        #expect(script.contains("https://www.orgo.ai/api/computers/"))
        #expect(script.contains("integrations/samantha"))
        #expect(script.contains("apt-get install"))
        #expect(script.contains("npm install -g @openai/codex"))
        #expect(script.contains("NousResearch/hermes-agent/main/scripts/install.sh"))
        #expect(script.contains("CODEX_OK"))
        #expect(script.contains("Local Keychain codex.refresh-token updated after remote rotation."))
    }

    @Test
    func setupScriptDoesNotPrintSecretValues() throws {
        let script = try String(contentsOf: setupScriptPath(), encoding: .utf8)

        #expect(script.contains("values will not be printed"))
        #expect(!script.contains("echo \"$CODEX_REFRESH_TOKEN"))
        #expect(!script.contains("echo \"$AITOEARN_API_KEY"))
        #expect(!script.contains("echo \"$COMPOSIO_API_KEY"))
    }

    private func setupScriptPath() throws -> URL {
        let current = URL(fileURLWithPath: #filePath)
        let repoRoot = current
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = repoRoot.appendingPathComponent("scripts/setup-samantha.sh")
        #expect(FileManager.default.fileExists(atPath: script.path))
        return script
    }
}
