// ============================================================================
// Claude for Chrome — background service worker
// ----------------------------------------------------------------------------
// Responsibilities:
//   1. Open the side panel when the toolbar button is clicked.
//   2. Listen for keyboard commands (summarize, explain selection, etc.).
//   3. Wire up the context menu ("Ask Claude about this selection").
//   4. Forward messages between content script ↔ side panel
//      (content_script runs per-tab; sidepanel runs globally and needs a way
//       to reach whichever tab is active).
//
// Because this is an MV3 service worker, it can be suspended at any time.
// Keep all long-lived state in chrome.storage, not in module-level variables.
// ============================================================================

// -------- Install / first-launch setup ---------------------------------------

// Runs the first time the extension is loaded, and again on browser update.
chrome.runtime.onInstalled.addListener(async (details) => {
  // Create the right-click menu item on any selected text.
  chrome.contextMenus.create({
    id: 'claude-explain-selection',
    title: 'Ask Claude about "%s"',   // %s is replaced with the selected text
    contexts: ['selection'],
  });

  // Also an entry for the whole page.
  chrome.contextMenus.create({
    id: 'claude-summarize-page',
    title: 'Summarize this page with Claude',
    contexts: ['page'],
  });

  // If this is a fresh install (not a browser update), open the options page
  // so the user can drop in an API key or log into claude.ai.
  if (details.reason === 'install') {
    chrome.tabs.create({ url: chrome.runtime.getURL('options.html') });
  }
});

// -------- Side panel: open on action click -----------------------------------

// Tell Chromium to open the side panel whenever the toolbar button is clicked.
// Without this line, clicking the button does nothing because sidePanel is
// gated behind an explicit user gesture.
chrome.sidePanel
  .setPanelBehavior({ openPanelOnActionClick: true })
  .catch((err) => console.error('[claude] setPanelBehavior failed:', err));

// -------- Keyboard commands --------------------------------------------------

chrome.commands.onCommand.addListener(async (command) => {
  const [activeTab] = await chrome.tabs.query({
    active: true, currentWindow: true,
  });
  if (!activeTab) return;

  if (command === 'summarize-page') {
    // Post a message the side panel picks up to kick off a summary.
    await chrome.runtime.sendMessage({
      type: 'claude:action',
      action: 'summarize',
      tabId: activeTab.id,
      url:   activeTab.url,
      title: activeTab.title,
    });
    // And make sure the panel is actually open.
    await chrome.sidePanel.open({ tabId: activeTab.id });
  }
});

// -------- Context menu handlers ---------------------------------------------

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  if (!tab) return;

  if (info.menuItemId === 'claude-explain-selection') {
    await chrome.sidePanel.open({ tabId: tab.id });
    await chrome.runtime.sendMessage({
      type: 'claude:action',
      action: 'explain',
      selection: info.selectionText,
      tabId: tab.id,
      url: tab.url,
      title: tab.title,
    });
  } else if (info.menuItemId === 'claude-summarize-page') {
    await chrome.sidePanel.open({ tabId: tab.id });
    await chrome.runtime.sendMessage({
      type: 'claude:action',
      action: 'summarize',
      tabId: tab.id,
      url: tab.url,
      title: tab.title,
    });
  }
});

// -------- Message router ----------------------------------------------------
//
// The side panel asks us to fetch page text from the current tab; we forward
// to the content script. We also act as a relay for LLM API calls so the
// sidepanel.html doesn't need host_permissions for api.anthropic.com.

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  // Return true to keep the message channel open for async responses.
  if (msg.type === 'claude:getPageText') {
    chrome.tabs.sendMessage(msg.tabId, { type: 'claude:extractText' })
      .then((text) => sendResponse({ ok: true, text }))
      .catch((err)  => sendResponse({ ok: false, error: err?.message }));
    return true;
  }

  if (msg.type === 'claude:callAPI') {
    callAnthropic(msg.messages, msg.model)
      .then((data) => sendResponse({ ok: true, data }))
      .catch((err) => sendResponse({ ok: false, error: err?.message }));
    return true;
  }
});

// -------- Anthropic API helper ----------------------------------------------

async function callAnthropic(messages, model = 'claude-sonnet-4-6') {
  // We look up the key lazily — the user sets it in options.html.
  const { anthropicApiKey } = await chrome.storage.sync.get('anthropicApiKey');
  if (!anthropicApiKey) {
    throw new Error(
      'No Anthropic API key configured. ' +
      'Open the extension options and add one.'
    );
  }

  const resp = await fetch('https://api.anthropic.com/v1/messages', {
    method:  'POST',
    headers: {
      'content-type':      'application/json',
      'x-api-key':         anthropicApiKey,
      'anthropic-version': '2023-06-01',
      // This header lets the extension call the API directly from the browser.
      'anthropic-dangerous-direct-browser-access': 'true',
    },
    body: JSON.stringify({
      model:       model,
      max_tokens:  4096,
      messages:    messages,
    }),
  });

  if (!resp.ok) {
    const text = await resp.text();
    throw new Error(`Anthropic API ${resp.status}: ${text}`);
  }
  return resp.json();
}
