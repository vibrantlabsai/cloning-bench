"""Report generation for test execution results."""

import json
import re
import shutil
from datetime import datetime, timezone
from pathlib import Path

from .schema import (
    AssertionComparison,
    ExecutionLog,
    FailedStep,
    SkippedStep,
    StepResult,
    Summary,
)
from .visual import extract_screenshot_index


def create_report_folder(
    source_url: str,
    output_dir: Path,
) -> Path:
    """Create and return the report folder path."""
    domain = source_url.split("://")[-1].split("/")[0]
    timestamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    folder_name = f"{domain}_{timestamp}_test"
    report_path = output_dir / folder_name
    report_path.mkdir(parents=True, exist_ok=True)
    return report_path


def copy_source_materials(
    report_path: Path,
    screenplay_path: Path,
    recording_path: Path,
) -> None:
    """Copy screenplay and recording to report folder."""
    shutil.copy(screenplay_path, report_path / "screenplay.json")

    recording_dest = report_path / "recording"
    if recording_path.is_dir():
        shutil.copytree(recording_path, recording_dest)


def parse_agent_output(output: str) -> dict:
    """Parse the structured output from the agent."""
    result = {
        "status": "failure",
        "steps_completed": 0,
        "steps_skipped": 0,
        "steps_failed": 0,
        "failure_reason": None,
        "steps": [],
    }

    result_match = re.search(
        r"===EXECUTION_RESULT===(.*?)===STEP_RESULTS===",
        output,
        re.DOTALL,
    )
    if result_match:
        result_section = result_match.group(1)

        status_match = re.search(r"STATUS:\s*(SUCCESS|FAILURE)", result_section)
        if status_match:
            result["status"] = status_match.group(1).lower()

        completed_match = re.search(r"STEPS_COMPLETED:\s*(\d+)", result_section)
        if completed_match:
            result["steps_completed"] = int(completed_match.group(1))

        skipped_match = re.search(r"STEPS_SKIPPED:\s*(\d+)", result_section)
        if skipped_match:
            result["steps_skipped"] = int(skipped_match.group(1))

        failed_match = re.search(r"STEPS_FAILED:\s*(\d+)", result_section)
        if failed_match:
            result["steps_failed"] = int(failed_match.group(1))

        failure_match = re.search(r"FAILURE_REASON:\s*(.+?)(?:\n|$)", result_section)
        if failure_match:
            reason = failure_match.group(1).strip()
            if reason.lower() != "none":
                result["failure_reason"] = reason

    steps_match = re.search(
        r"===STEP_RESULTS===(.*?)===END_RESULT===",
        output,
        re.DOTALL,
    )
    if steps_match:
        steps_section = steps_match.group(1)
        step_blocks = steps_section.split("---")

        for block in step_blocks:
            block = block.strip()
            if not block:
                continue

            step = {}

            index_match = re.search(
                r"STEP\s+(\d+):\s*(completed|skipped|failed)", block
            )
            if index_match:
                step["index"] = int(index_match.group(1))
                step["status"] = index_match.group(2)

            type_match = re.search(r"TYPE:\s*(action|assert|wait)", block)
            if type_match:
                step["type"] = type_match.group(1)

            desc_match = re.search(r"DESCRIPTION:\s*(.+?)(?:\nSCREENSHOT:|$)", block, re.DOTALL)
            if desc_match:
                step["description"] = desc_match.group(1).strip()

            screenshot_match = re.search(r"SCREENSHOT:\s*(.+?)(?:\nASSERTION:|$)", block, re.DOTALL)
            if screenshot_match:
                screenshot = screenshot_match.group(1).strip()
                step["screenshot_captured"] = None if screenshot.lower() == "none" else screenshot

            assertion_match = re.search(r"ASSERTION:\s*(PASSED|FAILED)", block)
            if assertion_match:
                step["assertion_passed"] = assertion_match.group(1) == "PASSED"

            notes_match = re.search(r"NOTES:\s*(.+?)(?:\n---|$)", block, re.DOTALL)
            if notes_match:
                notes = notes_match.group(1).strip()
                step["notes"] = None if notes.lower() == "none" else notes

            if "index" in step and "type" in step:
                result["steps"].append(step)

    return result


def generate_execution_log(
    parsed_result: dict,
    started_at: datetime,
    completed_at: datetime,
    screenplay_data: dict,
) -> ExecutionLog:
    """Generate the execution log from parsed agent output."""
    screenplay_steps = screenplay_data.get("steps", [])

    steps = []
    for step_data in parsed_result.get("steps", []):
        step_index = step_data.get("index", 0)
        step_type = step_data.get("type", "action")

        assertion = None
        if step_type == "assert" and "assertion_passed" in step_data:
            screenplay_step = next(
                (s for i, s in enumerate(screenplay_steps) if i == step_index),
                None,
            )
            if screenplay_step and "screenshot" in screenplay_step:
                try:
                    screenshot_index = extract_screenshot_index(screenplay_step["screenshot"])
                    assertion = AssertionComparison(
                        screenshot_index=screenshot_index,
                        recording_path=f"asserts/{screenshot_index}/recording.png",
                        subject_path=f"asserts/{screenshot_index}/subject.png",
                        diff_path=f"asserts/{screenshot_index}/diff.png",
                        passed=step_data.get("assertion_passed", False),
                        reasoning=step_data.get("notes"),
                    )
                except ValueError:
                    pass

        steps.append(
            StepResult(
                index=step_index,
                type=step_type,
                description=step_data.get("description", ""),
                status=step_data.get("status", "failed"),
                screenshot_captured=step_data.get("screenshot_captured"),
                notes=step_data.get("notes"),
                assertion=assertion,
            )
        )

    return ExecutionLog(
        started_at=started_at.isoformat(),
        completed_at=completed_at.isoformat(),
        steps=steps,
    )


def generate_summary(
    parsed_result: dict,
    screenplay_data: dict,
    recording_name: str,
    started_at: datetime,
    completed_at: datetime,
) -> Summary:
    """Generate the summary from parsed agent output."""
    duration = (completed_at - started_at).total_seconds()
    steps_total = len(screenplay_data.get("steps", []))

    skipped_steps = []
    failed_step = None
    last_screenshot = None

    for step in parsed_result.get("steps", []):
        if step.get("status") == "skipped":
            skipped_steps.append(
                SkippedStep(
                    index=step.get("index", 0),
                    reason=step.get("notes", "Unknown reason"),
                )
            )
        elif step.get("status") == "failed":
            failed_step = FailedStep(
                index=step.get("index", 0),
                type=step.get("type", "action"),
                description=step.get("description", ""),
            )

        if step.get("screenshot_captured"):
            last_screenshot = step["screenshot_captured"]

    return Summary(
        status=parsed_result.get("status", "failure"),
        screenplay="screenplay.json",
        source_recording=recording_name,
        started_at=started_at.isoformat(),
        completed_at=completed_at.isoformat(),
        duration_seconds=round(duration, 1),
        steps_total=steps_total,
        steps_completed=parsed_result.get("steps_completed", 0),
        steps_skipped=parsed_result.get("steps_skipped", 0),
        steps_failed=parsed_result.get("steps_failed", 0),
        skipped_steps=skipped_steps,
        failure_reason=parsed_result.get("failure_reason"),
        failed_at_step=failed_step,
        last_screenshot=last_screenshot,
    )


def write_reports(
    report_path: Path,
    execution_log: ExecutionLog,
    summary: Summary,
) -> None:
    """Write execution log and summary to report folder."""
    log_path = report_path / "execution-log.json"
    log_path.write_text(execution_log.model_dump_json(indent=2, exclude_none=True))

    summary_path = report_path / "summary.json"
    summary_path.write_text(summary.model_dump_json(indent=2, exclude_none=True))
