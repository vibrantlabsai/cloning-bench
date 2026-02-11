"""CLI helper for computing visual diffs during test execution."""

import json
import sys
from pathlib import Path

import click

from .visual import (
    DimensionMismatchError,
    compute_visual_diff,
    compute_visual_diff_with_dynamic_detection,
)


@click.command()
@click.argument("recording_screenshot", type=click.Path(exists=True, path_type=Path))
@click.argument("subject_screenshot", type=click.Path(exists=True, path_type=Path))
@click.argument("diff_output", type=click.Path(path_type=Path))
@click.option(
    "--no-dynamic-detection",
    is_flag=True,
    help="Skip all LLM-based dynamic content detection",
)
@click.option(
    "--skip-verification",
    is_flag=True,
    help="Use Stage 1 only (detect regions but skip per-region verification)",
)
def cli(
    recording_screenshot: Path,
    subject_screenshot: Path,
    diff_output: Path,
    no_dynamic_detection: bool,
    skip_verification: bool,
) -> None:
    """Generate diff visualization highlighting differences.

    RECORDING_SCREENSHOT: Path to reference screenshot from recording
    SUBJECT_SCREENSHOT: Path to screenshot captured during test
    DIFF_OUTPUT: Path to save the diff visualization

    Outputs JSON with:
    - recording_path: str
    - subject_path: str
    - diff_path: str
    - has_flagged_differences: bool (with dynamic detection)
    - dynamic_regions: list (with dynamic detection)
    - ignored_regions: list (with dynamic detection)
    - flagged_regions: list (with dynamic detection)

    Color coding in diff image (with dynamic detection):
    - Red: Flagged differences (non-dynamic + structural issues)
    - Blue/Cyan: Ignored content changes in dynamic regions

    Exits with code 1 if images are not 1280x720.
    """
    try:
        if no_dynamic_detection:
            # Use original diff without LLM processing
            compute_visual_diff(
                recording_screenshot,
                subject_screenshot,
                diff_output,
            )

            result = {
                "recording_path": str(recording_screenshot),
                "subject_path": str(subject_screenshot),
                "diff_path": str(diff_output),
            }
        else:
            # Use two-stage dynamic detection
            diff_result = compute_visual_diff_with_dynamic_detection(
                recording_screenshot,
                subject_screenshot,
                diff_output,
                skip_verification=skip_verification,
            )

            result = {
                "recording_path": str(recording_screenshot),
                "subject_path": str(subject_screenshot),
                **diff_result.to_dict(),
            }

        click.echo(json.dumps(result))

    except DimensionMismatchError as e:
        click.echo(f"ERROR: {e}", err=True)
        sys.exit(1)
    except FileNotFoundError as e:
        click.echo(f"ERROR: {e}", err=True)
        sys.exit(1)


if __name__ == "__main__":
    cli()
