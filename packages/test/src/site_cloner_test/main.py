"""CLI entry point for the test command."""

import asyncio
import json
import os
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse

import click

from .agent import execute_screenplay
from .report import (
    copy_source_materials,
    create_report_folder,
    generate_execution_log,
    generate_summary,
    parse_agent_output,
    write_reports,
)


def extract_hostname(url: str) -> str:
    """Extract hostname from URL, handling URLs with or without scheme."""
    if not url:
        raise click.ClickException("URL cannot be empty")

    if "://" not in url:
        url = "https://" + url

    parsed = urlparse(url)
    hostname = parsed.netloc or parsed.path.split("/")[0]

    if not hostname:
        raise click.ClickException(f"Could not extract hostname from URL: {url}")

    return hostname


def find_recording(hostname: str, search_dir: Path) -> Path:
    """Find the most recent recording folder matching the hostname."""
    pattern = f"{hostname}_*"
    matching_dirs = [
        d for d in search_dir.glob(pattern) if d.is_dir() and (d / "video.mp4").exists()
    ]

    if not matching_dirs:
        raise click.ClickException(
            f"No recording found for {hostname} in {search_dir}"
        )

    return max(matching_dirs, key=lambda d: d.stat().st_mtime)


def find_screenplay(hostname: str, search_dir: Path) -> Path:
    """Find screenplay file matching the hostname."""
    hostname_pattern = f"{hostname}_*.json"
    hostname_matches = list(search_dir.glob(hostname_pattern))

    if hostname_matches:
        return max(hostname_matches, key=lambda f: f.stat().st_mtime)

    screenplay_matches = list(search_dir.glob("screenplay*.json"))
    for sp in sorted(screenplay_matches, key=lambda f: f.stat().st_mtime, reverse=True):
        try:
            with open(sp) as f:
                data = json.load(f)
            source_url = data.get("metadata", {}).get("source_url", "")
            if hostname in source_url:
                return sp
        except (json.JSONDecodeError, KeyError):
            continue

    raise click.ClickException(
        f"No screenplay found for {hostname} in {search_dir}"
    )


def validate_recording_folder(folder: Path) -> None:
    """Validate that the recording folder contains required files."""
    if not folder.exists():
        raise click.ClickException(f"Recording folder not found: {folder}")

    if not folder.is_dir():
        raise click.ClickException(f"Not a directory: {folder}")

    video_path = folder / "video.mp4"
    if not video_path.exists():
        raise click.ClickException(f"Missing video.mp4 in {folder}")

    markers_path = folder / "markers.json"
    if not markers_path.exists():
        raise click.ClickException(f"Missing markers.json in {folder}")

    screenshots_dir = folder / "screenshots"
    if not screenshots_dir.exists() or not screenshots_dir.is_dir():
        raise click.ClickException(f"Missing screenshots/ directory in {folder}")


def validate_screenplay(screenplay_path: Path) -> dict:
    """Validate and load the screenplay JSON file."""
    if not screenplay_path.exists():
        raise click.ClickException(f"Screenplay file not found: {screenplay_path}")

    try:
        with open(screenplay_path) as f:
            data = json.load(f)
    except json.JSONDecodeError as e:
        raise click.ClickException(f"Invalid screenplay JSON: {e}")

    if "version" not in data or "metadata" not in data or "steps" not in data:
        raise click.ClickException(
            "Invalid screenplay format: missing required fields (version, metadata, steps)"
        )

    return data


def check_agent_browser() -> None:
    """Check that agent-browser is available in PATH."""
    if shutil.which("agent-browser") is None:
        raise click.ClickException(
            "agent-browser not found in PATH. Install with: npm install -g agent-browser"
        )


async def run_test(
    screenplay_path: Path,
    recording_path: Path,
    output_dir: Path,
    target_url: str,
) -> Path:
    """Run the test and return the report folder path."""
    screenplay_data = validate_screenplay(screenplay_path)
    validate_recording_folder(recording_path)

    source_url = screenplay_data.get("metadata", {}).get("source_url", "unknown")
    report_path = create_report_folder(source_url, output_dir)

    asserts_dir = report_path / "asserts"
    asserts_dir.mkdir(parents=True, exist_ok=True)

    copy_source_materials(report_path, screenplay_path, recording_path)

    screenplay_json = json.dumps(screenplay_data, indent=2)
    steps = screenplay_data.get("steps", [])
    total_steps = len(steps)

    click.echo("Starting test execution...", err=True)
    click.echo(
        f"Screenplay: {screenplay_data.get('metadata', {}).get('title', 'Untitled')} ({total_steps} steps)",
        err=True,
    )
    click.echo(f"Source: {recording_path.name}", err=True)
    click.echo("", err=True)

    started_at = datetime.now(timezone.utc)

    def on_message(message):
        msg_type = type(message).__name__
        click.echo(f"[{msg_type}]", err=True)
        if hasattr(message, "content"):
            for block in message.content:
                block_type = type(block).__name__
                if hasattr(block, "text") and block.text:
                    text = block.text.strip()
                    if text:
                        click.echo(f"  TEXT: {text[:200]}", err=True)
                elif hasattr(block, "name"):
                    # Tool use block
                    tool_input = getattr(block, "input", {})
                    click.echo(f"  TOOL_USE: {block.name}", err=True)
                    if isinstance(tool_input, dict) and "cmd" in tool_input:
                        click.echo(f"    cmd: {tool_input['cmd'][:200]}", err=True)
                elif hasattr(block, "content"):
                    # Tool result block
                    content = str(block.content)[:200] if block.content else ""
                    click.echo(f"  TOOL_RESULT: {content}", err=True)
                else:
                    click.echo(f"  {block_type}: {str(block)[:100]}", err=True)

    try:
        output = await execute_screenplay(
            screenplay_json,
            report_path,
            recording_path,
            target_url,
            on_message=on_message,
        )
    except Exception as e:
        output = f"""===EXECUTION_RESULT===
STATUS: FAILURE
STEPS_COMPLETED: 0
STEPS_SKIPPED: 0
STEPS_FAILED: 1
FAILURE_REASON: Agent execution error: {e}
===STEP_RESULTS===
===END_RESULT===
"""

    completed_at = datetime.now(timezone.utc)

    parsed_result = parse_agent_output(output)

    execution_log = generate_execution_log(
        parsed_result, started_at, completed_at, screenplay_data
    )

    summary = generate_summary(
        parsed_result,
        screenplay_data,
        recording_path.name,
        started_at,
        completed_at,
    )

    write_reports(report_path, execution_log, summary)

    return report_path


def print_summary(report_path: Path) -> None:
    """Print the test summary to stdout."""
    summary_path = report_path / "summary.json"
    if not summary_path.exists():
        return

    with open(summary_path) as f:
        summary = json.load(f)

    status = summary.get("status", "unknown").upper()
    passed = status == "SUCCESS"

    click.echo("")
    click.echo("═" * 65)
    if passed:
        click.echo("TEST PASSED", err=False)
    else:
        click.echo("TEST FAILED", err=False)
    click.echo("═" * 65)

    if not passed and summary.get("failure_reason"):
        failed_step = summary.get("failed_at_step", {})
        if failed_step:
            click.echo(
                f"Failed at step {failed_step.get('index', '?') + 1}: {failed_step.get('description', '')}",
                err=False,
            )
        click.echo(f"\nReason: {summary.get('failure_reason')}", err=False)

    completed = summary.get("steps_completed", 0)
    total = summary.get("steps_total", 0)
    skipped = summary.get("steps_skipped", 0)

    click.echo(f"\nSteps: {completed}/{total} completed, {skipped} skipped", err=False)
    click.echo(f"Duration: {summary.get('duration_seconds', 0)}s", err=False)
    click.echo(f"Report: {report_path}/", err=False)
    click.echo("═" * 65)


@click.command()
@click.argument("recording", type=click.Path(exists=True, path_type=Path))
@click.argument("url")
@click.option(
    "--screenplay",
    "-s",
    type=click.Path(exists=True, path_type=Path),
    default=None,
    help="Path to screenplay JSON file. If not provided, auto-discovers from output directory.",
)
@click.option(
    "--output-dir",
    "-o",
    type=click.Path(path_type=Path),
    default=Path("."),
    help="Base directory for reports and screenplay discovery. Default: current directory",
)
def cli(
    recording: Path,
    url: str,
    screenplay: Path | None,
    output_dir: Path,
) -> None:
    """Execute a screenplay and generate a test report.

    RECORDING is the path to the recording folder (containing video.mp4, markers.json, screenshots/).

    URL is the target URL to open in the browser for testing (e.g., https://airbnb.com).

    The screenplay is auto-discovered from the output directory based on the URL hostname,
    unless explicitly provided via --screenplay.

    A timestamped report folder is created containing:
    - Copy of the screenplay
    - Copy of the source recording
    - Assertion screenshots from this run
    - execution-log.json with step-by-step results
    - summary.json with pass/fail status
    """
    check_agent_browser()

    output_dir = output_dir.resolve()
    recording_path = recording.resolve()
    hostname = extract_hostname(url)

    if screenplay:
        screenplay_path = screenplay.resolve()
    else:
        screenplay_path = find_screenplay(hostname, output_dir)

    click.echo(f"Found screenplay: {screenplay_path.name}", err=True)
    click.echo(f"Recording: {recording_path.name}", err=True)
    click.echo(f"Target URL: {url}", err=True)

    try:
        report_path = asyncio.run(
            run_test(screenplay_path, recording_path, output_dir, url)
        )
        print_summary(report_path)

        summary_path = report_path / "summary.json"
        if summary_path.exists():
            with open(summary_path) as f:
                summary = json.load(f)
            if summary.get("status") != "success":
                sys.exit(1)

    except click.ClickException:
        raise
    except Exception as e:
        raise click.ClickException(f"Test execution failed: {e}")


if __name__ == "__main__":
    cli()
