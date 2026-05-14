import Foundation
import Testing

struct N8nSamanthaInstallerTests {
    @Test
    func installerScriptParsesAsBash() throws {
        let script = try installerScriptPath()
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
    func installerEncodesLiveSamanthaN8nFix() throws {
        let script = try String(contentsOf: installerScriptPath(), encoding: .utf8)

        #expect(script.contains("pnpm add -g"))
        #expect(script.contains("n8n@"))
        #expect(script.contains("--ignore-scripts"))
        #expect(script.contains("npm rebuild sqlite3"))
        #expect(script.contains("NODE_PATH=\"/usr/local/bin/global/5/node_modules:/usr/local/bin/global/5/.pnpm/node_modules"))
        #expect(script.contains("/healthz"))
        #expect(script.contains("start-n8n.sh"))
    }

    private func installerScriptPath() throws -> URL {
        let current = URL(fileURLWithPath: #filePath)
        let repoRoot = current
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = repoRoot.appendingPathComponent("scripts/install-n8n-samantha.sh")
        #expect(FileManager.default.fileExists(atPath: script.path))
        return script
    }
}
