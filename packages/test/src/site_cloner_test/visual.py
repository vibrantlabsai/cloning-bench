"""Visual comparison utilities for assertion screenshots."""

import logging
import re
import shutil
from dataclasses import dataclass, field
from pathlib import Path

import cv2
import numpy as np
from skimage.metrics import structural_similarity

from .llm_mask import (
    DifferenceType,
    DynamicRegion,
    RegionVerification,
    get_or_create_dynamic_regions,
    region_has_differences,
    verify_region_difference,
)

logger = logging.getLogger(__name__)

EXPECTED_WIDTH = 1280
EXPECTED_HEIGHT = 720


class DimensionMismatchError(ValueError):
    """Raised when image dimensions don't match expected 1280x720."""

    def __init__(self, path: Path, actual_width: int, actual_height: int):
        self.path = path
        self.actual_width = actual_width
        self.actual_height = actual_height
        super().__init__(
            f"Image {path} has dimensions {actual_width}x{actual_height}, "
            f"expected {EXPECTED_WIDTH}x{EXPECTED_HEIGHT}"
        )


def extract_screenshot_index(screenshot_path: str) -> int:
    """Extract the screenshot index from a path like 'screenshots/3/screenshot.png'.

    Args:
        screenshot_path: Path string like 'screenshots/3/screenshot.png' or 'screenshots/12/screenshot.png'
            Also supports legacy format 'screenshots/3.png' for backwards compatibility.

    Returns:
        The numeric index (e.g., 3, 12)

    Raises:
        ValueError: If the path doesn't match expected pattern
    """
    match = re.search(r"screenshots/(\d+)/screenshot\.png$", screenshot_path)
    if not match:
        match = re.search(r"screenshots/(\d+)\.png$", screenshot_path)
    if not match:
        raise ValueError(f"Invalid screenshot path format: {screenshot_path}")
    return int(match.group(1))


def prepare_assertion_folder(
    report_path: Path,
    screenshot_index: int,
    recording_path: Path,
) -> Path:
    """Create assertion folder and copy recording screenshot.

    Args:
        report_path: Path to the report folder
        screenshot_index: The screenshot index (e.g., 3 for screenshots/3/screenshot.png)
        recording_path: Path to the source recording folder

    Returns:
        Path to the assertion folder (e.g., report_path/asserts/3/)
    """
    assert_folder = report_path / "asserts" / str(screenshot_index)
    assert_folder.mkdir(parents=True, exist_ok=True)

    recording_screenshot = recording_path / "screenshots" / str(screenshot_index) / "screenshot.png"
    if not recording_screenshot.exists():
        recording_screenshot = recording_path / "screenshots" / f"{screenshot_index}.png"
    if recording_screenshot.exists():
        shutil.copy(recording_screenshot, assert_folder / "recording.png")

    return assert_folder


def compute_visual_diff(
    recording_path: Path,
    subject_path: Path,
    diff_path: Path,
) -> float:
    """Compute SSIM and generate diff mask with red overlay.

    Args:
        recording_path: Path to the reference screenshot from recording
        subject_path: Path to the screenshot captured during test
        diff_path: Path to save the diff visualization

    Returns:
        SSIM score (0.0 to 1.0, higher is more similar)

    Raises:
        DimensionMismatchError: If either image is not 1280x720
        FileNotFoundError: If either image doesn't exist
    """
    if not recording_path.exists():
        raise FileNotFoundError(f"Recording screenshot not found: {recording_path}")
    if not subject_path.exists():
        raise FileNotFoundError(f"Subject screenshot not found: {subject_path}")

    recording_img = cv2.imread(str(recording_path))
    subject_img = cv2.imread(str(subject_path))

    if recording_img is None:
        raise FileNotFoundError(f"Failed to read recording image: {recording_path}")
    if subject_img is None:
        raise FileNotFoundError(f"Failed to read subject image: {subject_path}")

    rec_h, rec_w = recording_img.shape[:2]
    if rec_w != EXPECTED_WIDTH or rec_h != EXPECTED_HEIGHT:
        raise DimensionMismatchError(recording_path, rec_w, rec_h)

    sub_h, sub_w = subject_img.shape[:2]
    if sub_w != EXPECTED_WIDTH or sub_h != EXPECTED_HEIGHT:
        raise DimensionMismatchError(subject_path, sub_w, sub_h)

    recording_gray = cv2.cvtColor(recording_img, cv2.COLOR_BGR2GRAY)
    subject_gray = cv2.cvtColor(subject_img, cv2.COLOR_BGR2GRAY)

    ssim_score, diff_map = structural_similarity(
        recording_gray,
        subject_gray,
        full=True,
    )

    diff_map_uint8 = ((1 - diff_map) * 255).astype(np.uint8)

    _, threshold_mask = cv2.threshold(diff_map_uint8, 25, 255, cv2.THRESH_BINARY)

    diff_overlay = subject_img.copy()
    diff_overlay[threshold_mask > 0] = [0, 0, 255]  # BGR red

    blended = cv2.addWeighted(subject_img, 0.5, diff_overlay, 0.5, 0)

    cv2.imwrite(str(diff_path), blended)

    return float(ssim_score)


@dataclass
class DiffResult:
    """Result of visual diff computation with dynamic region analysis."""

    diff_path: Path
    has_flagged_differences: bool
    ssim_score: float = 0.0
    dynamic_regions: list[DynamicRegion] = field(default_factory=list)
    verifications: list[RegionVerification] = field(default_factory=list)
    ignored_regions: list[DynamicRegion] = field(default_factory=list)
    flagged_regions: list[DynamicRegion] = field(default_factory=list)

    def to_dict(self) -> dict:
        """Convert to dictionary for JSON serialization."""
        return {
            "diff_path": str(self.diff_path),
            "ssim_score": self.ssim_score,
            "has_flagged_differences": self.has_flagged_differences,
            "dynamic_regions": [r.to_dict() for r in self.dynamic_regions],
            "verifications": [
                {
                    "region": v.region.to_dict(),
                    "difference_type": v.difference_type.value,
                    "reason": v.reason,
                }
                for v in self.verifications
            ],
            "ignored_regions": [r.to_dict() for r in self.ignored_regions],
            "flagged_regions": [r.to_dict() for r in self.flagged_regions],
        }


def compute_visual_diff_with_dynamic_detection(
    recording_path: Path,
    subject_path: Path,
    diff_path: Path,
    dynamic_regions: list[DynamicRegion] | None = None,
    skip_verification: bool = False,
) -> DiffResult:
    """Generate diff mask with color coding for dynamic content detection.

    Color coding:
    - Red: Flagged differences (non-dynamic + structural issues in dynamic regions)
    - Blue/Cyan: Ignored content changes in dynamic regions

    Args:
        recording_path: Path to the reference screenshot from recording
        subject_path: Path to the screenshot captured during test
        diff_path: Path to save the diff visualization
        dynamic_regions: Pre-loaded dynamic regions, or None to auto-detect
        skip_verification: If True, skip Stage 2 and mask all dynamic regions

    Returns:
        DiffResult with diff path and region analysis

    Raises:
        DimensionMismatchError: If either image is not 1280x720
        FileNotFoundError: If either image doesn't exist
    """
    if not recording_path.exists():
        raise FileNotFoundError(f"Recording screenshot not found: {recording_path}")
    if not subject_path.exists():
        raise FileNotFoundError(f"Subject screenshot not found: {subject_path}")

    recording_img = cv2.imread(str(recording_path))
    subject_img = cv2.imread(str(subject_path))

    if recording_img is None:
        raise FileNotFoundError(f"Failed to read recording image: {recording_path}")
    if subject_img is None:
        raise FileNotFoundError(f"Failed to read subject image: {subject_path}")

    rec_h, rec_w = recording_img.shape[:2]
    if rec_w != EXPECTED_WIDTH or rec_h != EXPECTED_HEIGHT:
        raise DimensionMismatchError(recording_path, rec_w, rec_h)

    sub_h, sub_w = subject_img.shape[:2]
    if sub_w != EXPECTED_WIDTH or sub_h != EXPECTED_HEIGHT:
        raise DimensionMismatchError(subject_path, sub_w, sub_h)

    # Compute SSIM diff
    recording_gray = cv2.cvtColor(recording_img, cv2.COLOR_BGR2GRAY)
    subject_gray = cv2.cvtColor(subject_img, cv2.COLOR_BGR2GRAY)

    ssim_score, diff_map = structural_similarity(
        recording_gray,
        subject_gray,
        full=True,
    )

    diff_map_uint8 = ((1 - diff_map) * 255).astype(np.uint8)
    _, threshold_mask = cv2.threshold(diff_map_uint8, 25, 255, cv2.THRESH_BINARY)

    # Detect dynamic regions
    if dynamic_regions is None:
        dynamic_regions = get_or_create_dynamic_regions(recording_path)

    # Process dynamic regions
    verifications: list[RegionVerification] = []
    ignored_regions: list[DynamicRegion] = []
    flagged_regions: list[DynamicRegion] = []

    # Create masks for ignored (blue) and flagged (red) differences
    ignored_mask = np.zeros((EXPECTED_HEIGHT, EXPECTED_WIDTH), dtype=np.uint8)
    flagged_mask = threshold_mask.copy()

    for region in dynamic_regions:
        if not region_has_differences(region, threshold_mask):
            continue

        if skip_verification:
            # Skip Stage 2: treat all dynamic region differences as content changes
            ignored_regions.append(region)
            # Mark region as ignored in the mask
            ignored_mask[
                region.y : region.y + region.height, region.x : region.x + region.width
            ] = threshold_mask[
                region.y : region.y + region.height, region.x : region.x + region.width
            ]
            # Remove from flagged mask
            flagged_mask[
                region.y : region.y + region.height, region.x : region.x + region.width
            ] = 0
        else:
            # Stage 2: Verify each region with differences
            recording_crop = region.crop_image(recording_img)
            subject_crop = region.crop_image(subject_img)

            diff_type = verify_region_difference(
                recording_crop, subject_crop, region
            )

            verification = RegionVerification(
                region=region,
                difference_type=diff_type,
                reason="",  # Could be populated from API response
            )
            verifications.append(verification)

            if diff_type == DifferenceType.CONTENT_CHANGE:
                # Ignore this region - mark as blue
                ignored_regions.append(region)
                ignored_mask[
                    region.y : region.y + region.height,
                    region.x : region.x + region.width,
                ] = threshold_mask[
                    region.y : region.y + region.height,
                    region.x : region.x + region.width,
                ]
                # Remove from flagged mask
                flagged_mask[
                    region.y : region.y + region.height,
                    region.x : region.x + region.width,
                ] = 0
            else:
                # Flag this region - keep as red
                flagged_regions.append(region)
                logger.info(
                    f"Flagged dynamic region '{region.label}' as {diff_type.value}"
                )

    # Generate color-coded diff image
    diff_overlay = subject_img.copy()

    # Apply red overlay for flagged differences
    diff_overlay[flagged_mask > 0] = [0, 0, 255]  # BGR red

    # Apply blue/cyan overlay for ignored content changes
    diff_overlay[ignored_mask > 0] = [255, 200, 0]  # BGR cyan/blue tint

    # Blend with original
    blended = cv2.addWeighted(subject_img, 0.5, diff_overlay, 0.5, 0)

    cv2.imwrite(str(diff_path), blended)

    # Determine if there are flagged differences
    # (non-dynamic differences or structural/missing in dynamic regions)
    has_flagged = np.any(flagged_mask > 0)

    return DiffResult(
        diff_path=diff_path,
        has_flagged_differences=bool(has_flagged),
        ssim_score=float(ssim_score),
        dynamic_regions=dynamic_regions,
        verifications=verifications,
        ignored_regions=ignored_regions,
        flagged_regions=flagged_regions,
    )
