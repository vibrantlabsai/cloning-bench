---
name: asset-handling
description: Extracts images, icons, fonts, and other assets from recording data for use in the clone.
---

# Asset Extraction

Extract and copy assets (images, icons, fonts, CSS, JS) from recordings to your project.

## Workflow

```
Screenshot -> Accessibility Tree -> Grep DOM -> Manifest -> Copy Asset
```

1. **Screenshot** - See what asset you need visually
2. **Accessibility tree** - Find semantic identifiers (alt text, labels)
3. **Grep DOM** - Find actual URLs using keywords
4. **Manifest** - Map URLs to asset hashes
5. **Copy** - Move asset to `public/` folder with correct extension

## Step-by-Step

### 1. Identify the Asset

Look at the recording screenshot to identify what you need:
- Logo images
- Icons (social, UI, etc.)
- Background images
- Profile pictures
- Product images

### 2. Find Semantic Identifiers

Read the accessibility tree to find identifying information:

```bash
cat ./recordings/<rec>/screenshots/<idx>/viewport/axtree.txt
```

Look for entries like:
```
[22] img 'Company Logo'
[45] img 'Twitter icon'
[67] button 'Search' [has icon]
```

### 3. Search DOM for URLs

Use the accessible name or common keywords to find the URL in DOM:

```bash
grep -i "company-logo" ./recordings/<rec>/screenshots/<idx>/dom.html
grep -i "twitter" ./recordings/<rec>/screenshots/<idx>/dom.html
grep -i "\.png\|\.jpg\|\.svg" ./recordings/<rec>/screenshots/<idx>/dom.html | head -20
```

### 4. Match URL to Hash

Look up the URL in the manifest:

```bash
cat ./recordings/<rec>/screenshots/<idx>/manifest.json | grep -A1 "logo"
```

The manifest maps URLs to hashes:
```json
{
  "assets": [
    {"url": "https://example.com/images/logo.png", "hash": "abc123def456..."}
  ]
}
```

### 5. Copy Asset

Copy the asset with the correct extension:

```bash
cp ./recordings/<rec>/assets/<hash> ./public/images/logo.png
```

## Asset Types

### Images

```bash
grep -oE 'src="[^"]*\.(png|jpg|jpeg|gif|webp|svg)"' ./recordings/<rec>/screenshots/<idx>/dom.html
grep -i "img src" ./recordings/<rec>/screenshots/<idx>/dom.html
grep -i "background-image" ./recordings/<rec>/screenshots/<idx>/dom.html
```

### Icons

Icons come in three forms:

**Inline SVG** (no asset file):
```bash
grep -o "<svg[^>]*>.*</svg>" ./recordings/<rec>/screenshots/<idx>/dom.html
```

**Icon images** (img tags):
```bash
grep -i "icon" ./recordings/<rec>/screenshots/<idx>/dom.html
```

**CSS background** (in stylesheets):
```bash
cat ./recordings/<rec>/screenshots/<idx>/manifest.json | grep "\.css"
grep "background-image" ./recordings/<rec>/assets/<css-hash>
```

### Fonts

```bash
cat ./recordings/<rec>/screenshots/<idx>/manifest.json | grep -i "font\|woff\|ttf"
grep -A5 "@font-face" ./recordings/<rec>/assets/<css-hash>
```

## Tips

### Resolution Selection
- Choose higher resolution versions over thumbnails
- Look for srcset attributes with multiple sizes
- Prefer SVG for icons when available (scalable)

### Inline SVGs
- Embedded directly in the DOM, not in assets
- Extract from `dom.html` and save to your project
- May need cleanup (remove inline styles, add classes)

### CSS Background Images
- Check stylesheet assets for `background-image` URLs
- May be base64 encoded (data:image/...)
- May use relative URLs that need the manifest lookup

### Sprite Sheets
- Some sites use CSS sprites (one image, multiple background-position)
- Extract the full sprite and replicate the CSS positioning

## Directory Structure

Organize extracted assets:

```
public/
├── images/
│   ├── logo.png
│   ├── banner.jpg
│   └── products/
├── icons/
│   ├── twitter.svg
│   ├── facebook.svg
│   └── search.svg
└── fonts/
    ├── inter-regular.woff2
    └── inter-bold.woff2
```

## Troubleshooting

### Asset not in manifest
- May be inline (SVG, base64)
- May be loaded dynamically (check other assertion indices)
- May be from external CDN not captured

### Wrong resolution
- Check for srcset alternatives
- Look for @2x or @3x versions
- Search other assertion indices

### Missing fonts
- Check if font is from Google Fonts (use CDN link instead)
- Font may be system font (no asset needed)
- Check CSS for font-family fallbacks
