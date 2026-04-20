# Claum — first-run import flow

What happens the first time a user launches Claum, and what gets brought over
from their existing browser.

## User-visible flow

1. User double-clicks Claum.app (or launches `claum.exe`).
2. Claum's Welcome tab opens with the glass NTP.
3. Immediately after, a second tab opens: `chrome://settings/importData`.
4. The Source dropdown is pre-set to **Google Chrome** (if detected).
   Other sources Claum detects on the machine: Firefox, Safari (mac only),
   Microsoft Edge (win), Brave, Arc.
5. Checkboxes appear for each data category. **All are checked by default:**

   | Data               | Source of truth                                    |
   |--------------------|----------------------------------------------------|
   | Bookmarks          | `Bookmarks` JSON file in the source profile        |
   | Browsing history   | `History` SQLite database                          |
   | Saved passwords    | `Login Data` SQLite, decrypted via OS keychain     |
   | Cookies            | `Cookies` SQLite database                          |
   | Autofill form data | `Web Data` SQLite                                  |
   | Search engines     | `Preferences` → `default_search_provider_data`     |
   | Home page          | `Preferences` → `homepage`                         |
   | **Installed extensions** (Claum-specific) | `Preferences` → `extensions.settings` |

6. User clicks **Import**. Claum:
   - For each regular category, spawns the standard utility-process importer.
   - For extensions, reads the IDs from Preferences, then queues each for
     install via the Chrome Web Store update URL.
7. A progress dialog shows per-category status. Most imports finish in <5 s;
   extensions take longer because each is a web-store round-trip.
8. Claum restarts once to pick up any imported default-search-engine change.

## Under the hood

### Regular importer

The standard Chromium importer is invoked via `ImporterHost::StartImportSettings`
with these flags set:

```cpp
uint16_t items = importer::FAVORITES
               | importer::HISTORY
               | importer::PASSWORDS
               | importer::SEARCH_ENGINES
               | importer::AUTOFILL_FORM_DATA
               | importer::HOME_PAGE
               | importer::COOKIES          // Claum adds this
               | importer::CLAUM_EXTENSIONS; // Claum-only bit
```

### Cookies

Upstream Chromium intentionally does NOT import cookies across profiles
(security concern: cookies are session credentials). Claum enables it behind
a one-time confirmation dialog, with a clear warning that it's copying session
state. Most users want this — it means they don't have to log back into
everything.

### Extensions

Chrome doesn't export its extension list in a standard format. What we do:

1. Read `<source_profile>/Preferences` as JSON.
2. Walk `extensions.settings` — each key is a 32-char extension ID.
3. For each entry, check:
   - `from_webstore: true` (skip anything side-loaded)
   - `state: 1` (enabled; value 0 = disabled, 2 = blacklisted)
4. For each surviving ID, queue a `WebstoreInstallWithPrompt`.

**What's skipped intentionally:**
- Developer-mode extensions (no web store == no safe re-install URL).
- Disabled extensions (the user disabled them for a reason).
- Enterprise-policy-installed extensions (managed by group policy; if the
  Claum profile is also managed, they'll install automatically).
- Component extensions in the source browser (irrelevant to Claum).

### What about Firefox?

Upstream Chromium already knows how to import bookmarks, history, passwords,
and search engines from Firefox via the NSS security database. Extensions
are **not** imported from Firefox — XPI add-ons don't have one-to-one
equivalents on the Chrome Web Store.

### What about Safari?

macOS only. Chromium reads Safari's `Bookmarks.plist`, `History.db`, and
`Keychain`-stored passwords. No extension import (Safari extensions are
AppKit apps, not cross-compatible).

## Running the flow manually

If you skip the first-run dialog (`--claum-skip-first-run-import`), you can
re-run it anytime:

- **mac**: `Menu bar → Claum → Import from another browser…`
- **win**: `⋮ menu → Import bookmarks and settings…`

Both menu items route to `chrome://settings/importData` with the same flow
described above.

## Privacy posture

- Imports happen entirely on-device. Nothing is sent to Claum servers
  (there are no Claum servers).
- The source profile files are read, not modified. You could import twice;
  it's idempotent for bookmarks + history (deduped by URL+title) and
  additive-only for passwords and cookies.
- If the user cancels mid-import, partial data may remain. They can wipe
  with `chrome://settings/clearBrowserData → All time → all categories`.
