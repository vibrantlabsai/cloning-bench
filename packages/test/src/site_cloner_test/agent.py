"""Claude Agent SDK integration for test execution."""

import os
import tempfile
from pathlib import Path
from typing import Callable

from claude_agent_sdk import ClaudeAgentOptions, query

from .prompts import build_system_prompt, load_skill_content


async def execute_screenplay(
    screenplay_json: str,
    report_dir: Path,
    recording_path: Path,
    target_url: str,
    on_message: Callable | None = None,
) -> str:
    """Execute a screenplay using the Claude Agent SDK.

    Args:
        screenplay_json: The screenplay JSON string
        report_dir: Directory for the test report (contains asserts/ folder)
        recording_path: Path to the source recording folder
        target_url: The URL to open in the browser for testing
        on_message: Optional callback for streaming messages

    Returns:
        The complete agent output as a string
    """
    chromium_path = os.environ.get("CHROMIUM_PATH")
    system_prompt = build_system_prompt(screenplay_json, chromium_path)
    skill_content = load_skill_content()

    full_prompt = f"""Execute the screenplay defined in the system prompt.

The report directory for this test run is: {report_dir}
The recording directory with reference screenshots is: {recording_path}
The target URL to test is: {target_url}

For assertion steps with screenshots (e.g., "screenshot": "screenshots/3/screenshot.png"):
1. Create the asserts folder if needed: `mkdir -p asserts/3`
2. Take screenshot: `agent-browser screenshot asserts/3/subject.png`
3. Compute diff: `site-test-diff {recording_path}/screenshots/3/screenshot.png asserts/3/subject.png asserts/3/diff.png`
4. View the diff to judge: Look at asserts/3/diff.png (red areas = differences)
5. Judge pass/fail based on the assertion description and visual differences

Remember to:
1. Open the browser with `agent-browser open {target_url}` (include --executable-path if CHROMIUM_PATH is set)
2. Use `agent-browser snapshot -i` to see available elements
3. Execute each step in order, adapting as needed
4. For assert steps, follow the visual assertion flow above
5. Close the browser when done with `agent-browser close`
6. Output the structured result format at the end

{skill_content}

Begin execution now.
"""

    # Give the test subprocess its own config directory to avoid contention
    # with any other Claude CLI instance running in the same container.
    # Without this, two instances fight over .claude.json locks and MCP ports.
    test_config_dir = tempfile.mkdtemp(prefix="claude-test-")

    env = {
        "CHROMIUM_PATH": chromium_path or "",
        "IS_SANDBOX": "1",
        "HOME": "/home/agent" if os.getuid() == 0 else os.environ.get("HOME", ""),
        "CLAUDE_CONFIG_DIR": test_config_dir,
    }

    # When running as root (e.g. inside Docker), Claude CLI refuses
    # bypassPermissions mode.  Drop to the non-root "agent" user (uid 1000)
    # that is baked into the container image.
    user = "agent" if os.getuid() == 0 else None
    if user:
        import subprocess
        # Ensure the agent user can write to the report dir, its HOME,
        # and the isolated config dir
        subprocess.run(["chown", "-R", "agent:agent", str(report_dir)], check=False)
        subprocess.run(["mkdir", "-p", "/home/agent"], check=False)
        subprocess.run(["chown", "-R", "agent:agent", "/home/agent"], check=False)
        subprocess.run(["chown", "-R", "agent:agent", test_config_dir], check=False)

    options = ClaudeAgentOptions(
        system_prompt=system_prompt,
        tools=["Bash"],
        permission_mode="bypassPermissions",
        cwd=str(report_dir),
        env=env,
        user=user,
    )

    output_parts: list[str] = []

    async for message in query(prompt=full_prompt, options=options):
        if on_message:
            on_message(message)

        if hasattr(message, "content"):
            for block in message.content:
                if hasattr(block, "text"):
                    output_parts.append(block.text)

    return "\n".join(output_parts)


def format_step_progress(
    index: int,
    total: int,
    step_type: str,
    description: str,
    status: str,
    screenshot: str | None = None,
) -> str:
    """Format a step progress line for CLI output."""
    status_symbols = {
        "completed": "✓",
        "skipped": "⊘",
        "failed": "✗",
    }
    symbol = status_symbols.get(status, "?")

    line = f"[{index + 1}/{total}] {step_type}: {description}\n"
    line += f"       {symbol} {status.capitalize()}"

    if screenshot:
        line += f": {screenshot}"

    return line
