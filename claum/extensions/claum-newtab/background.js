// ==========================================================================
// Glass Browser — Background Service Worker
//
// This runs in the background and handles:
//   1. Opening the side panel when the extension icon is clicked
//   2. Providing tab data to the side panel
// ==========================================================================

// When the user clicks the Glass Browser icon in the toolbar,
// open the side panel (vertical tabs + Claude AI)
chrome.action.onClicked.addListener((tab) => {
  chrome.sidePanel.open({ windowId: tab.windowId });
});

// Set the side panel to open automatically on install
chrome.runtime.onInstalled.addListener(() => {
  // Enable the side panel for all sites
  chrome.sidePanel.setOptions({
    enabled: true
  });
});

// ========================================================================
// MESSAGE HANDLER — listens for messages from the new tab page
//
// The new tab page sends messages here because background scripts have
// access to APIs that regular extension pages don't (like sending messages
// to other extensions, or using the management API).
// ========================================================================
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === 'open-claude-extension') {
    // Try to open the Claude Chrome extension.
    // The Claude extension ID: fcoeoabgfenejglbffodgkkbkcdhcgfn
    //
    // Strategy:
    //   1. Send a message to the Claude extension asking it to open
    //   2. If that fails, simulate clicking its action icon
    //   3. If that also fails, open claude.ai in a new tab
    const CLAUDE_EXT_ID = 'fcoeoabgfenejglbffodgkkbkcdhcgfn';

    // First, try sending a message to the Claude extension
    chrome.runtime.sendMessage(
      CLAUDE_EXT_ID,
      { type: 'open', action: 'openSidePanel' },
      (response) => {
        if (chrome.runtime.lastError) {
          // The Claude extension didn't respond to our message.
          // Fall back: try to find and click Claude's action, or open claude.ai
          chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
            if (tabs[0]) {
              // Try using keyboard shortcut to toggle Claude's side panel
              // Most extensions register Alt+Shift+C or similar
              // As a reliable fallback, just open claude.ai
              chrome.tabs.create({ url: 'https://claude.ai/new' });
            }
          });
        }
        sendResponse({ success: true });
      }
    );

    // Return true to indicate we'll call sendResponse asynchronously
    return true;
  }
});
