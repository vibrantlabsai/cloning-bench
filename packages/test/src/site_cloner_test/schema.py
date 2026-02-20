"""Pydantic models for execution log and summary reports."""

from typing import Literal

from pydantic import BaseModel, Field


class AssertionComparison(BaseModel):
    """Visual comparison result for an assertion step."""

    screenshot_index: int = Field(description="Screenshot index from screenplay (e.g., 3 for screenshots/3.png)")
    recording_path: str = Field(description="Path to recording screenshot (e.g., asserts/3/recording.png)")
    subject_path: str = Field(description="Path to captured screenshot (e.g., asserts/3/subject.png)")
    diff_path: str = Field(description="Path to diff visualization (e.g., asserts/3/diff.png)")
    passed: bool = Field(description="Whether the visual assertion passed")
    reasoning: str | None = Field(default=None, description="Agent's reasoning for pass/fail judgment")


class StepResult(BaseModel):
    """Result of executing a single screenplay step."""

    index: int = Field(description="Step index in the screenplay")
    type: Literal["action", "assert", "wait"] = Field(description="Step type")
    description: str = Field(description="Step description or condition")
    status: Literal["completed", "skipped", "failed"] = Field(
        description="Execution status"
    )
    started_at: str | None = Field(
        default=None, description="ISO 8601 datetime when step execution started"
    )
    completed_at: str | None = Field(
        default=None, description="ISO 8601 datetime when step execution completed"
    )
    screenshot_captured: str | None = Field(
        default=None, description="Path to captured screenshot if applicable"
    )
    notes: str | None = Field(
        default=None, description="Additional notes about execution"
    )
    assertion: AssertionComparison | None = Field(
        default=None, description="Visual comparison result for assert steps"
    )


class ExecutionLog(BaseModel):
    """Detailed step-by-step execution log."""

    started_at: str = Field(description="ISO 8601 datetime when execution started")
    completed_at: str = Field(description="ISO 8601 datetime when execution completed")
    steps: list[StepResult] = Field(description="Results for each step")


class SkippedStep(BaseModel):
    """Information about a skipped step."""

    index: int = Field(description="Step index")
    reason: str = Field(description="Reason for skipping")


class FailedStep(BaseModel):
    """Information about the step where execution failed."""

    index: int = Field(description="Step index")
    type: Literal["action", "assert", "wait"] = Field(description="Step type")
    description: str = Field(description="Step description")


class Summary(BaseModel):
    """High-level test result summary."""

    status: Literal["success", "failure"] = Field(description="Overall test status")
    screenplay: str = Field(description="Path to screenplay file in report")
    source_recording: str = Field(description="Name of source recording folder")
    started_at: str = Field(description="ISO 8601 datetime when execution started")
    completed_at: str = Field(description="ISO 8601 datetime when execution completed")
    duration_seconds: float = Field(description="Total execution time in seconds")
    steps_total: int = Field(description="Total number of steps in screenplay")
    steps_completed: int = Field(description="Number of steps completed successfully")
    steps_skipped: int = Field(description="Number of steps skipped")
    steps_failed: int = Field(description="Number of steps that failed")
    skipped_steps: list[SkippedStep] = Field(
        default_factory=list, description="Details of skipped steps"
    )
    failure_reason: str | None = Field(
        default=None, description="Reason for failure if status is failure"
    )
    failed_at_step: FailedStep | None = Field(
        default=None, description="Step where execution failed"
    )
    last_screenshot: str | None = Field(
        default=None, description="Path to last screenshot taken before failure"
    )
