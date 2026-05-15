#!/usr/local/lib/hermes-agent/venv/bin/python3
"""Hermes Tools MCP Bridge — exposes web_search, vision_analyze, image_generate,
and hermes_task as MCP tools to Codex (or any MCP client).

Install path: /root/hermes-tools-mcp.py  (chmod +x)
Registered in: ~/.codex/config.toml as [mcp_servers.hermes-tools]
"""
import subprocess, sys, os
import urllib.request, urllib.parse, html

sys.path.insert(0, "/usr/local/lib/hermes-agent")
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("hermes-tools")
HERMES = "/usr/local/bin/hermes"


def _hermes(prompt: str, timeout: int = 90) -> str:
    """Run a hermes --yolo oneshot task and return stdout."""
    try:
        r = subprocess.run(
            [HERMES, "--yolo", "--accept-hooks", "-z", prompt],
            capture_output=True, text=True, timeout=timeout,
            env={**os.environ},
        )
        return (r.stdout or r.stderr or "(no output)").strip()
    except subprocess.TimeoutExpired:
        return "ERROR: timed out"
    except Exception as e:
        return f"ERROR: {e}"


def _ddg_search(query: str, max_results: int = 5) -> str:
    """DuckDuckGo HTML search — no API key, ~2s response."""
    try:
        q = urllib.parse.quote_plus(query)
        url = f"https://html.duckduckgo.com/html/?q={q}"
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            body = resp.read().decode("utf-8", errors="replace")
        import re
        snippets = re.findall(r'class="result__snippet"[^>]*>(.*?)</a>', body, re.DOTALL)
        titles   = re.findall(r'class="result__a"[^>]*>(.*?)</a>', body, re.DOTALL)
        results = []
        for t, s in zip(titles[:max_results], snippets[:max_results]):
            t = html.unescape(re.sub(r"<[^>]+>", "", t)).strip()
            s = html.unescape(re.sub(r"<[^>]+>", "", s)).strip()
            results.append(f"- {t}: {s}")
        return "\n".join(results) if results else "No results found."
    except Exception as e:
        return f"ERROR: {e}"


@mcp.tool()
def web_search(query: str) -> str:
    """Search the web using DuckDuckGo and return top results."""
    return _ddg_search(query)


@mcp.tool()
def vision_analyze(image_path_or_url: str, question: str = "Describe this image in detail") -> str:
    """Analyze an image (local path or URL) using Hermes vision."""
    return _hermes(f"{question} Image: {image_path_or_url}", timeout=60)


@mcp.tool()
def image_generate(prompt: str, save_path: str = "/tmp/generated.png") -> str:
    """Generate an image from a text prompt and save it to disk."""
    return _hermes(
        f"Generate an image of: {prompt}. Save it to {save_path}. Report the exact file path.",
        timeout=120,
    )


@mcp.tool()
def hermes_task(prompt: str) -> str:
    """Run any Hermes task with full tool access: browser automation, research, file ops, vision, TTS, image gen."""
    return _hermes(prompt, timeout=110)


if __name__ == "__main__":
    mcp.run(transport="stdio")
