// ============================================================================
// Claude for Chrome — content script
// ----------------------------------------------------------------------------
// Runs in the page itself (NOT in the extension origin) so it can read the
// rendered DOM. Its only job is: when the background worker asks for the
// page's text, extract a clean readable version and send it back.
// ============================================================================

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg.type === 'claude:extractText') {
    // `true` return means "I'll respond asynchronously."
    try {
      const text = extractReadableText();
      sendResponse(text);
    } catch (err) {
      // Always reply — otherwise the sender's promise hangs.
      sendResponse('');
    }
    return true;
  }
});

// -------- Readable text extraction ------------------------------------------
// A tiny, dependency-free version of Mozilla's Readability algorithm:
//   1. Clone the DOM so we don't mutate the live page.
//   2. Remove noisy elements (scripts, nav, footer, aside, ads).
//   3. Score paragraphs by length; keep the densest subtree.
//   4. Join into plain text.
//
// Good enough for "summarize this page" use cases. Swap in Readability.js
// later if you want publisher-quality extraction.

function extractReadableText() {
  const clone = document.cloneNode(true);

  // Rip out obvious junk.
  const junk = clone.querySelectorAll(
    'script, style, noscript, iframe, svg, ' +
    'nav, header, footer, aside, form, ' +
    '[role="navigation"], [aria-hidden="true"], ' +
    '.ad, .ads, [class*="advert"], [id*="advert"]'
  );
  junk.forEach((n) => n.remove());

  // Score every paragraph-ish node by character count.
  const candidates = [...clone.querySelectorAll(
    'article, main, [role="main"], section, div, p'
  )];
  let best = null;
  let bestScore = 0;
  for (const node of candidates) {
    const txt = (node.innerText || '').trim();
    const score = txt.length;
    // Small bonus for semantic tags.
    const tag = node.tagName.toLowerCase();
    const bonus = tag === 'article' ? 200 : tag === 'main' ? 150 : 0;
    const total = score + bonus;
    if (total > bestScore) {
      best = node;
      bestScore = total;
    }
  }

  const root = best || clone.body;
  return (root.innerText || '').replace(/\n{3,}/g, '\n\n').trim();
}
