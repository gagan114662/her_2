import Foundation
import Testing

struct N8nWorkflowAuthorTests {
    @Test
    func workflowAuthorScriptParsesAsBash() throws {
        let script = try workflowAuthorScriptPath()
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
    func workflowAuthorEncodesComplexSamanthaWorkflowContract() throws {
        let script = try String(contentsOf: workflowAuthorScriptPath(), encoding: .utf8)

        #expect(script.contains("n8n-nodes-base.manualTrigger"))
        #expect(script.contains("n8n-nodes-base.scheduleTrigger"))
        #expect(script.contains("n8n-nodes-base.webhook"))
        #expect(script.contains("n8n-nodes-base.executeCommand"))
        #expect(script.contains("n8n-nodes-base.if"))
        #expect(script.contains("n8n-nodes-base.wait"))
        #expect(script.contains("n8n-nodes-base.respondToWebhook"))
        #expect(script.contains("n8n-agent-control.sh"))
        #expect(script.contains("--prompt <natural-language task>"))
        #expect(script.contains("with --prompt"))
        #expect(script.contains("stdout_file"))
        #expect(script.contains("workflow must contain at least 8 nodes"))
        #expect(script.contains("N8N_API_KEY"))
        #expect(script.contains("/api/v1/workflows"))
        #expect(script.contains("n8n import:workflow"))
        #expect(script.contains("JSON.stringify([workflow]"))
        #expect(script.contains("\"active\":true"))
    }

    @Test
    func dryRunCreatesValidatedWorkflowJson() throws {
        guard commandExists("node") else {
            return
        }

        let script = try workflowAuthorScriptPath()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "bash",
            script.path,
            "--dry-run",
            "--name",
            "Revenue Followup",
            "--prompt",
            "Inspect revenue events, retry failed actions, and summarize next steps.",
            "--output",
            output.path
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let errorText = String(
            data: (try? stderr.fileHandleForReading.readToEnd()) ?? Data(),
            encoding: .utf8
        ) ?? ""
        #expect(process.terminationStatus == 0, "workflow author failed: \(errorText)")

        let data = try Data(contentsOf: output)
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let nodes = try #require(json["nodes"] as? [[String: Any]])
        let connections = try #require(json["connections"] as? [String: Any])

        #expect(json["name"] as? String == "Revenue Followup")
        #expect(nodes.count >= 8)
        #expect(nodes.contains { $0["type"] as? String == "n8n-nodes-base.executeCommand" })
        #expect(nodes.contains { node in
            guard node["type"] as? String == "n8n-nodes-base.executeCommand",
                  let parameters = node["parameters"] as? [String: Any],
                  let command = parameters["command"] as? String else {
                return false
            }
            return command.contains("n8n-agent-control.sh") && command.contains("--prompt")
        })
        #expect(nodes.contains { $0["type"] as? String == "n8n-nodes-base.if" })
        #expect(nodes.contains { $0["type"] as? String == "n8n-nodes-base.wait" })
        #expect(connections["Prepare Task"] != nil)
    }

    private func workflowAuthorScriptPath() throws -> URL {
        let current = URL(fileURLWithPath: #filePath)
        let repoRoot = current
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = repoRoot.appendingPathComponent("scripts/n8n-workflow-author.sh")
        #expect(FileManager.default.fileExists(atPath: script.path))
        return script
    }

    private func commandExists(_ command: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["bash", "-lc", "command -v \(command) >/dev/null 2>&1"]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
