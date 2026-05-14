import Foundation
import Testing

struct N8nAgentControlBridgeTests {
    @Test
    func bridgeScriptParsesAsBash() throws {
        let script = try bridgeScriptPath()
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
    func bridgeDefaultsToFullLocalAgentControl() throws {
        let script = try String(contentsOf: bridgeScriptPath(), encoding: .utf8)

        #expect(script.contains("SAMANTHA_AGENT_CONTROL_MODE:-full"))
        #expect(script.contains("SAMANTHA_AGENT_RUNTIME:-auto"))
        #expect(script.contains("/root/.hermes/logs/n8n-agent-control"))
        #expect(script.contains("SAMANTHA_AGENT_WORKDIR:-/root"))
        #expect(script.contains("cd \"$WORKDIR\""))
        #expect(script.contains("hermes -z"))
        #expect(script.contains("codex exec"))
        #expect(script.contains("--skip-git-repo-check"))
        #expect(script.contains("< /dev/null"))
        #expect(script.contains("SAMANTHA_AGENT_COMMAND"))
        #expect(script.contains("falling back to Codex"))
    }

    @Test
    func bridgeDocumentsPluginBackedDelegation() throws {
        let script = try String(contentsOf: bridgeScriptPath(), encoding: .utf8)

        #expect(script.contains("plugins, MCP servers, browser tools"))
        #expect(script.contains("connected accounts"))
        #expect(script.contains("auditable actions"))
        #expect(script.contains("financially"))
    }

    private func bridgeScriptPath() throws -> URL {
        let current = URL(fileURLWithPath: #filePath)
        let repoRoot = current
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = repoRoot.appendingPathComponent("scripts/n8n-agent-control.sh")
        #expect(FileManager.default.fileExists(atPath: script.path))
        return script
    }
}
