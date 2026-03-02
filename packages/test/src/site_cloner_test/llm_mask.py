"""LLM-based dynamic content detection for diff masks using Gemini."""

import base64
import json
import logging
import os
from dataclasses import dataclass
from enum import Enum
from pathlib import Path

import cv2
import numpy as np

logger = logging.getLogger(__name__)


class DifferenceType(Enum):
    """Classification of difference in a dynamic region."""

    CONTENT_CHANGE = "CONTENT_CHANGE"  # Same structure, different content - ignore
    STRUCTURAL_CHANGE = "STRUCTURAL_CHANGE"  # Different layout/size - flag
    MISSING = "MISSING"  # Element missing or significantly different - flag


@dataclass
class DynamicRegion:
    """A detected dynamic content region."""

    x: int
    y: int
    width: int
    height: int
    label: str
    region_type: str

    def to_dict(self) -> dict:
        """Convert to dictionary for JSON serialization."""
        return {
            "x": self.x,
            "y": self.y,
            "width": self.width,
            "height": self.height,
            "label": self.label,
            "type": self.region_type,
        }

    @classmethod
    def from_dict(cls, data: dict) -> "DynamicRegion":
        """Create from dictionary."""
        return cls(
            x=data["x"],
            y=data["y"],
            width=data["width"],
            height=data["height"],
            label=data["label"],
            region_type=data["type"],
        )

    def crop_image(self, img: np.ndarray) -> np.ndarray:
        """Crop this region from an image."""
        return img[self.y : self.y + self.height, self.x : self.x + self.width]


@dataclass
class RegionVerification:
    """Result of verifying a difference in a dynamic region."""

    region: DynamicRegion
    difference_type: DifferenceType
    reason: str


def _get_gemini_client():
    """Get the Gemini client, returns None if API key not available."""
    api_key = os.environ.get("GEMINI_API_KEY")
    google_creds = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")

    if not api_key and not google_creds:
        logger.warning("GEMINI_API_KEY / GOOGLE_APPLICATION_CREDENTIALS not set, LLM detection disabled")
        return None

    try:
        from google import genai

        if api_key:
            return genai.Client(api_key=api_key)
        else:
            return genai.Client(vertexai=True)
    except ImportError:
        logger.warning("google-genai not installed, LLM detection disabled")
        return None


def _image_to_base64(img: np.ndarray) -> str:
    """Convert numpy image to base64 string."""
    _, buffer = cv2.imencode(".png", img)
    return base64.b64encode(buffer).decode("utf-8")


def _load_image_bytes(path: Path) -> bytes:
    """Load image file as bytes."""
    return path.read_bytes()


STAGE1_PROMPT = """Analyze this screenshot and identify all regions containing dynamic content - content that changes between page loads or over time.

Types of dynamic content to identify:
- Timestamps (e.g., "5 minutes ago", "Jan 28, 2026")
- Counters (e.g., view counts, like counts)
- Advertisements and ad slots
- Carousels and slideshows
- Personalized content (e.g., "Recommended for you")
- Trending sections
- Live indicators
- User-specific data (names, avatars)
- Random/rotating content

Return a JSON array of detected regions. Each region should have:
- x: left coordinate in pixels
- y: top coordinate in pixels
- width: width in pixels
- height: height in pixels
- label: brief description of what this region contains
- type: category (timestamp, counter, ad, carousel, personalized, trending, live, user_content, random)

Return ONLY valid JSON array, no markdown formatting. Example:
[{"x": 100, "y": 50, "width": 200, "height": 30, "label": "Post timestamp", "type": "timestamp"}]

If no dynamic regions are found, return an empty array: []"""


STAGE2_PROMPT = """Compare these two cropped regions from the same UI location.

Region type: {region_type}
Region label: {label}

Determine the type of difference between these two images:

1. CONTENT_CHANGE - Same visual structure, but different content displayed
   - Examples: Different timestamp text, different counter number, different ad image
   - The element looks the same but shows different data

2. STRUCTURAL_CHANGE - Different layout, size, shape, or visual structure
   - Examples: Element is resized, repositioned, has different border/styling
   - The element itself has changed, not just its content

3. MISSING - Element is missing, empty, or has been replaced with something completely different
   - Examples: Ad slot is now empty, element doesn't exist in one image
   - One image has the element, the other doesn't

Return ONLY valid JSON with this format:
{{"difference_type": "CONTENT_CHANGE", "reason": "Brief explanation"}}

Valid difference_type values: CONTENT_CHANGE, STRUCTURAL_CHANGE, MISSING"""


def detect_dynamic_regions(image_path: Path) -> list[DynamicRegion]:
    """Stage 1: Identify dynamic regions in a recording image.

    Args:
        image_path: Path to the recording screenshot

    Returns:
        List of detected dynamic regions with bounding boxes
    """
    client = _get_gemini_client()
    if client is None:
        return []

    try:
        from google.genai import types

        image_bytes = _load_image_bytes(image_path)

        response = client.models.generate_content(
            model="gemini-2.0-flash",
            contents=[
                types.Part.from_bytes(data=image_bytes, mime_type="image/png"),
                types.Part.from_text(text=STAGE1_PROMPT),
            ],
        )

        response_text = response.text.strip()
        # Handle potential markdown code blocks
        if response_text.startswith("```"):
            lines = response_text.split("\n")
            response_text = "\n".join(lines[1:-1])

        regions_data = json.loads(response_text)

        regions = []
        for item in regions_data:
            try:
                region = DynamicRegion.from_dict(item)
                regions.append(region)
            except (KeyError, TypeError) as e:
                logger.warning(f"Skipping invalid region data: {item}, error: {e}")

        logger.info(f"Detected {len(regions)} dynamic regions")
        return regions

    except Exception as e:
        logger.error(f"Stage 1 detection failed: {e}")
        return []


def verify_region_difference(
    recording_crop: np.ndarray,
    subject_crop: np.ndarray,
    region: DynamicRegion,
) -> DifferenceType:
    """Stage 2: Classify difference in a specific region.

    Args:
        recording_crop: Cropped region from recording image
        subject_crop: Cropped region from subject image
        region: The dynamic region being verified

    Returns:
        DifferenceType classification
    """
    client = _get_gemini_client()
    if client is None:
        # Safe default: flag as structural change
        return DifferenceType.STRUCTURAL_CHANGE

    try:
        from google.genai import types

        # Encode both crops
        _, rec_buffer = cv2.imencode(".png", recording_crop)
        _, sub_buffer = cv2.imencode(".png", subject_crop)

        prompt = STAGE2_PROMPT.format(
            region_type=region.region_type,
            label=region.label,
        )

        response = client.models.generate_content(
            model="gemini-2.0-flash",
            contents=[
                types.Part.from_text(text="Recording image (reference):"),
                types.Part.from_bytes(data=rec_buffer.tobytes(), mime_type="image/png"),
                types.Part.from_text(text="Subject image (test):"),
                types.Part.from_bytes(data=sub_buffer.tobytes(), mime_type="image/png"),
                types.Part.from_text(text=prompt),
            ],
        )

        response_text = response.text.strip()
        # Handle potential markdown code blocks
        if response_text.startswith("```"):
            lines = response_text.split("\n")
            response_text = "\n".join(lines[1:-1])

        result = json.loads(response_text)
        diff_type_str = result.get("difference_type", "STRUCTURAL_CHANGE")

        try:
            return DifferenceType(diff_type_str)
        except ValueError:
            logger.warning(f"Unknown difference type: {diff_type_str}")
            return DifferenceType.STRUCTURAL_CHANGE

    except Exception as e:
        logger.error(f"Stage 2 verification failed: {e}")
        # Safe default: flag as structural change
        return DifferenceType.STRUCTURAL_CHANGE


def get_or_create_dynamic_regions(
    recording_path: Path,
    force_detect: bool = False,  # kept for API compatibility, now ignored
) -> list[DynamicRegion]:
    """Detect dynamic regions in a recording image.

    Args:
        recording_path: Path to the recording screenshot
        force_detect: Deprecated, kept for API compatibility

    Returns:
        List of dynamic regions
    """
    return detect_dynamic_regions(recording_path)


def region_has_differences(
    region: DynamicRegion,
    threshold_mask: np.ndarray,
    min_diff_pixels: int = 10,
) -> bool:
    """Check if a region contains differences based on the threshold mask.

    Args:
        region: The dynamic region to check
        threshold_mask: Binary mask of differences (255 = different)
        min_diff_pixels: Minimum number of different pixels to consider

    Returns:
        True if region has significant differences
    """
    region_mask = threshold_mask[
        region.y : region.y + region.height, region.x : region.x + region.width
    ]
    diff_count = np.count_nonzero(region_mask)
    return diff_count >= min_diff_pixels
