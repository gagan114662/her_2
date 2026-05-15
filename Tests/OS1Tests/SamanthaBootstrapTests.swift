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
        #expect(script.contains("[mcp_servers.aitoearn]"))
        #expect(script.contains("aitoearn-mcp-proxy.py"))
        #expect(script.contains("[mcp_servers.aitoearn.headers]"))
        #expect(script.contains("AITOEARN_API_KEY"))
        #expect(script.contains("ipop-factory.py"))
        #expect(script.contains("ipop-factory.conf"))
        #expect(script.contains("ipop-factory.py init --max-workers 4"))
    }

    @Test
    func setupScriptDoesNotPrintSecretValues() throws {
        let script = try String(contentsOf: setupScriptPath(), encoding: .utf8)

        #expect(script.contains("values will not be printed"))
        #expect(!script.contains("echo \"$CODEX_REFRESH_TOKEN"))
        #expect(!script.contains("echo \"$AITOEARN_API_KEY"))
        #expect(!script.contains("echo \"$COMPOSIO_API_KEY"))
    }

    @Test
    func aitoearnUsesLocalProxyInAllRuntimeTemplates() throws {
        let repoRoot = try repoRootURL()
        let hermesConfig = try String(
            contentsOf: repoRoot.appendingPathComponent("integrations/samantha/config.yaml.template"),
            encoding: .utf8
        )
        let claudeConfig = try String(
            contentsOf: repoRoot.appendingPathComponent("integrations/samantha/claude_desktop_config.json.template"),
            encoding: .utf8
        )
        let codexConfig = try String(
            contentsOf: repoRoot.appendingPathComponent("integrations/samantha/codex-config-additions.toml"),
            encoding: .utf8
        )

        for template in [hermesConfig, claudeConfig, codexConfig] {
            #expect(template.contains("/root/aitoearn-mcp-proxy.py"))
            #expect(!template.contains("https://aitoearn.ai/api/unified/mcp"))
        }
    }

    @Test
    func ipopFactoryRuntimeIsFileBackedAndParallel() throws {
        let repoRoot = try repoRootURL()
        let runtime = try String(
            contentsOf: repoRoot.appendingPathComponent("integrations/samantha/ipop-factory.py"),
            encoding: .utf8
        )
        let supervisor = try String(
            contentsOf: repoRoot.appendingPathComponent("integrations/samantha/ipop-factory.conf"),
            encoding: .utf8
        )

        #expect(runtime.contains("DEFAULT_STATE_PATH"))
        #expect(runtime.contains("/root/ipop-factory.json"))
        #expect(runtime.contains("ThreadPoolExecutor"))
        #expect(runtime.contains("allowed_actions"))
        #expect(runtime.contains("blocked_actions"))
        #expect(runtime.contains("Do not send messages, submit proposals, publish externally"))
        #expect(runtime.contains("run-once"))
        #expect(runtime.contains("loop"))
        #expect(supervisor.contains("[program:ipop-factory]"))
        #expect(supervisor.contains("/root/ipop-factory.py loop"))
    }

    private func setupScriptPath() throws -> URL {
        let script = try repoRootURL().appendingPathComponent("scripts/setup-samantha.sh")
        #expect(FileManager.default.fileExists(atPath: script.path))
        return script
    }

    private func repoRootURL() throws -> URL {
        let current = URL(fileURLWithPath: #filePath)
        return current
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
