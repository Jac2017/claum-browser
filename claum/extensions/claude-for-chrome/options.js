// ============================================================================
// Claude for Chrome — options page
// ----------------------------------------------------------------------------
// Stores the user's API key + default model in chrome.storage.sync (syncs
// across Claum installs signed into the same browser account) and provides
// a one-click "test connection" button.
// ============================================================================

const keyEl    = document.getElementById('api-key');
const modelEl  = document.getElementById('model');
const saveEl   = document.getElementById('save');
const testEl   = document.getElementById('test');
const statusEl = document.getElementById('status');

// -------- load saved settings on page open ---------------------------------
chrome.storage.sync.get(['anthropicApiKey', 'defaultModel'], (cfg) => {
  if (cfg.anthropicApiKey) keyEl.value   = cfg.anthropicApiKey;
  if (cfg.defaultModel)    modelEl.value = cfg.defaultModel;
});

// -------- save -------------------------------------------------------------
saveEl.addEventListener('click', async () => {
  const anthropicApiKey = keyEl.value.trim();
  const defaultModel    = modelEl.value;

  if (anthropicApiKey && !anthropicApiKey.startsWith('sk-ant-')) {
    return setStatus('That doesn\u2019t look like an Anthropic key (should start with sk-ant-).', 'err');
  }

  await chrome.storage.sync.set({ anthropicApiKey, defaultModel });
  setStatus('Saved.', 'ok');
});

// -------- test connection --------------------------------------------------
testEl.addEventListener('click', async () => {
  setStatus('Testing\u2026', '');
  try {
    const resp = await chrome.runtime.sendMessage({
      type: 'claude:callAPI',
      model: modelEl.value,
      messages: [{ role: 'user', content: 'Say "pong" and nothing else.' }],
    });
    if (!resp?.ok) throw new Error(resp?.error || 'unknown');
    const text = (resp.data.content || [])
      .filter((b) => b.type === 'text').map((b) => b.text).join('');
    setStatus(`OK \u2014 Claude says: "${text.trim()}"`, 'ok');
  } catch (err) {
    setStatus(`Failed: ${err.message}`, 'err');
  }
});

function setStatus(text, cls) {
  statusEl.textContent = text;
  statusEl.className = 'status ' + (cls || '');
}
