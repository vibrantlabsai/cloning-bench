import os
import sys
from pathlib import Path

import click
from google import genai
from google.genai import types

SYSTEM_PROMPT = """You are a UI tester that catches regressions in UIs.

You will receive 3 screenshots:
1. **Subject** - The current UI (what we have built)
2. **Diff** - A difference mask overlaid on the subject showing visual differences
3. **Actual** - The target UI (what we need to match)

## Diff Color Coding

The diff image uses color coding to distinguish between types of differences:
- **Red areas** = Flagged differences that MUST be fixed (real visual mismatches)
- **Blue/Cyan areas** = Ignored content changes (dynamic content like timestamps, counters, user avatars) - these are usually safe to ignore

## Your Task

Analyze the screenshots and provide a detailed list of changes needed to make the Subject match the Actual.

1. **Primary focus**: Red-highlighted differences - these must be fixed
2. **Secondary**: If any blue/cyan areas look suspicious (e.g., structural issues incorrectly marked as dynamic content), call them out separately as potential issues to investigate

Group the needed changes by UI section (e.g., header, sidebar, main content, footer)."""

QUESTION_SYSTEM_PROMPT = """You are a UI tester analyzing visual differences between screenshots.

You will receive 3 screenshots:
1. **Subject** - The current UI (what we have built)
2. **Diff** - A difference mask overlaid on the subject showing visual differences
3. **Actual** - The target UI (what we need to match)

## Diff Color Coding
- **Red areas** = Flagged differences that MUST be fixed (real visual mismatches)
- **Blue/Cyan areas** = Ignored content changes (dynamic content like timestamps, counters, user avatars)

Answer the user's question about these screenshots and the diff mask."""


def get_mime_type(path: Path) -> str:
    """Determine MIME type based on file extension."""
    suffix = path.suffix.lower()
    mime_types = {
        ".png": "image/png",
        ".jpg": "image/jpeg",
        ".jpeg": "image/jpeg",
        ".gif": "image/gif",
        ".webp": "image/webp",
    }
    return mime_types.get(suffix, "image/png")


@click.command()
@click.argument("subject", type=click.Path(exists=True, path_type=Path))
@click.argument("diff", type=click.Path(exists=True, path_type=Path))
@click.argument("actual", type=click.Path(exists=True, path_type=Path))
@click.option("-q", "--question", type=str, default=None,
              help="Ask a specific question about the diff")
def cli(subject: Path, diff: Path, actual: Path, question: str | None) -> None:
    """Analyze UI screenshots to identify visual regressions.

    SUBJECT: Path to the current UI screenshot (what we have)
    DIFF: Path to the difference mask overlay image
    ACTUAL: Path to the target UI screenshot (what we want)
    """
    api_key = os.environ.get("GEMINI_API_KEY")
    if not api_key:
        click.echo("Error: GEMINI_API_KEY environment variable is not set", err=True)
        sys.exit(1)

    client = genai.Client(api_key=api_key)

    # Load images as bytes
    subject_bytes = subject.read_bytes()
    diff_bytes = diff.read_bytes()
    actual_bytes = actual.read_bytes()

    # Create image parts
    subject_part = types.Part.from_bytes(
        data=subject_bytes,
        mime_type=get_mime_type(subject),
    )
    diff_part = types.Part.from_bytes(
        data=diff_bytes,
        mime_type=get_mime_type(diff),
    )
    actual_part = types.Part.from_bytes(
        data=actual_bytes,
        mime_type=get_mime_type(actual),
    )

    # Select prompt and build contents based on whether a question was provided
    if question:
        system_prompt = QUESTION_SYSTEM_PROMPT
        contents = [subject_part, diff_part, actual_part, question]
    else:
        system_prompt = SYSTEM_PROMPT
        contents = [subject_part, diff_part, actual_part]

    # Generate content with all three images
    response = client.models.generate_content(
        model="gemini-3-pro-preview",
        contents=contents,
        config=types.GenerateContentConfig(
            system_instruction=system_prompt,
        ),
    )

    # Output markdown to stdout
    click.echo(response.text)


if __name__ == "__main__":
    cli()
