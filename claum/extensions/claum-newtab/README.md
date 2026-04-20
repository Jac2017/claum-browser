# claum-newtab (component extension)

This is the new-tab / sidebar / settings extension. It was previously the
`glass-browser-extension` from the Glass Browser build — merged into this repo
and rebranded for Claum.

## How it ships

It's a **component extension**: loaded at startup by Chromium from the resource
bundle, can't be uninstalled, always enabled. Registration happens in
`claum/patches/04-component-extensions.patch`, which teaches
`chrome/browser/extensions/component_loader.cc` about this folder.

## Files

```
claum-newtab/
├── manifest.json      ← MV3 manifest, declares newtab override + sidepanel
├── background.js      ← service worker (tab tracking, storage wiring)
├── newtab.html        ← glass NTP layout (weather, bookmarks, top sites, feed)
├── newtab.js          ← NTP logic (94 KB — includes feed renderer)
├── sidepanel/
│   ├── sidepanel.html ← vertical tab sidebar
│   └── sidepanel.js
├── options.html       ← settings page (chrome://extensions → Details → Options)
├── options.js
├── rules.json         ← declarativeNetRequest rules (ad-frame helpers)
├── ads/
│   └── ad-frame.html  ← sandboxed iframe for optional partner content
└── icons/             ← 16 / 48 / 128 px PNGs
```

## Developing it

Because it's loaded as a component extension, editing files here only takes
effect after the next browser build. For fast iteration:

```bash
# From the Chromium source tree (build/src)
out/Claum/Claum.app/Contents/MacOS/Claum \
  --load-extension=~/claum-browser/claum/extensions/claum-newtab \
  --user-data-dir=/tmp/claum-dev
```

That side-loads the extension as a regular (not component) extension, so you
can reload from `chrome://extensions` without rebuilding the browser.
