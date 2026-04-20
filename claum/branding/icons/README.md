# Claum app icons

Drop your final icon files here:

```
icons/
├── app.icns          ← macOS (built from a 1024×1024 PNG with iconutil)
├── app.ico           ← Windows (multi-resolution: 16, 32, 48, 64, 128, 256)
├── app_512.png       ← Linux / generic
├── document.icns     ← macOS document icon (HTML/PDF when Claum is default)
└── source/           ← editable source (SVG, Sketch, Figma, etc.)
```

## Generating from a single SVG

```bash
# macOS — produce app.icns from a 1024×1024 PNG
mkdir app.iconset
sips -z 16 16     icon-1024.png --out app.iconset/icon_16x16.png
sips -z 32 32     icon-1024.png --out app.iconset/icon_16x16@2x.png
sips -z 32 32     icon-1024.png --out app.iconset/icon_32x32.png
sips -z 64 64     icon-1024.png --out app.iconset/icon_32x32@2x.png
sips -z 128 128   icon-1024.png --out app.iconset/icon_128x128.png
sips -z 256 256   icon-1024.png --out app.iconset/icon_128x128@2x.png
sips -z 256 256   icon-1024.png --out app.iconset/icon_256x256.png
sips -z 512 512   icon-1024.png --out app.iconset/icon_256x256@2x.png
sips -z 512 512   icon-1024.png --out app.iconset/icon_512x512.png
cp icon-1024.png             app.iconset/icon_512x512@2x.png
iconutil -c icns app.iconset
mv app.icns ../app.icns

# Windows — needs ImageMagick
magick convert icon-1024.png -define icon:auto-resize=256,128,96,64,48,32,16 app.ico
```

## Design notes

The Claum mark is the Claude "C" overlaid on the Chrome circle, but rendered
in the glass-morphism style: frosted gradient fill, soft inner highlight, no
pure-black outlines. Match the palette in `glass-browser-preview.html`:

- Primary tint:  `#D97757` (Claude orange)
- Glass fill:    `rgba(255,255,255,0.12)` over a desaturated background
- Highlight:     `rgba(255,255,255,0.35)` top-left arc
