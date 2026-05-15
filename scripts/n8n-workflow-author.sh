#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  n8n-workflow-author.sh --prompt "workflow goal" [options]

Options:
  --name NAME             Workflow name. Default: Samantha Complex Workflow
  --prompt PROMPT         Goal for the workflow to perform.
  --output PATH           Workflow JSON path. Default: /root/.hermes/n8n-workflows/<slug>.json
  --agent                 Ask Samantha/Codex to author the workflow JSON, then validate it.
  --dry-run               Generate and validate only. This is the default when --import is omitted.
  --import                Import into n8n after validation.
  --activate              Import and request activation.
  -h, --help              Show this help.

Environment:
  N8N_URL=http://127.0.0.1:5678
  N8N_API_KEY=...                         Optional. Uses n8n REST API when set.
  SAMANTHA_AGENT_BRIDGE=/root/.hermes/bin/n8n-agent-control.sh
  SAMANTHA_WORKFLOW_DIR=/root/.hermes/n8n-workflows
USAGE
}

NAME="Samantha Complex Workflow"
PROMPT=""
OUTPUT=""
USE_AGENT=false
IMPORT_WORKFLOW=false
ACTIVATE_WORKFLOW=false
N8N_URL="${N8N_URL:-http://127.0.0.1:5678}"
WORKFLOW_DIR="${SAMANTHA_WORKFLOW_DIR:-/root/.hermes/n8n-workflows}"
AGENT_BRIDGE="${SAMANTHA_AGENT_BRIDGE:-/root/.hermes/bin/n8n-agent-control.sh}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      [[ $# -ge 2 ]] || { echo "--name requires a value" >&2; exit 64; }
      NAME="$2"
      shift 2
      ;;
    --prompt)
      [[ $# -ge 2 ]] || { echo "--prompt requires a value" >&2; exit 64; }
      PROMPT="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || { echo "--output requires a value" >&2; exit 64; }
      OUTPUT="$2"
      shift 2
      ;;
    --agent)
      USE_AGENT=true
      shift
      ;;
    --dry-run)
      IMPORT_WORKFLOW=false
      ACTIVATE_WORKFLOW=false
      shift
      ;;
    --import)
      IMPORT_WORKFLOW=true
      shift
      ;;
    --activate)
      IMPORT_WORKFLOW=true
      ACTIVATE_WORKFLOW=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

if [[ -z "${PROMPT//[[:space:]]/}" ]]; then
  echo "n8n workflow authoring requires a non-empty --prompt." >&2
  exit 64
fi

slugify() {
  python3 - "$1" <<'PY'
import re
import sys

slug = re.sub(r"[^a-z0-9]+", "-", sys.argv[1].lower()).strip("-")
print(slug or "samantha-workflow")
PY
}

if [[ -z "$OUTPUT" ]]; then
  mkdir -p "$WORKFLOW_DIR"
  OUTPUT="$WORKFLOW_DIR/$(slugify "$NAME").json"
else
  mkdir -p "$(dirname "$OUTPUT")"
fi

generate_template_workflow() {
  node - "$NAME" "$PROMPT" "$AGENT_BRIDGE" "$OUTPUT" <<'NODE'
const fs = require("fs");
const [name, prompt, bridge, output] = process.argv.slice(2);

const command = JSON.stringify(bridge) + " --prompt " + JSON.stringify(prompt);
const retryPrompt = "Retry with more diagnostics. Original task: " + prompt;
const retryCommand = JSON.stringify(bridge) + " --prompt " + JSON.stringify(retryPrompt);

const workflow = {
  name,
  active: false,
  nodes: [
    {
      parameters: {},
      id: "manual-trigger",
      name: "Manual Trigger",
      type: "n8n-nodes-base.manualTrigger",
      typeVersion: 1,
      position: [-900, -140]
    },
    {
      parameters: { rule: { interval: [{ field: "hours", hoursInterval: 24 }] } },
      id: "schedule-trigger",
      name: "Schedule Trigger",
      type: "n8n-nodes-base.scheduleTrigger",
      typeVersion: 1.2,
      position: [-900, 40]
    },
    {
      parameters: {
        httpMethod: "POST",
        path: "samantha-complex-workflow",
        responseMode: "responseNode",
        options: {}
      },
      id: "webhook-trigger",
      name: "Webhook Trigger",
      type: "n8n-nodes-base.webhook",
      typeVersion: 2,
      position: [-900, 220]
    },
    {
      parameters: {
        assignments: {
          assignments: [
            { id: "task", name: "task", value: prompt, type: "string" },
            { id: "source", name: "source", value: "={{$json.body || $json}}", type: "object" }
          ]
        },
        options: {}
      },
      id: "prepare-task",
      name: "Prepare Task",
      type: "n8n-nodes-base.set",
      typeVersion: 3.4,
      position: [-620, 40]
    },
    {
      parameters: { command },
      id: "run-samantha",
      name: "Run Samantha Agent",
      type: "n8n-nodes-base.executeCommand",
      typeVersion: 1,
      position: [-340, 40]
    },
    {
      parameters: {
        jsCode: [
          "const stdout = $json.stdout || '';",
          "const stderr = $json.stderr || '';",
          "const exitCode = Number($json.exitCode ?? $json.exit_code ?? 0);",
          "return [{ json: { ok: exitCode === 0, exitCode, stdout, stderr, shouldRetry: exitCode !== 0 } }];"
        ].join("\n")
      },
      id: "parse-result",
      name: "Parse Agent Result",
      type: "n8n-nodes-base.code",
      typeVersion: 2,
      position: [-80, 40]
    },
    {
      parameters: {
        conditions: {
          options: { caseSensitive: true, leftValue: "", typeValidation: "strict" },
          conditions: [
            {
              id: "needs-retry",
              leftValue: "={{$json.shouldRetry}}",
              rightValue: true,
              operator: { type: "boolean", operation: "equals" }
            }
          ],
          combinator: "and"
        },
        options: {}
      },
      id: "retry-check",
      name: "Needs Retry?",
      type: "n8n-nodes-base.if",
      typeVersion: 2.2,
      position: [180, 40]
    },
    {
      parameters: { amount: 2, unit: "minutes" },
      id: "wait-before-retry",
      name: "Wait Before Retry",
      type: "n8n-nodes-base.wait",
      typeVersion: 1.1,
      position: [460, -80]
    },
    {
      parameters: { command: retryCommand },
      id: "retry-samantha",
      name: "Retry Samantha Agent",
      type: "n8n-nodes-base.executeCommand",
      typeVersion: 1,
      position: [720, -80]
    },
    {
      parameters: {
        respondWith: "json",
        responseBody: "={{ { ok: true, stdout: $json.stdout, stderr: $json.stderr, exitCode: $json.exitCode } }}",
        options: {}
      },
      id: "success-response",
      name: "Success Response",
      type: "n8n-nodes-base.respondToWebhook",
      typeVersion: 1.1,
      position: [460, 160]
    },
    {
      parameters: {
        respondWith: "json",
        responseBody: "={{ { ok: false, retried: true, stdout: $json.stdout, stderr: $json.stderr, exitCode: $json.exitCode } }}",
        options: { responseCode: 500 }
      },
      id: "retry-response",
      name: "Retry Response",
      type: "n8n-nodes-base.respondToWebhook",
      typeVersion: 1.1,
      position: [980, -80]
    }
  ],
  connections: {
    "Manual Trigger": { main: [[{ node: "Prepare Task", type: "main", index: 0 }]] },
    "Schedule Trigger": { main: [[{ node: "Prepare Task", type: "main", index: 0 }]] },
    "Webhook Trigger": { main: [[{ node: "Prepare Task", type: "main", index: 0 }]] },
    "Prepare Task": { main: [[{ node: "Run Samantha Agent", type: "main", index: 0 }]] },
    "Run Samantha Agent": { main: [[{ node: "Parse Agent Result", type: "main", index: 0 }]] },
    "Parse Agent Result": { main: [[{ node: "Needs Retry?", type: "main", index: 0 }]] },
    "Needs Retry?": {
      main: [
        [{ node: "Wait Before Retry", type: "main", index: 0 }],
        [{ node: "Success Response", type: "main", index: 0 }]
      ]
    },
    "Wait Before Retry": { main: [[{ node: "Retry Samantha Agent", type: "main", index: 0 }]] },
    "Retry Samantha Agent": { main: [[{ node: "Retry Response", type: "main", index: 0 }]] }
  },
  settings: { executionOrder: "v1" }
};

fs.writeFileSync(output, JSON.stringify(workflow, null, 2) + "\n");
NODE
}

extract_json_object() {
  node - "$1" "$2" <<'NODE'
const fs = require("fs");
const [input, output] = process.argv.slice(2);
const text = fs.readFileSync(input, "utf8");
const start = text.indexOf("{");
const end = text.lastIndexOf("}");
if (start < 0 || end <= start) {
  console.error("agent output did not contain a JSON object");
  process.exit(65);
}
const parsed = JSON.parse(text.slice(start, end + 1));
fs.writeFileSync(output, JSON.stringify(parsed, null, 2) + "\n");
NODE
}

generate_agent_workflow() {
  if [[ ! -x "$AGENT_BRIDGE" ]]; then
    echo "agent workflow authoring requires executable bridge: $AGENT_BRIDGE" >&2
    exit 66
  fi

  local run_meta agent_stdout
  run_meta="$(mktemp)"
  "$AGENT_BRIDGE" --prompt "Create a production n8n workflow JSON object named '$NAME'. It must solve this task: $PROMPT. Include multiple triggers, branching, retry behavior, a command node that calls $AGENT_BRIDGE, and valid n8n connections. Return only JSON." >"$run_meta"
  agent_stdout="$(node - "$run_meta" <<'NODE'
const fs = require("fs");
const meta = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (!meta.ok) {
  console.error("Samantha agent workflow authoring failed");
  process.exit(70);
}
if (!meta.stdout_file) {
  console.error("Samantha agent metadata did not include stdout_file");
  process.exit(70);
}
console.log(meta.stdout_file);
NODE
)"
  extract_json_object "$agent_stdout" "$OUTPUT"
}

validate_workflow() {
  node - "$OUTPUT" <<'NODE'
const fs = require("fs");
const path = process.argv[2];
const workflow = JSON.parse(fs.readFileSync(path, "utf8"));
const errors = [];

if (!workflow || typeof workflow !== "object") errors.push("workflow must be an object");
if (!workflow.name || typeof workflow.name !== "string") errors.push("workflow.name must be a string");
if (!Array.isArray(workflow.nodes)) errors.push("workflow.nodes must be an array");
if (!workflow.connections || typeof workflow.connections !== "object") errors.push("workflow.connections must be an object");

const nodes = Array.isArray(workflow.nodes) ? workflow.nodes : [];
if (nodes.length < 8) errors.push("workflow must contain at least 8 nodes for a complex Samantha workflow");

const names = new Set();
let triggerCount = 0;
let commandCount = 0;
let hasBranch = false;
let hasRetry = false;
let hasWebhookResponse = false;

for (const node of nodes) {
  if (!node.name || typeof node.name !== "string") errors.push("each node must have a string name");
  if (!node.type || typeof node.type !== "string") errors.push("each node must have a string type");
  if (!Array.isArray(node.position) || node.position.length !== 2) errors.push("each node must have a two-value position");
  if (node.name) names.add(node.name);
  if ((node.type || "").includes("Trigger") || node.type === "n8n-nodes-base.webhook") triggerCount += 1;
  if (node.type === "n8n-nodes-base.executeCommand") {
    commandCount += 1;
    const command = String((node.parameters || {}).command || "");
    if (!command.includes("n8n-agent-control.sh")) errors.push("executeCommand nodes must call n8n-agent-control.sh");
  }
  if (node.type === "n8n-nodes-base.if") hasBranch = true;
  if (node.type === "n8n-nodes-base.wait" || /retry/i.test(node.name || "")) hasRetry = true;
  if (node.type === "n8n-nodes-base.respondToWebhook") hasWebhookResponse = true;
}

if (triggerCount < 2) errors.push("workflow must include at least two trigger paths");
if (commandCount < 1) errors.push("workflow must include an Execute Command node");
if (!hasBranch) errors.push("workflow must include branching");
if (!hasRetry) errors.push("workflow must include retry behavior");
if (!hasWebhookResponse) errors.push("workflow must include webhook response handling");

for (const [source, lanes] of Object.entries(workflow.connections || {})) {
  if (!names.has(source)) errors.push("connection source is missing from nodes: " + source);
  for (const lane of lanes.main || []) {
    for (const edge of lane || []) {
      if (!names.has(edge.node)) errors.push("connection target is missing from nodes: " + edge.node);
    }
  }
}

if (errors.length) {
  console.error(errors.join("\n"));
  process.exit(65);
}

console.log(JSON.stringify({
  ok: true,
  name: workflow.name,
  nodes: nodes.length,
  triggers: triggerCount,
  executeCommandNodes: commandCount
}));
NODE
}

api_import_workflow() {
  local import_payload response_file status
  import_payload="$(mktemp)"
  response_file="$(mktemp)"

  if [[ "$ACTIVATE_WORKFLOW" == true ]]; then
    node - "$OUTPUT" "$import_payload" <<'NODE'
const fs = require("fs");
const [input, output] = process.argv.slice(2);
const workflow = JSON.parse(fs.readFileSync(input, "utf8"));
workflow.active = true;
fs.writeFileSync(output, JSON.stringify(workflow, null, 2) + "\n");
NODE
  else
    cp "$OUTPUT" "$import_payload"
  fi

  status="$(curl -sS -o "$response_file" -w '%{http_code}' \
    -X POST "${N8N_URL}/api/v1/workflows" \
    -H "Content-Type: application/json" \
    -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
    --data-binary "@${import_payload}")"

  if [[ "$status" != 2* ]]; then
    cat "$response_file" >&2
    echo "n8n workflow import failed with HTTP $status" >&2
    exit 69
  fi

  if [[ "$ACTIVATE_WORKFLOW" == true ]]; then
    local workflow_id activate_status activate_response
    workflow_id="$(node - "$response_file" <<'NODE'
const fs = require("fs");
const response = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
console.log(response.id || response.data?.id || "");
NODE
)"
    if [[ -n "$workflow_id" ]]; then
      activate_response="$(mktemp)"
      activate_status="$(curl -sS -o "$activate_response" -w '%{http_code}' \
        -X PATCH "${N8N_URL}/api/v1/workflows/${workflow_id}" \
        -H "Content-Type: application/json" \
        -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
        --data-binary '{"active":true}')"
      if [[ "$activate_status" != 2* ]]; then
        cat "$activate_response" >&2
        echo "n8n workflow activation failed with HTTP $activate_status" >&2
        exit 69
      fi
    fi
  fi

  cat "$response_file"
}

cli_import_workflow() {
  local import_payload
  import_payload="$(mktemp)"
  if [[ "$ACTIVATE_WORKFLOW" == true ]]; then
    node - "$OUTPUT" "$import_payload" <<'NODE'
const fs = require("fs");
const [input, output] = process.argv.slice(2);
const workflow = JSON.parse(fs.readFileSync(input, "utf8"));
workflow.active = true;
fs.writeFileSync(output, JSON.stringify(workflow, null, 2) + "\n");
NODE
  else
    cp "$OUTPUT" "$import_payload"
  fi

  n8n import:workflow --input "$import_payload"
  printf '{"ok":true,"via":"n8n-cli","active_requested":%s,"workflow_file":%s}\n' \
    "$ACTIVATE_WORKFLOW" \
    "$(node -e 'console.log(JSON.stringify(process.argv[1]))' "$OUTPUT")"
}

import_workflow() {
  if [[ -n "${N8N_API_KEY:-}" ]]; then
    api_import_workflow
    return
  fi

  if command -v n8n >/dev/null 2>&1; then
    cli_import_workflow
    return
  fi

  echo "Import requires N8N_API_KEY for the REST API or n8n on PATH for CLI import." >&2
  exit 69
}

if [[ "$USE_AGENT" == true ]]; then
  generate_agent_workflow
else
  generate_template_workflow
fi

validate_workflow

if [[ "$IMPORT_WORKFLOW" == true ]]; then
  import_workflow
else
  printf '{"ok":true,"dry_run":true,"workflow_file":%s}\n' \
    "$(node -e 'console.log(JSON.stringify(process.argv[1]))' "$OUTPUT")"
fi
