---
name: site-test
description: Visual compliance testing tools for comparing a website clone against reference recordings. Use to run tests, generate visual diffs, and analyze differences.
---

# Visual Compliance Testing

These CLI tools compare your clone against reference recordings to identify visual differences.

## Commands

### site-test

Run a full visual compliance test against a recording.

```bash
site-test <recording_folder> <url>
```

**Arguments:**
- `recording_folder` - Path to the recording directory (e.g., `./recordings/0`)
- `url` - URL of your dev server (e.g., `http://localhost:5173`)

**Options:**
- `--output-dir <path>` - Where to write the test report (default: auto-generated)
- `--no-dynamic-detection` - Skip LLM-based dynamic content detection (faster)
- `--skip-verification` - Use Stage 1 detection only (fastest)
- `--screenplay <path>` - Custom screenplay file (auto-discovered by default)

**What it does:**
1. Reads the screenplay.json from the recording
2. Executes each step (navigation, clicks, etc.) via browser automation
3. Takes screenshots at assertion points
4. Compares screenshots against reference images
5. Generates a report with diffs

**Output structure:**
```
{domain}_{timestamp}_test/
├── execution-log.json    # Detailed step-by-step log
├── summary.json          # Pass/fail with step counts and duration
├── asserts/
│   ├── 0/
│   │   ├── screenshot.png   # Captured screenshot
│   │   └── diff.png         # Visual diff (if differences found)
│   └── ...
└── recording/            # Copy of reference data
```

**Example:**
```bash
site-test ./recordings/0 http://localhost:5173
site-test ./recordings/0 http://localhost:5173 --no-dynamic-detection
site-test ./recordings/0 http://localhost:5173 --output-dir ./test-results
```

### site-test-diff

Generate a visual diff between two screenshots.

```bash
site-test-diff <reference_screenshot> <subject_screenshot> <output_path>
```

**Arguments:**
- `reference_screenshot` - Path to the reference image (from recording)
- `subject_screenshot` - Path to the current implementation screenshot
- `output_path` - Where to write the diff image

**Options:**
- `--no-dynamic-detection` - Pure SSIM-based diff without LLM analysis
- `--skip-verification` - Stage 1 only (detect regions but skip classification)

**What it does:**
1. Computes structural similarity (SSIM) between the two images
2. Stage 1: Uses Gemini to detect dynamic content regions (timestamps, ads, etc.)
3. Stage 2: Classifies each difference as structural (red) or content change (blue)
4. Outputs a color-coded diff image

**Expected image dimensions:** 1280x720

**Example:**
```bash
site-test-diff ./recordings/0/screenshots/0/screenshot.png ./my-screenshot.png ./diff.png
site-test-diff ./recordings/0/screenshots/0/screenshot.png ./my-screenshot.png ./diff.png --no-dynamic-detection
```

### lookatdiff

AI-powered analysis of visual differences using Gemini.

```bash
lookatdiff <subject> <diff> <actual>
```

**Arguments:**
- `subject` - Screenshot of the current implementation
- `diff` - The diff image (from site-test-diff)
- `actual` - The reference screenshot (target)

**Options:**
- `-q, --question <text>` - Ask a specific question about the differences

**What it does:**
- Sends all three images to Gemini for multi-modal analysis
- Identifies what needs to be fixed based on red-highlighted differences
- Groups changes by UI section (header, sidebar, content, footer)
- Flags suspicious blue/cyan areas that might be incorrectly marked

**Example:**
```bash
lookatdiff ./my-screenshot.png ./diff.png ./recordings/0/screenshots/0/screenshot.png
lookatdiff ./my-screenshot.png ./diff.png ./reference.png -q "What CSS changes would fix the header?"
```

## Workflow

A typical testing iteration:

```bash
# 1. Start your dev server
npm run dev &

# 2. Run the full test suite
site-test ./recordings/0 http://localhost:5173

# 3. Review the report
cat ./*_test/summary.json

# 4. For specific diffs, get detailed analysis
lookatdiff ./capture.png ./diff.png ./reference.png

# 5. Make fixes and re-test
site-test ./recordings/0 http://localhost:5173
```

## Diff Color Coding

| Color | Meaning | Action |
|-------|---------|--------|
| **Red** | Structural differences (layout, missing elements) | Must fix |
| **Blue/Cyan** | Dynamic content changes (same structure, different text) | Can ignore |

## Two-Stage Detection

1. **Stage 1 - Region detection**: Gemini identifies dynamic content areas (timestamps, counters, personalized content, ads, carousels)
2. **Stage 2 - Difference verification**: Each flagged region is classified as:
   - `CONTENT_CHANGE` - Same structure, different content (blue, ignore)
   - `STRUCTURAL_CHANGE` - Layout or size changed (red, must fix)
   - `MISSING` - Element missing entirely (red, must fix)
