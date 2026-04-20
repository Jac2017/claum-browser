// ================================================================
// GLASS BROWSER — SIDE PANEL LOGIC
//
// Handles: panel switching, vertical tabs, and Claude AI iframe.
// All JS must be in external files (Manifest V3 requirement).
// ================================================================


// ================================================================
// 1. PANEL SWITCHING — toggle between "Tabs" and "Claude"
// ================================================================

// Track whether we've loaded Claude yet (lazy-load on first click)
var claudeLoaded = false;

document.querySelectorAll('.nav-tab').forEach(function(tab) {
  tab.addEventListener('click', function() {
    // Remove "active" from all tabs and panels
    document.querySelectorAll('.nav-tab').forEach(function(t) {
      t.classList.remove('active');
    });
    document.querySelectorAll('.panel').forEach(function(p) {
      p.classList.remove('active');
    });
    // Add "active" to the one that was clicked
    tab.classList.add('active');
    document.getElementById(tab.dataset.panel).classList.add('active');

    // Lazy-load Claude: only set the iframe src the FIRST time
    // the user clicks the Claude tab. Loads claude.ai directly.
    //
    // NOTE: We tried embedding the Claude Chrome extension
    // (fcoeoabgfenejglbffodgkkbkcdhcgfn) but Chrome blocks
    // cross-extension iframing for security. Only the extension
    // itself can render its own pages. So we embed claude.ai
    // and provide a button to open the Claude extension separately.
    if (tab.dataset.panel === 'claude-panel' && !claudeLoaded) {
      var frame = document.getElementById('claudeFrame');
      if (frame) {
        // Pre-request microphone permission from the extension's origin
        if (navigator.mediaDevices && navigator.mediaDevices.getUserMedia) {
          navigator.mediaDevices.getUserMedia({ audio: true })
            .then(function(stream) {
              stream.getTracks().forEach(function(track) { track.stop(); });
            })
            .catch(function() { /* user can grant later */ });
        }

        frame.src = 'https://claude.ai/new';
        claudeLoaded = true;
      }
    }
  });
});


// ================================================================
// 2. VERTICAL TABS — shows all open Chrome tabs grouped by domain
// ================================================================

var GROUP_COLORS = [
  '#0a84ff', '#30d158', '#ff9f0a', '#ff453a',
  '#bf5af2', '#64d2ff', '#ff6482', '#ac8e68'
];

function faviconUrl(url) {
  try {
    return 'chrome-extension://' + chrome.runtime.id + '/_favicon/?pageUrl=' + encodeURIComponent(url) + '&size=32';
  } catch (e) {
    return '';
  }
}

function groupTabs(tabs) {
  var groups = {};
  tabs.forEach(function(tab) {
    try {
      var url = new URL(tab.url || '');
      var domain = url.hostname.replace('www.', '');
      if (!groups[domain]) groups[domain] = [];
      groups[domain].push(tab);
    } catch (e) {
      if (!groups['Other']) groups['Other'] = [];
      groups['Other'].push(tab);
    }
  });
  return groups;
}

function renderTabs(tabs, filter) {
  filter = filter || '';
  var container = document.getElementById('tabList');
  container.innerHTML = '';

  var filtered = tabs;
  if (filter) {
    var q = filter.toLowerCase();
    filtered = tabs.filter(function(t) {
      return (t.title || '').toLowerCase().includes(q) ||
             (t.url || '').toLowerCase().includes(q);
    });
  }

  var groups = groupTabs(filtered);
  var colorIndex = 0;

  var sorted = Object.entries(groups).sort(function(a, b) {
    return b[1].length - a[1].length;
  });

  sorted.forEach(function(entry) {
    var domain = entry[0];
    var domainTabs = entry[1];
    var color = GROUP_COLORS[colorIndex % GROUP_COLORS.length];
    colorIndex++;

    if (domainTabs.length > 1) {
      var header = document.createElement('div');
      header.className = 'group-header';
      header.innerHTML =
        '<svg class="chevron" width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><path d="M6 9l6 6 6-6"/></svg>' +
        '<span class="dot" style="background:' + color + '"></span>' +
        domain +
        '<span class="count">' + domainTabs.length + '</span>';

      var tabsDiv = document.createElement('div');
      tabsDiv.className = 'group-tabs';

      header.addEventListener('click', function() {
        header.classList.toggle('collapsed');
        tabsDiv.classList.toggle('hidden');
      });

      container.appendChild(header);
      domainTabs.forEach(function(tab) {
        tabsDiv.appendChild(createTabItem(tab));
      });
      container.appendChild(tabsDiv);
    } else {
      domainTabs.forEach(function(tab) {
        container.appendChild(createTabItem(tab));
      });
    }
  });
}

function createTabItem(tab) {
  var div = document.createElement('div');
  div.className = 'tab-item' + (tab.active ? ' active-tab' : '');

  // --- Build the tab item using DOM methods (NOT innerHTML) ---
  // SECURITY: Tab titles come from web pages and could contain
  // malicious HTML. Using textContent ensures they're safely escaped.

  // Favicon image
  var favicon = document.createElement('img');
  favicon.className = 'favicon';
  favicon.src = faviconUrl(tab.url);
  favicon.alt = '';
  div.appendChild(favicon);

  // Tab title (safely escaped via textContent)
  var titleSpan = document.createElement('span');
  titleSpan.className = 'tab-title';
  titleSpan.textContent = tab.title || 'New Tab';
  div.appendChild(titleSpan);

  // Pin icon (if pinned)
  if (tab.pinned) {
    var pin = document.createElement('span');
    pin.className = 'pin-icon';
    pin.textContent = '\uD83D\uDCCC';  // Pushpin emoji
    div.appendChild(pin);
  }

  // Close button
  var closeBtn = document.createElement('button');
  closeBtn.className = 'close-btn';
  closeBtn.title = 'Close tab';
  closeBtn.textContent = '\u00D7';  // × character
  div.appendChild(closeBtn);

  // Click to switch to this tab
  div.addEventListener('click', function(e) {
    if (e.target.classList.contains('close-btn')) return;
    chrome.tabs.update(tab.id, { active: true });
    chrome.windows.update(tab.windowId, { focused: true });
  });

  // Click close button to remove tab
  closeBtn.addEventListener('click', function(e) {
    e.stopPropagation();
    chrome.tabs.remove(tab.id);
  });

  return div;
}

function loadTabs() {
  chrome.tabs.query({}, function(tabs) {
    var filter = document.getElementById('tabSearch').value;
    renderTabs(tabs, filter);
  });
}

loadTabs();

// --- Debounce helper ---
// Prevents excessive re-renders when Chrome fires many rapid tab events.
// onUpdated fires for EVERY property change (title, favicon, URL, loading
// state) on EVERY tab, so without debounce we'd re-render dozens of times
// per second during page loads.
var _debounceTimer = null;
function debouncedLoadTabs() {
  clearTimeout(_debounceTimer);
  _debounceTimer = setTimeout(loadTabs, 150);  // Wait 150ms for events to settle
}

chrome.tabs.onCreated.addListener(debouncedLoadTabs);
chrome.tabs.onRemoved.addListener(debouncedLoadTabs);
chrome.tabs.onUpdated.addListener(debouncedLoadTabs);
chrome.tabs.onActivated.addListener(debouncedLoadTabs);

document.getElementById('tabSearch').addEventListener('input', debouncedLoadTabs);

document.getElementById('newTabBtn').addEventListener('click', function() {
  chrome.tabs.create({});
});


// ================================================================
// 3. CLAUDE POP-OUT — opens Claude in a full browser tab
// ================================================================
// Opens Claude's website in a full tab for unrestricted access
// (useful if the embedded extension panel has limitations).

var popoutBtn = document.getElementById('claudePopout');
if (popoutBtn) {
  popoutBtn.addEventListener('click', function() {
    // Open the Claude extension's page in a new tab.
    // Falls back to claude.ai if the extension page can't open in a tab.
    chrome.tabs.create({ url: 'https://claude.ai/new' });
  });
}
