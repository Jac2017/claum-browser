// ============================================================================
// Claude for Chrome — side panel UI logic (ES module)
// ----------------------------------------------------------------------------
// Keeps the chat history in memory (no persistence across sessions by design).
// Talks to background.js through chrome.runtime.sendMessage so all network I/O
// happens in the service worker (which has host_permissions for anthropic.com).
// ============================================================================

// -------- DOM refs ----------------------------------------------------------
const threadEl   = document.getElementById('thread');
const inputEl    = document.getElementById('composer-input');
const sendEl     = document.getElementById('composer-send');
const tabTitleEl = document.getElementById('tab-title');

// -------- Per-tab state -----------------------------------------------------
// Each tab gets its own thread. Map<tabId, Array<{role,content}>>.
const threadsByTab = new Map();
let currentTabId   = null;
let pageTextCache  = null; // Fetched lazily; reset on tab switch.

// -------- Track the active tab ---------------------------------------------

async function refreshActiveTab() {
  const [tab] = await chrome.tabs.query({
    active: true, currentWindow: true,
  });
  if (!tab) return;

  // If the tab changed, clear cached page text and rerender.
  if (currentTabId !== tab.id) {
    currentTabId  = tab.id;
    pageTextCache = null;
    renderThread();
  }
  tabTitleEl.textContent = tab.title || tab.url || '(untitled)';
}

// Listen for activeTab changes (user clicking a different tab in the strip).
chrome.tabs.onActivated.addListener(refreshActiveTab);
// And for URL changes within the current tab.
chrome.tabs.onUpdated.addListener((tabId, change) => {
  if (tabId === currentTabId && (change.title || change.url)) {
    refreshActiveTab();
  }
});

refreshActiveTab();

// -------- Render ------------------------------------------------------------

function renderThread() {
  const msgs = threadsByTab.get(currentTabId) || [];
  // Wipe everything except the welcome card (if no messages yet).
  threadEl.innerHTML = '';
  if (msgs.length === 0) {
    threadEl.appendChild(buildWelcome());
    return;
  }
  for (const m of msgs) {
    threadEl.appendChild(buildBubble(m));
  }
  threadEl.scrollTop = threadEl.scrollHeight;
}

function buildWelcome() {
  const div = document.createElement('div');
  div.className = 'welcome';
  div.innerHTML = `
    <h1>Ask Claude about this page</h1>
    <p>Try <kbd>Summarize</kbd>, <kbd>Explain the hard parts</kbd>,
       or paste in a question.</p>
    <div class="chips">
      <button data-prompt="Summarize this page in 5 bullets.">Summarize</button>
      <button data-prompt="What are the 3 most important points on this page?">Key points</button>
      <button data-prompt="Explain this page like I'm new to the topic.">Explain</button>
      <button data-prompt="What action items does this page imply for me?">Action items</button>
    </div>
  `;
  // Re-wire chip handlers every render.
  div.querySelectorAll('.chips button').forEach((b) => {
    b.addEventListener('click', () => send(b.dataset.prompt));
  });
  return div;
}

function buildBubble(msg) {
  const div = document.createElement('div');
  div.className = `msg ${msg.role}`;
  if (msg.role === 'assistant') {
    const meta = document.createElement('div');
    meta.className = 'meta';
    meta.textContent = 'Claude';
    div.appendChild(meta);
  }
  const body = document.createElement('div');
  body.textContent = msg.content;
  div.appendChild(body);
  return div;
}

// -------- Background-triggered actions --------------------------------------

chrome.runtime.onMessage.addListener((msg) => {
  // If the user hit Cmd+Shift+S or picked "Summarize this page" from the menu,
  // the background worker posts `claude:action`. Turn that into a normal send.
  if (msg.type !== 'claude:action') return;

  if (msg.action === 'summarize') {
    send('Summarize this page in 5 bullets.');
  } else if (msg.action === 'explain') {
    send(`Explain this in context of the page: "${msg.selection}"`);
  }
});

// -------- Send message ------------------------------------------------------

async function send(userText) {
  if (!userText?.trim()) return;

  // Lazy-fetch page text the first time we send in this tab.
  if (pageTextCache == null) {
    pageTextCache = await fetchPageText();
  }

  const history = threadsByTab.get(currentTabId) || [];
  history.push({ role: 'user', content: userText });
  threadsByTab.set(currentTabId, history);
  renderThread();

  sendEl.disabled = true;
  inputEl.value = '';

  try {
    // Build the messages array for the API.
    // We prepend a system-ish context message with the extracted page text,
    // but only send the real conversation history (user/assistant pairs).
    const messages = [];
    if (pageTextCache) {
      messages.push({
        role: 'user',
        content:
          `Here is the text of the page I'm reading. ` +
          `Use it only as context for my questions; don't summarize it ` +
          `until I explicitly ask.\n\n<page>\n${pageTextCache.slice(0, 60000)}\n</page>`,
      });
      messages.push({
        role: 'assistant',
        content: 'Got it. What would you like to know about this page?',
      });
    }
    for (const m of history) messages.push({ role: m.role, content: m.content });

    const resp = await chrome.runtime.sendMessage({
      type: 'claude:callAPI',
      messages,
      model: 'claude-sonnet-4-6',
    });

    if (!resp?.ok) throw new Error(resp?.error || 'unknown error');

    // Anthropic returns an array of content blocks; grab the text from all of them.
    const reply = (resp.data.content || [])
      .filter((b) => b.type === 'text')
      .map((b) => b.text)
      .join('\n\n');

    history.push({ role: 'assistant', content: reply || '(empty reply)' });
    threadsByTab.set(currentTabId, history);
    renderThread();
  } catch (err) {
    const errBubble = { role: 'error', content: `Error: ${err.message}` };
    // We render errors as a one-off bubble but DON'T store them in history
    // (so they don't re-send to the API next turn).
    renderThread();
    threadEl.appendChild(buildErrorBubble(err.message));
    threadEl.scrollTop = threadEl.scrollHeight;
  } finally {
    sendEl.disabled = false;
    inputEl.focus();
  }
}

function buildErrorBubble(msg) {
  const div = document.createElement('div');
  div.className = 'msg error';
  div.textContent = msg;
  return div;
}

// -------- Page text extraction via background -------------------------------

async function fetchPageText() {
  try {
    const resp = await chrome.runtime.sendMessage({
      type: 'claude:getPageText',
      tabId: currentTabId,
    });
    return resp?.ok ? (resp.text || '') : '';
  } catch {
    return '';
  }
}

// -------- Composer events ---------------------------------------------------

sendEl.addEventListener('click', () => send(inputEl.value));
inputEl.addEventListener('keydown', (e) => {
  // Enter sends, Shift+Enter inserts a newline.
  if (e.key === 'Enter' && !e.shiftKey) {
    e.preventDefault();
    send(inputEl.value);
  }
});

// Wire welcome-card chips on initial render.
renderThread();
