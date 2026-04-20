// ================================================================
// GLASS BROWSER — OPTIONS PAGE LOGIC
//
// Handles: permission management, name customization, and
// launching Claude in a full tab for voice mode.
// ================================================================


// --- Name personalization ---
// Load the stored name into the input field
chrome.storage.local.get('userName', function(stored) {
  var input = document.getElementById('nameInput');
  if (stored.userName) {
    input.value = stored.userName;
  }
});

// Save button — stores the name and shows confirmation
document.getElementById('saveName').addEventListener('click', function() {
  var name = document.getElementById('nameInput').value.trim();
  if (name) {
    chrome.storage.local.set({ userName: name }, function() {
      var msg = document.getElementById('savedMsg');
      msg.classList.add('show');
      setTimeout(function() { msg.classList.remove('show'); }, 2000);
    });
  }
});


// --- Permission status checks ---
// Check microphone permission status
function checkMicPermission() {
  var statusEl = document.getElementById('micStatus');
  if (navigator.permissions && navigator.permissions.query) {
    navigator.permissions.query({ name: 'microphone' })
      .then(function(result) {
        updateStatus(statusEl, result.state);
        // Listen for changes (user might grant/deny while page is open)
        result.onchange = function() {
          updateStatus(statusEl, result.state);
        };
      })
      .catch(function() {
        statusEl.textContent = 'Unknown';
        statusEl.className = 'perm-status prompt';
      });
  } else {
    statusEl.textContent = 'Unknown';
    statusEl.className = 'perm-status prompt';
  }
}

// Check geolocation permission status
function checkLocPermission() {
  var statusEl = document.getElementById('locStatus');
  if (navigator.permissions && navigator.permissions.query) {
    navigator.permissions.query({ name: 'geolocation' })
      .then(function(result) {
        updateStatus(statusEl, result.state);
        result.onchange = function() {
          updateStatus(statusEl, result.state);
        };
      })
      .catch(function() {
        statusEl.textContent = 'Unknown';
        statusEl.className = 'perm-status prompt';
      });
  }
}

// Helper to update a status badge based on permission state
function updateStatus(el, state) {
  if (state === 'granted') {
    el.textContent = 'Granted';
    el.className = 'perm-status granted';
  } else if (state === 'denied') {
    el.textContent = 'Denied';
    el.className = 'perm-status denied';
  } else {
    el.textContent = 'Not yet granted';
    el.className = 'perm-status prompt';
  }
}

// Run checks on page load
checkMicPermission();
checkLocPermission();


// --- Grant buttons ---
// Microphone: triggers the browser's permission prompt
document.getElementById('grantMic').addEventListener('click', function() {
  if (navigator.mediaDevices && navigator.mediaDevices.getUserMedia) {
    navigator.mediaDevices.getUserMedia({ audio: true })
      .then(function(stream) {
        // Permission granted! Stop the stream immediately
        stream.getTracks().forEach(function(t) { t.stop(); });
        checkMicPermission();  // Refresh status display
      })
      .catch(function() {
        checkMicPermission();  // Refresh — might now show "denied"
      });
  }
});

// Location: triggers the browser's geolocation prompt
document.getElementById('grantLoc').addEventListener('click', function() {
  navigator.geolocation.getCurrentPosition(
    function() { checkLocPermission(); },   // Success — refresh status
    function() { checkLocPermission(); },   // Error — refresh anyway
    { timeout: 5000 }
  );
});


// --- Open Claude in full tab ---
// Voice mode works properly in a full tab where the page has
// direct microphone access (no iframe restrictions).
document.getElementById('openClaude').addEventListener('click', function() {
  chrome.tabs.create({ url: 'https://claude.ai/new' });
});
