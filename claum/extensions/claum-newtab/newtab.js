// ================================================================
// GLASS BROWSER — NEW TAB PAGE LOGIC
//
// Manifest V3 requires all JS in external files (no inline scripts).
// This file handles:
//   1. Clock & greeting (personalized via Google account)
//   2. Search bar (Google)
//   3. Real Chrome bookmarks with pagination
//   4. Category-based news feed (For You, Local News, Sports, Money)
//   4b. Local News via geolocation + Google News RSS
//   5. YouTube recommendations (trending + personalized)
//   5b. Google Shopping — multiple "For You" sections
//   6. Background image rotation
//   7. Google account sign-in status
// ================================================================


// ================================================================
// UTILITY: Fetch with timeout
//
// Wraps fetch() with a timeout so hung requests don't block the
// entire feed loading pipeline. Defaults to 10 seconds.
// ================================================================
function fetchWithTimeout(url, options, timeoutMs) {
  timeoutMs = timeoutMs || 10000;  // Default 10 second timeout
  return new Promise(function(resolve, reject) {
    var timer = setTimeout(function() {
      reject(new Error('Fetch timeout after ' + timeoutMs + 'ms'));
    }, timeoutMs);

    fetch(url, options).then(function(response) {
      clearTimeout(timer);
      resolve(response);
    }).catch(function(err) {
      clearTimeout(timer);
      reject(err);
    });
  });
}


// ================================================================
// 1. CLOCK & GREETING — shows time, personalized with Google name
// ================================================================

// The user's display name, loaded from chrome.storage or Google account.
// Falls back to empty string (greeting says "Good morning" with no name).
var _userName = '';

// --- Fetch the user's REAL first name from their Google account ---
// Strategy (in order of reliability):
//   1. Check chrome.storage for a name the user set manually (options page)
//   2. Fetch google.com with cookies to get the actual account name
//   3. Fall back to deriving a name from the email prefix
chrome.storage.local.get('userName', function(stored) {
  if (stored.userName) {
    _userName = stored.userName;
    updateClock();
  }

  // Get the user's Google account email first
  if (chrome.identity && chrome.identity.getProfileUserInfo) {
    chrome.identity.getProfileUserInfo({ accountStatus: 'ANY' }, function(info) {
      if (info && info.email) {
        _userEmail = info.email;
        updateAccountIndicator();

        // Now try to get their REAL first name by fetching a Google
        // page with their session cookies. The extension has <all_urls>
        // permission, so it can fetch google.com with cookies included.
        // Google's homepage includes the user's display name in the
        // account button (aria-label="Google Account: First Last (email)")
        fetchWithTimeout('https://www.google.com', {
          credentials: 'include',
          headers: { 'Accept': 'text/html' }
        }, 8000)
        .then(function(r) { return r.text(); })
        .then(function(html) {
          // Pattern 1: aria-label on the account button
          // e.g. aria-label="Google Account: Matt Kenneway  &#10;(mkenneway@gmail.com)"
          var ariaMatch = html.match(
            /aria-label="Google Account[^"]*?:\s*([A-Za-z][A-Za-z\s'-]+?)[\s]*[\n(&#]/
          );
          if (ariaMatch && ariaMatch[1]) {
            var fullName = ariaMatch[1].trim();
            var firstName = fullName.split(/\s+/)[0];
            if (firstName && firstName.length > 1) {
              // Only update if we don't already have a manually-set name
              if (!stored.userName) {
                _userName = firstName;
                chrome.storage.local.set({ userName: firstName });
                updateClock();
              }
              return;  // Success — got the real name
            }
          }

          // Pattern 2: data-name attribute
          var dataMatch = html.match(/data-name="([^"]+)"/);
          if (dataMatch && dataMatch[1]) {
            var first = dataMatch[1].split(/\s+/)[0];
            if (first && first.length > 1 && !stored.userName) {
              _userName = first;
              chrome.storage.local.set({ userName: first });
              updateClock();
              return;
            }
          }

          // Pattern 3: og:title or similar containing the user name
          var ogMatch = html.match(/"displayName"\s*:\s*"([^"]+)"/);
          if (ogMatch && ogMatch[1]) {
            var first2 = ogMatch[1].split(/\s+/)[0];
            if (first2 && first2.length > 1 && !stored.userName) {
              _userName = first2;
              chrome.storage.local.set({ userName: first2 });
              updateClock();
              return;
            }
          }

          // All patterns failed — fall back to email-derived name
          deriveNameFromEmail(info.email, stored.userName);
        })
        .catch(function() {
          // Fetch failed — fall back to email-derived name
          deriveNameFromEmail(info.email, stored.userName);
        });
      }
    });
  }
});

// Fallback: derive a first name from the email prefix
// e.g. "matt.kenneway@gmail.com" → "Matt"
function deriveNameFromEmail(email, storedName) {
  if (storedName) return;  // Don't override manually-set name
  var prefix = email.split('@')[0];
  // Split on dots, underscores, plus signs — take the first part
  var namePart = prefix.split(/[._+]/)[0];
  // Remove any trailing numbers (like "matt123")
  namePart = namePart.replace(/\d+$/, '');
  if (namePart.length > 1) {
    var derived = namePart.charAt(0).toUpperCase() + namePart.slice(1).toLowerCase();
    _userName = derived;
    chrome.storage.local.set({ userName: derived });
    updateClock();
  }
}

function updateClock() {
  var now = new Date();
  var h = now.getHours();
  var ampm = h >= 12 ? 'PM' : 'AM';
  h = h % 12 || 12;
  var m = String(now.getMinutes()).padStart(2, '0');
  document.getElementById('clock').textContent = h + ':' + m + ' ' + ampm;

  var hour = now.getHours();
  var greet = 'Good evening';
  if (hour < 12) greet = 'Good morning';
  else if (hour < 17) greet = 'Good afternoon';

  // Personalize with user's name if we have it
  var greetingText = _userName ? greet + ', ' + _userName : greet;
  document.getElementById('greeting').textContent = greetingText;
}
updateClock();
setInterval(updateClock, 1000);


// ================================================================
// 2. SEARCH BAR — press Enter to search Google or navigate to a URL
// ================================================================

document.getElementById('searchInput').addEventListener('keydown', function(e) {
  if (e.key === 'Enter' && e.target.value.trim()) {
    var q = e.target.value.trim();
    // If it looks like a URL (has a dot, no spaces), navigate directly
    if (q.includes('.') && !q.includes(' ')) {
      window.location.href = q.startsWith('http') ? q : 'https://' + q;
    } else {
      // Otherwise search with Google
      window.location.href = 'https://www.google.com/search?q=' + encodeURIComponent(q);
    }
  }
});


// ================================================================
// 3. REAL BOOKMARKS — pulled from Chrome's bookmarks API
// ================================================================

var BOOKMARKS_PER_PAGE = 10;  // Tiles are compact so more fit per row
var bookmarkPage = 0;
var allBookmarks = [];

// Favicon helper — gets a site's icon via Chrome's built-in service
function faviconUrl(url) {
  try {
    return 'chrome-extension://' + chrome.runtime.id +
      '/_favicon/?pageUrl=' + encodeURIComponent(url) + '&size=32';
  } catch (e) {
    return '';
  }
}

// Recursively flatten the bookmark tree into a simple list
function flattenBookmarks(nodes) {
  var result = [];
  nodes.forEach(function(node) {
    if (node.url) result.push(node);
    if (node.children) result = result.concat(flattenBookmarks(node.children));
  });
  return result;
}

function renderBookmarkPage() {
  var container = document.getElementById('bookmarks');
  container.innerHTML = '';
  var start = bookmarkPage * BOOKMARKS_PER_PAGE;
  var end = start + BOOKMARKS_PER_PAGE;
  var pageBookmarks = allBookmarks.slice(start, end);
  var totalPages = Math.ceil(allBookmarks.length / BOOKMARKS_PER_PAGE);

  pageBookmarks.forEach(function(bm) {
    var a = document.createElement('a');
    a.className = 'bookmark';
    a.href = bm.url;

    // Show the full URL on hover so the user can see where the link goes
    a.title = bm.url;

    // Large favicon image — centered in the rounded rectangle
    var img = document.createElement('img');
    img.src = faviconUrl(bm.url);
    img.alt = '';
    a.appendChild(img);

    // Short label below the favicon — truncate long bookmark names
    var label = document.createElement('span');
    label.className = 'bm-label';
    var displayName = bm.title || 'Untitled';
    if (displayName.length > 10) displayName = displayName.substring(0, 9) + '…';
    label.textContent = displayName;
    a.appendChild(label);

    container.appendChild(a);
  });

  var indicator = document.getElementById('bookmarkPageIndicator');
  if (indicator && totalPages > 1) {
    indicator.textContent = (bookmarkPage + 1) + ' / ' + totalPages;
  } else if (indicator) {
    indicator.textContent = '';
  }
  var prevBtn = document.getElementById('bookmarkPrev');
  var nextBtn = document.getElementById('bookmarkNext');
  if (prevBtn) prevBtn.disabled = (bookmarkPage === 0);
  if (nextBtn) nextBtn.disabled = (bookmarkPage >= totalPages - 1);
}

function loadBookmarks() {
  chrome.bookmarks.getTree(function(tree) {
    allBookmarks = flattenBookmarks(tree);
    bookmarkPage = 0;
    renderBookmarkPage();
  });
}

document.getElementById('bookmarkPrev').addEventListener('click', function() {
  if (bookmarkPage > 0) { bookmarkPage--; renderBookmarkPage(); }
});
document.getElementById('bookmarkNext').addEventListener('click', function() {
  var totalPages = Math.ceil(allBookmarks.length / BOOKMARKS_PER_PAGE);
  if (bookmarkPage < totalPages - 1) { bookmarkPage++; renderBookmarkPage(); }
});

loadBookmarks();


// ================================================================
// 4. CATEGORY-BASED NEWS FEED
//
//    Organized like Google News with sections:
//    - Picks For You (BBC, CNN, NYT, Ars Technica — top stories mix)
//    - Local News (geo-detected city via Google News RSS search)
//    - Sports (ESPN top stories, NFL, NBA + NYT Sports)
//    - Money (BBC Business, CNN Money, NYT Business)
//
//    Each section fetches 2-3 RSS feeds in parallel, merges them,
//    sorts by date, and displays as a horizontal scrolling row
//    of glass cards with real thumbnail images.
//
//    YouTube recommendations are fetched separately and injected
//    as a "For You" section between the news categories.
// ================================================================


// --- FEED CATEGORIES ---
// Each category has a display name and an array of RSS feed configs.
// Each feed config knows how to extract the image from its XML format.
//
// User's requested layout:
//   1. Picks For You  — a mix of top stories from all major outlets
//   2. Local News     — regional / US-focused news feeds
//   3. Sports         — BBC Sport + NYT Sports
//   4. Money          — BBC Business, CNN Money, NYT Business
//
// (YouTube "For You" gets inserted after Picks For You)
// ("Continue Shopping" gets appended at the very end)

// --- Reusable image extractor functions ---
// BBC puts images in <media:thumbnail url="..."> (Yahoo MRSS namespace)
function bbcGetImage(item) {
  var els = item.getElementsByTagNameNS('http://search.yahoo.com/mrss/', 'thumbnail');
  if (els.length > 0) return (els[0].getAttribute('url') || '').replace('/240/', '/640/');
  return '';
}
// CNN & NYT put images in <media:content url="...">
function mediaContentGetImage(item) {
  var els = item.getElementsByTagNameNS('http://search.yahoo.com/mrss/', 'content');
  if (els.length > 0) return els[0].getAttribute('url') || '';
  return '';
}
// Google News RSS has no images — always returns empty
function googleNewsGetImage() { return ''; }


// ================================================================
// ESPN JSON API LOADER
//
// ESPN's RSS feeds have ZERO images per article — just plain text.
// But ESPN has a public JSON API that returns full article data
// including image URLs on a.espncdn.com.
//
// API pattern:
//   https://site.api.espn.com/apis/site/v2/sports/{sport}/{league}/news
//
// Each article in the response has:
//   - headline: string (article title)
//   - description: string
//   - images[0].url: full image URL (e.g., a.espncdn.com/photo/...)
//   - links.web.href: article URL on espn.com
//   - published: ISO date string
//
// We fetch NFL, NBA, and MLB news in parallel, merge and sort them.
// ================================================================

// ESPN API endpoints for the major US sports leagues
var ESPN_API_URLS = [
  { url: 'https://site.api.espn.com/apis/site/v2/sports/football/nfl/news?limit=8',
    league: 'NFL' },
  { url: 'https://site.api.espn.com/apis/site/v2/sports/basketball/nba/news?limit=8',
    league: 'NBA' },
  { url: 'https://site.api.espn.com/apis/site/v2/sports/baseball/mlb/news?limit=8',
    league: 'MLB' }
];

// Fetch one ESPN API endpoint and return article objects
function fetchEspnApi(config) {
  return fetch(config.url)
    .then(function(response) {
      if (!response.ok) throw new Error('HTTP ' + response.status);
      return response.json();
    })
    .then(function(data) {
      var articles = data.articles || [];
      return articles.map(function(article) {
        // Get the best image (first one is usually the main image)
        var image = '';
        if (article.images && article.images.length > 0) {
          image = article.images[0].url || '';
        }
        // Get the article link
        var link = '#';
        if (article.links && article.links.web) {
          link = article.links.web.href || '#';
        }
        // Parse the published date
        var pubDate = article.published || '';
        return {
          title: article.headline || 'Untitled',
          link: link,
          image: image,
          source: 'ESPN ' + config.league,
          sourceUrl: 'https://www.espn.com',
          time: timeAgo(pubDate),
          _date: pubDate ? new Date(pubDate) : new Date(0)
        };
      });
    })
    .catch(function(err) {
      console.warn('Glass: Failed to load ESPN ' + config.league + ':', err.message);
      return [];
    });
}

// Load all ESPN sports and return merged articles
function loadEspnSports() {
  var promises = ESPN_API_URLS.map(fetchEspnApi);
  return Promise.all(promises).then(function(results) {
    var all = [];
    results.forEach(function(arr) { all = all.concat(arr); });
    // Sort by date, newest first
    all.sort(function(a, b) { return b._date - a._date; });
    console.log('Glass: Loaded ' + all.length + ' ESPN articles with images');
    return all;
  });
}


// ================================================================
// GOOGLE NEWS "FOR YOU" LOADER
//
// Fetches the personalized Google News "For You" page and extracts
// articles from the embedded AF_initDataCallback JSON data.
//
// WHY NOT DOMParser:
// Google News embeds article data in a <script> tag as a
// JavaScript data callback: AF_initDataCallback({key:'ds:1', data:...})
// This contains article titles, REAL source URLs (nytimes.com, cnn.com),
// and image attachment paths. The DOM structure has /api/attachments/
// image URLs that only work with Google session cookies — they return
// 1x1 pixel placeholders from <img> tags on chrome-extension:// pages.
//
// SOLUTION:
// 1. Extract articles from AF_initDataCallback via regex:
//    Pattern: "TITLE",null,[TIMESTAMP],null,"SOURCE_URL",null,[["/attachments/PATH"
// 2. Build image URLs as news.google.com/api/attachments/... with -rw suffix
// 3. Use extension's fetch() (which CAN send cookies) to load each image
//    as a blob, then convert to object URLs that <img> can display
// 4. The actual article URLs point to the real source (WSJ, CNN, etc.)
//    not news.google.com/read/ redirects — much better for the user
// ================================================================

function loadGoogleNewsForYou() {
  return fetch('https://news.google.com/foryou?hl=en-US&gl=US&ceid=US:en', {
    headers: {
      'Accept': 'text/html',
      'Accept-Language': 'en-US,en;q=0.9'
    },
    credentials: 'include'   // Send cookies for personalized results
  })
  .then(function(response) {
    if (!response.ok) throw new Error('HTTP ' + response.status);
    return response.text();
  })
  .then(function(html) {
    var articles = [];

    // --- STRATEGY 1: Extract from AF_initDataCallback script ---
    // This gives us article titles, real source URLs, and image paths.
    // Data format per article:
    //   "TITLE",null,[TIMESTAMP],null,"SOURCE_URL",null,[["/attachments/IMAGE_PATH"
    var articleRegex = /"([^"]{20,200})",null,\[(\d+)\],null,"(https:\/\/[^"]+)",null,\[\["(\/attachments\/[^"]+)"/g;
    var match;
    var seen = {};

    while ((match = articleRegex.exec(html)) !== null && articles.length < 20) {
      var title = match[1];
      // Skip duplicate titles
      if (seen[title]) continue;
      seen[title] = true;

      // The timestamp is Unix-ish (seconds since some epoch)
      var timestamp = parseInt(match[2], 10);
      // Google News timestamps appear to be seconds
      var pubDate = new Date(timestamp * 1000);
      // Sanity check — if date is wildly wrong, use now
      if (pubDate.getFullYear() < 2020 || pubDate.getFullYear() > 2030) {
        pubDate = new Date();
      }

      // NOTE: We no longer use the /api/attachments/ image path here.
      // Those URLs need full Google session auth and return 1x1 pixels
      // from chrome-extension:// pages. Instead, we extract CDN image
      // URLs (lh3.googleusercontent.com) in a second pass below and
      // pair them with articles by text position.

      // Get the source domain name for display
      var sourceUrl = match[3];
      var sourceName = 'News';
      try {
        var urlObj = new URL(sourceUrl);
        sourceName = urlObj.hostname.replace(/^www\./, '');
        // Shorten common domains
        if (sourceName.includes('nytimes')) sourceName = 'NY Times';
        else if (sourceName.includes('cnn.com')) sourceName = 'CNN';
        else if (sourceName.includes('bbc.')) sourceName = 'BBC';
        else if (sourceName.includes('washingtonpost')) sourceName = 'Washington Post';
        else if (sourceName.includes('theguardian')) sourceName = 'The Guardian';
        else if (sourceName.includes('reuters')) sourceName = 'Reuters';
        else if (sourceName.includes('apnews')) sourceName = 'AP News';
      } catch (e) {}

      articles.push({
        title: title,
        link: sourceUrl,          // Direct link to the actual article!
        image: '',                // Will be filled by og:image fetch below
        source: sourceName,
        sourceUrl: sourceUrl,
        time: timeAgo(pubDate.toISOString()),
        _date: pubDate
      });
    }

    // --- STRATEGY 2: Fallback — parse DOM for article links ---
    // If AF_initDataCallback parsing didn't find articles, fall back
    // to DOMParser (images won't load but at least we get content)
    if (articles.length < 5) {
      var parser = new DOMParser();
      var doc = parser.parseFromString(html, 'text/html');
      var readLinks = doc.querySelectorAll('a[href*="/read/"]');

      readLinks.forEach(function(a) {
        var title = a.textContent.trim();
        if (title.length < 15 || seen[title]) return;
        seen[title] = true;

        var rawHref = a.getAttribute('href') || '';
        var href = rawHref.startsWith('http') ? rawHref :
          'https://news.google.com' + rawHref.replace(/^\./, '');

        // Find timestamp from nearby DOM
        var card = a;
        for (var d = 0; d < 10; d++) {
          if (!card.parentElement) break;
          card = card.parentElement;
          if (card.querySelector('time')) break;
        }
        var timeEl = card.querySelector('time');
        var datetime = timeEl ? (timeEl.getAttribute('datetime') || '') : '';

        articles.push({
          title: title,
          link: href,
          image: '',  // Can't load /api/attachments/ from extension page
          source: 'Google News',
          sourceUrl: 'https://news.google.com',
          time: timeAgo(datetime),
          _date: datetime ? new Date(datetime) : new Date(0)
        });
      });
    }

    articles.sort(function(a, b) { return b._date - a._date; });
    console.log('Glass: Loaded ' + articles.length + ' Google News For You articles');

    // --- Fetch og:image from each article's source URL ---
    // The Google News /api/attachments/ image URLs need full Google
    // session auth that chrome-extension:// pages can't provide.
    //
    // Instead, we fetch each article's ACTUAL source URL (e.g.
    // nytimes.com, cnn.com) and extract the og:image meta tag.
    // Almost every news site has og:image — it's the standard way
    // to provide a thumbnail for social media / link previews.
    //
    // This works because manifest.json has "<all_urls>" host_permissions,
    // which lets the extension's fetch() access any website.
    //
    // We limit to the first 12 articles to keep load times reasonable.
    // The cache system means this only runs every 15 minutes.

    var imagePromises = articles.slice(0, 12).map(function(article) {
      // Skip articles that already have a working image URL
      if (article.image && !article.image.includes('/api/attachments/')) {
        return Promise.resolve(article);
      }

      // Fetch the article's source page to find its og:image.
      // Use fetchWithTimeout (8s) so a slow news site doesn't
      // block the whole page from rendering.
      return fetchWithTimeout(article.link, {
        headers: { 'Accept': 'text/html' },
        credentials: 'omit',    // Don't send our cookies to random news sites
        redirect: 'follow'      // Follow redirects (Google News links often redirect)
      }, 8000)
      .then(function(response) {
        if (!response.ok) throw new Error('HTTP ' + response.status);
        return response.text();
      })
      .then(function(pageHtml) {
        // Parse the HTML and look for og:image meta tag
        // This is the universal standard for article thumbnails
        var ogMatch = pageHtml.match(
          /<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']/i
        );
        // Also try the reverse attribute order (content before property)
        if (!ogMatch) {
          ogMatch = pageHtml.match(
            /<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:image["']/i
          );
        }
        // Fallback: try twitter:image (many sites have both)
        if (!ogMatch) {
          ogMatch = pageHtml.match(
            /<meta[^>]+(?:name|property)=["']twitter:image["'][^>]+content=["']([^"']+)["']/i
          );
        }
        if (!ogMatch) {
          ogMatch = pageHtml.match(
            /<meta[^>]+content=["']([^"']+)["'][^>]+(?:name|property)=["']twitter:image["']/i
          );
        }

        if (ogMatch && ogMatch[1]) {
          // Got an image URL! Clean it up
          var imgUrl = ogMatch[1]
            .replace(/&amp;/g, '&')    // Decode HTML entities
            .trim();
          // Make sure it's an absolute URL
          if (imgUrl.startsWith('//')) {
            imgUrl = 'https:' + imgUrl;
          }
          article.image = imgUrl;
        } else {
          article.image = '';  // No og:image found, gradient placeholder
        }
        return article;
      })
      .catch(function() {
        // Fetch failed (CORS, network error, etc.)
        article.image = '';
        return article;
      });
    });

    // For articles beyond the first 12, just clear images (gradient placeholder)
    for (var extra = 12; extra < articles.length; extra++) {
      articles[extra].image = '';
    }

    return Promise.all(imagePromises).then(function(resolved) {
      // Merge resolved articles back into the full list
      for (var r = 0; r < resolved.length; r++) {
        articles[r] = resolved[r];
      }
      var withImages = articles.filter(function(a) { return a.image; }).length;
      console.log('Glass: ' + withImages + '/' + articles.length + ' For You articles have og:image thumbnails');
      return articles;
    });
  })
  .catch(function(err) {
    console.warn('Glass: Google News For You failed:', err.message);
    return [];
  });
}


// --- STATIC CATEGORIES (Sports, Money) ---
// "Picks For You" is now loaded from Google News (see above).
// Local News is handled separately below because it needs
// the user's geolocation to find their city.
var CATEGORIES = [
  // NOTE: "Picks For You" is no longer a static category.
  // It's loaded dynamically from Google News For You page.
  // Local News (index 0 after dynamic insert) is inserted by loadLocalNews().
  {
    // "Sports" — US-focused sports from ESPN JSON API + NYT Sports RSS.
    //
    // ESPN's RSS feeds have NO images at all, so we use their public
    // JSON API instead which returns full image URLs on a.espncdn.com.
    //
    // The API endpoints are:
    //   site.api.espn.com/apis/site/v2/sports/{sport}/{league}/news
    //
    // We set useEspnApi: true so the orchestrator knows to call
    // loadEspnSports() for this category instead of fetchAndParseFeed().
    // NYT Sports is still fetched via RSS (it has images).
    name: 'Sports',
    useEspnApi: true,
    feeds: [
      { url: 'https://rss.nytimes.com/services/xml/rss/nyt/Sports.xml',
        source: 'NY Times', siteUrl: 'https://www.nytimes.com',
        getImage: mediaContentGetImage }
    ]
  },
  {
    // "Money" — financial & business news
    name: 'Money',
    feeds: [
      { url: 'https://feeds.bbci.co.uk/news/business/rss.xml',
        source: 'BBC Business', siteUrl: 'https://www.bbc.com',
        getImage: bbcGetImage },
      { url: 'http://rss.cnn.com/rss/money_latest.rss',
        source: 'CNN Money', siteUrl: 'https://www.cnn.com',
        getImage: mediaContentGetImage },
      { url: 'https://rss.nytimes.com/services/xml/rss/nyt/Business.xml',
        source: 'NY Times', siteUrl: 'https://www.nytimes.com',
        getImage: mediaContentGetImage }
    ]
  }
];


// ================================================================
// 4b. LOCAL NEWS — uses geolocation to find your city, then
//     searches Google News RSS for stories about your area.
//
//     How it works:
//       1. navigator.geolocation.getCurrentPosition() → lat/lng
//       2. Reverse geocode via OpenStreetMap Nominatim → city name
//       3. Fetch Google News RSS search for that city
//       4. If any step fails, fall back to generic US news feeds
//
//     Google News RSS doesn't provide images, so local news cards
//     will show gradient placeholders. The trade-off is worth it
//     because the stories will be ACTUALLY local to the user.
// ================================================================

// Stores the user's detected city so we can show it in the header
var detectedCity = '';

// Step 1: Get the user's lat/lng from the browser
function getUserLocation() {
  return new Promise(function(resolve) {
    if (!navigator.geolocation) {
      console.warn('Glass: Geolocation not available');
      resolve(null);
      return;
    }
    navigator.geolocation.getCurrentPosition(
      function(position) {
        resolve({
          lat: position.coords.latitude,
          lng: position.coords.longitude
        });
      },
      function(err) {
        console.warn('Glass: Geolocation denied or failed:', err.message);
        resolve(null);
      },
      { timeout: 5000, maximumAge: 3600000 } // cache for 1 hour
    );
  });
}

// Step 2: Reverse geocode lat/lng → city name using OpenStreetMap
function reverseGeocode(lat, lng) {
  var url = 'https://nominatim.openstreetmap.org/reverse?lat=' +
    lat + '&lon=' + lng + '&format=json&zoom=10';
  return fetch(url, {
    headers: { 'Accept': 'application/json' }
  })
  .then(function(r) { return r.json(); })
  .then(function(data) {
    // Nominatim returns address components: city, town, village, county, state
    var addr = data.address || {};
    var city = addr.city || addr.town || addr.village || addr.county || '';
    var state = addr.state || '';
    console.log('Glass: Detected location — ' + city + ', ' + state);
    return { city: city, state: state };
  })
  .catch(function(err) {
    console.warn('Glass: Reverse geocode failed:', err.message);
    return null;
  });
}

// Step 3: Build the Local News category using detected location
// Returns a category object that can be inserted into CATEGORIES
function loadLocalNews() {
  return getUserLocation()
    .then(function(loc) {
      if (!loc) return null;
      return reverseGeocode(loc.lat, loc.lng);
    })
    .then(function(geo) {
      if (!geo || !geo.city) {
        console.log('Glass: Could not detect city, using fallback US news');
        return null;
      }
      detectedCity = geo.city;
      var searchTerm = geo.city + ' ' + geo.state;
      var googleNewsUrl = 'https://news.google.com/rss/search?q=' +
        encodeURIComponent(searchTerm) + '&hl=en-US&gl=US&ceid=US:en';

      return {
        name: 'Local News — ' + geo.city,
        feeds: [
          { url: googleNewsUrl,
            source: 'Google News',
            siteUrl: 'https://news.google.com',
            getImage: googleNewsGetImage }
        ]
      };
    })
    .catch(function() { return null; });
}

// Fallback Local News if geolocation fails — generic US news
var FALLBACK_LOCAL = {
  name: 'US News',
  feeds: [
    { url: 'http://rss.cnn.com/rss/cnn_us.rss',
      source: 'CNN US', siteUrl: 'https://www.cnn.com',
      getImage: mediaContentGetImage },
    { url: 'https://rss.nytimes.com/services/xml/rss/nyt/US.xml',
      source: 'NY Times US', siteUrl: 'https://www.nytimes.com',
      getImage: mediaContentGetImage }
  ]
};


// ----------------------------------------------------------------
// HELPER: "Time ago" — turns a date into "2h ago", "3d ago", etc.
// ----------------------------------------------------------------
function timeAgo(dateString) {
  try {
    var published = new Date(dateString);
    var now = new Date();
    var diffMins = Math.floor((now - published) / 60000);
    if (diffMins < 1) return 'just now';
    if (diffMins < 60) return diffMins + 'm ago';
    var diffHours = Math.floor(diffMins / 60);
    if (diffHours < 24) return diffHours + 'h ago';
    var diffDays = Math.floor(diffHours / 24);
    if (diffDays < 7) return diffDays + 'd ago';
    return published.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
  } catch (e) {
    return '';
  }
}


// ----------------------------------------------------------------
// HELPER: Gradient placeholders (when image missing or fails)
// ----------------------------------------------------------------
var PLACEHOLDER_GRADIENTS = [
  'linear-gradient(135deg, rgba(10,132,255,0.18), rgba(100,210,255,0.10))',
  'linear-gradient(135deg, rgba(191,90,242,0.18), rgba(255,100,130,0.10))',
  'linear-gradient(135deg, rgba(255,159,10,0.18), rgba(255,69,58,0.10))',
  'linear-gradient(135deg, rgba(48,209,88,0.18), rgba(10,132,255,0.10))',
  'linear-gradient(135deg, rgba(255,69,58,0.15), rgba(191,90,242,0.10))',
  'linear-gradient(135deg, rgba(100,210,255,0.18), rgba(48,209,88,0.10))',
];

function createPlaceholder(sourceName, gradientIndex) {
  var div = document.createElement('div');
  div.className = 'thumb-placeholder';
  div.style.background = PLACEHOLDER_GRADIENTS[gradientIndex % PLACEHOLDER_GRADIENTS.length];
  div.textContent = sourceName;
  return div;
}


// ----------------------------------------------------------------
// buildNewsCard — creates a single news article glass card
// Uses DOM methods (NOT innerHTML) to comply with Manifest V3 CSP
// ----------------------------------------------------------------
function buildNewsCard(article, index) {
  var card = document.createElement('a');
  card.className = 'feed-item glass-card';
  card.href = article.link;
  card.target = '_blank';
  card.rel = 'noopener';

  // --- Thumbnail ---
  if (article.image) {
    var img = document.createElement('img');
    img.className = 'thumb';
    img.alt = '';
    img.loading = 'lazy';
    img.referrerPolicy = 'no-referrer';
    img.addEventListener('error', function() {
      card.replaceChild(createPlaceholder(article.source, index), img);
    });
    img.src = article.image;
    card.appendChild(img);
  } else {
    card.appendChild(createPlaceholder(article.source, index));
  }

  // --- Info ---
  var info = document.createElement('div');
  info.className = 'info';

  var titleDiv = document.createElement('div');
  titleDiv.className = 'title';
  titleDiv.textContent = article.title;
  info.appendChild(titleDiv);

  var sourceRow = document.createElement('div');
  sourceRow.className = 'source-row';
  if (article.sourceUrl) {
    var icon = document.createElement('img');
    icon.src = faviconUrl(article.sourceUrl);
    icon.alt = '';
    icon.referrerPolicy = 'no-referrer';
    sourceRow.appendChild(icon);
  }
  sourceRow.appendChild(document.createTextNode(
    article.source + (article.time ? ' · ' + article.time : '')
  ));
  info.appendChild(sourceRow);
  card.appendChild(info);

  return card;
}


// ----------------------------------------------------------------
// buildYouTubeCard — creates a YouTube video glass card
// Has a red play button overlay on the thumbnail
// ----------------------------------------------------------------
function buildYouTubeCard(video, index) {
  var card = document.createElement('a');
  card.className = 'feed-item glass-card';
  card.href = video.link;
  card.target = '_blank';
  card.rel = 'noopener';

  // --- Thumbnail with play button overlay ---
  var thumbWrap = document.createElement('div');
  thumbWrap.className = 'thumb-wrap';

  var img = document.createElement('img');
  img.className = 'thumb';
  img.alt = '';
  img.loading = 'lazy';
  img.referrerPolicy = 'no-referrer';
  img.addEventListener('error', function() {
    thumbWrap.replaceChild(createPlaceholder('YouTube', index), img);
  });
  img.src = video.image;
  thumbWrap.appendChild(img);

  // Red play button circle
  var playOverlay = document.createElement('div');
  playOverlay.className = 'yt-play-overlay';
  // SVG play triangle
  var playSvg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  playSvg.setAttribute('viewBox', '0 0 24 24');
  var playPath = document.createElementNS('http://www.w3.org/2000/svg', 'path');
  playPath.setAttribute('d', 'M8 5v14l11-7z');
  playSvg.appendChild(playPath);
  playOverlay.appendChild(playSvg);
  thumbWrap.appendChild(playOverlay);

  card.appendChild(thumbWrap);

  // --- Info ---
  var info = document.createElement('div');
  info.className = 'info';

  var titleDiv = document.createElement('div');
  titleDiv.className = 'title';
  titleDiv.textContent = video.title;
  info.appendChild(titleDiv);

  var sourceRow = document.createElement('div');
  sourceRow.className = 'source-row';
  // YouTube favicon
  var ytIcon = document.createElement('img');
  ytIcon.src = faviconUrl('https://www.youtube.com');
  ytIcon.alt = '';
  sourceRow.appendChild(ytIcon);
  sourceRow.appendChild(document.createTextNode(
    video.channel + (video.views ? ' · ' + video.views : '')
  ));
  info.appendChild(sourceRow);
  card.appendChild(info);

  return card;
}


// ----------------------------------------------------------------
// fetchAndParseFeed — fetches one RSS feed and extracts articles
// Returns a Promise resolving to an array of article objects.
// If a feed fails, it returns [] so the others still work.
// ----------------------------------------------------------------
function fetchAndParseFeed(feedConfig) {
  return fetch(feedConfig.url)
    .then(function(response) {
      if (!response.ok) throw new Error('HTTP ' + response.status);
      return response.text();
    })
    .then(function(xmlText) {
      var parser = new DOMParser();
      var xml = parser.parseFromString(xmlText, 'text/xml');
      if (xml.querySelector('parsererror')) throw new Error('XML parse error');

      var items = xml.querySelectorAll('item');
      var articles = [];

      for (var i = 0; i < Math.min(items.length, 10); i++) {
        var item = items[i];
        var title = item.querySelector('title')
          ? item.querySelector('title').textContent.trim() : 'Untitled';
        var link = item.querySelector('link')
          ? item.querySelector('link').textContent.trim() : '#';
        var pubDate = item.querySelector('pubDate')
          ? item.querySelector('pubDate').textContent : '';
        var image = feedConfig.getImage(item);

        // --- Google News RSS fix ---
        // ALL Google News RSS links (not just /rss/articles) are redirect
        // URLs that don't resolve properly via fetch(). This includes:
        //   - news.google.com/rss/articles/CBMi...  (topic feeds)
        //   - news.google.com/stories/...            (story clusters)
        //   - news.google.com/read/...               (search results)
        //   - Any other news.google.com path
        // The REAL article URL is inside the <description> HTML as an
        // <a href="...">. We extract it so we link to the actual article
        // AND can fetch its og:image correctly for thumbnails.
        if (link.includes('news.google.com')) {
          var desc = item.querySelector('description');
          if (desc) {
            var descHtml = desc.textContent || '';
            // Look for the FIRST real URL in the description HTML
            var hrefMatch = descHtml.match(/href="(https?:\/\/(?!news\.google\.com)[^"]+)"/);
            if (hrefMatch && hrefMatch[1]) {
              link = hrefMatch[1];  // Use the real article URL
            }
          }
          // Also try the <source url="..."> attribute as fallback
          // (contains the publisher's homepage, helpful for source name)
          if (link.includes('news.google.com')) {
            // Still a Google redirect — try source element
            var sourceEl = item.querySelector('source');
            if (sourceEl) {
              var sourceUrl = sourceEl.getAttribute('url');
              if (sourceUrl && sourceUrl.startsWith('http')) {
                // This is the publisher homepage, not the article,
                // but it's better than a broken redirect for og:image
                link = sourceUrl;
              }
            }
          }
        }

        articles.push({
          title: title,
          link: link,
          image: image,
          source: feedConfig.source,
          sourceUrl: feedConfig.siteUrl,
          time: timeAgo(pubDate),
          _date: pubDate ? new Date(pubDate) : new Date(0)
        });
      }

      // --- Fetch og:image for articles that have no image ---
      // Google News RSS and some other feeds don't include images.
      // We fetch each article's source page and extract og:image,
      // just like we do for the "For You" section. Limit to first
      // 8 articles to keep it fast.
      var needsImages = articles.filter(function(a) { return !a.image; });
      if (needsImages.length === 0) return articles;

      var ogPromises = needsImages.slice(0, 8).map(function(article) {
        return fetchWithTimeout(article.link, {
          headers: { 'Accept': 'text/html' },
          credentials: 'omit',
          redirect: 'follow'
        }, 6000)
        .then(function(r) {
          if (!r.ok) throw new Error('HTTP ' + r.status);
          return r.text();
        })
        .then(function(html) {
          // Look for og:image meta tag (standard for article thumbnails)
          var ogMatch = html.match(
            /<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']/i
          );
          if (!ogMatch) {
            ogMatch = html.match(
              /<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:image["']/i
            );
          }
          // Fallback: twitter:image
          if (!ogMatch) {
            ogMatch = html.match(
              /<meta[^>]+(?:name|property)=["']twitter:image["'][^>]+content=["']([^"']+)["']/i
            );
          }
          if (!ogMatch) {
            ogMatch = html.match(
              /<meta[^>]+content=["']([^"']+)["'][^>]+(?:name|property)=["']twitter:image["']/i
            );
          }
          if (ogMatch && ogMatch[1]) {
            var imgUrl = ogMatch[1].replace(/&amp;/g, '&').trim();
            if (imgUrl.startsWith('//')) imgUrl = 'https:' + imgUrl;
            article.image = imgUrl;
          }
        })
        .catch(function() {
          // Failed — article keeps gradient placeholder
        });
      });

      return Promise.all(ogPromises).then(function() {
        return articles;
      });
    })
    .catch(function(err) {
      console.warn('Glass: Failed to load ' + feedConfig.source + ':', err.message);
      return [];
    });
}


// ----------------------------------------------------------------
// loadCategoryFeeds — the main orchestrator that loads everything
//
// Fetches in parallel:
//   - All news categories (For You, Local, Sports, Money)
//   - YouTube recommendations
//   - Google Shopping (multiple sections)
//
// Then renders them all in order with deduplication.
// ----------------------------------------------------------------
function loadCategoryFeeds() {
  var container = document.getElementById('feedSections');

  // ===================================================================
  // CACHE SYSTEM — instant load from cache, then refresh in background
  //
  // On every new tab open:
  //   1. Check chrome.storage.local for cached feed data
  //   2. If cache exists and is < 15 min old, render it IMMEDIATELY
  //   3. Fetch fresh data in the background regardless
  //   4. When fresh data arrives, re-render and update cache
  //
  // This makes new tab opens feel instant while keeping data fresh.
  // ===================================================================

  // Try to render from cache first (instant load)
  chrome.storage.local.get('feedCache', function(stored) {
    var cache = stored.feedCache;
    var CACHE_MAX_AGE = 15 * 60 * 1000; // 15 minutes in milliseconds

    if (cache && cache.timestamp && (Date.now() - cache.timestamp < CACHE_MAX_AGE)) {
      // Cache is fresh enough — render it immediately!
      console.log('Glass: Rendering from cache (age: ' +
        Math.round((Date.now() - cache.timestamp) / 60000) + 'm)');
      renderAllSections(container, cache.data);
    }

    // Always fetch fresh data in the background
    fetchAllFreshData().then(function(freshData) {
      console.log('Glass: Fresh data loaded, updating display');
      renderAllSections(container, freshData);

      // Save to cache for next time.
      // NOTE: blob: URLs (from Google News images) can't be stored in
      // chrome.storage, so we strip them. On next load, the cached
      // articles will show gradient placeholders until fresh data arrives.
      // This is acceptable since the cache load is instant and fresh
      // data with real images follows within a few seconds.
      var cacheData = JSON.parse(JSON.stringify(freshData, function(key, val) {
        // Strip blob: URLs — they won't work across sessions
        if (typeof val === 'string' && val.startsWith('blob:')) return '';
        // Strip internal fields starting with _
        if (key.startsWith('_')) return undefined;
        return val;
      }));
      chrome.storage.local.set({
        feedCache: { timestamp: Date.now(), data: cacheData }
      });
    }).catch(function(err) {
      console.error('Glass: Feed loading error:', err);
      // Only show error message if we didn't already render from cache
      if (!cache || !cache.timestamp) {
        container.innerHTML =
          '<div style="color:rgba(255,255,255,0.4); text-align:center; padding:32px;">' +
          'Unable to load news feed. Check your connection and reload.</div>';
      }
    });
  });
}


// ----------------------------------------------------------------
// fetchAllFreshData — fetches ALL feed data from the network
//
// Returns a promise that resolves to an object containing:
//   - forYou: articles from Google News For You
//   - categories: array of { name, articles } for Local/Sports/Money
//   - youtube: YouTube video objects
//   - shopping: array of { title, products }
// ----------------------------------------------------------------
function fetchAllFreshData() {
  // --- Step 1: Get Local News category (needs geolocation) ---
  var localPromise = loadLocalNews().then(function(localCategory) {
    // Build the list of RSS-based categories:
    // Local News, Sports, Money (Picks For You is now from Google News)
    var allCategories = [];
    allCategories.push(localCategory || FALLBACK_LOCAL); // Local News
    // Add Sports and Money from CATEGORIES array
    for (var c = 0; c < CATEGORIES.length; c++) {
      allCategories.push(CATEGORIES[c]);
    }
    return allCategories;
  });

  // --- Step 2: Fetch RSS categories (with ESPN API for Sports) ---
  var categoryPromise = localPromise.then(function(allCategories) {
    var categoryPromises = allCategories.map(function(category) {
      // Fetch all RSS feeds for this category
      var feedPromises = category.feeds.map(fetchAndParseFeed);

      // If this category uses ESPN API (Sports), fetch ESPN articles
      // in parallel with the RSS feeds, then merge them together
      if (category.useEspnApi) {
        feedPromises.push(loadEspnSports());
      }

      return Promise.all(feedPromises).then(function(results) {
        var all = [];
        results.forEach(function(arr) { all = all.concat(arr); });
        all.sort(function(a, b) { return b._date - a._date; });
        // Put articles WITH images before those without
        var withImg = all.filter(function(a) { return a.image; });
        var noImg = all.filter(function(a) { return !a.image; });
        return { name: category.name, articles: withImg.concat(noImg) };
      });
    });
    return Promise.all(categoryPromises);
  });

  // --- Step 3: Fetch everything else in parallel ---
  var forYouPromise = loadGoogleNewsForYou();
  var ytPromise = loadYouTubeVideos();
  var shoppingPromise = loadGoogleShoppingSections();

  // --- Step 4: Combine all results into one data object ---
  return Promise.all([
    forYouPromise, categoryPromise, ytPromise, shoppingPromise
  ]).then(function(results) {
    return {
      forYou: results[0] || [],
      categories: results[1] || [],
      youtube: results[2] || [],
      shopping: results[3] || []
    };
  });
}


// ----------------------------------------------------------------
// renderAllSections — takes a data object and renders the full page
//
// Can be called with cached data (instant) or fresh data (update).
// Clears the container and re-renders everything in order.
// ----------------------------------------------------------------
function renderAllSections(container, data) {
  // Build all content into a DocumentFragment first, then swap it
  // into the container in ONE operation. This prevents the visual
  // flash that happens if we clear the container before rebuilding.
  var frag = document.createDocumentFragment();

  // --- DEDUPLICATION across all sections ---
  var seenUrls = {};
  var seenTitles = {};

  function dedup(articles) {
    var unique = [];
    articles.forEach(function(article) {
      var url = article.link;
      var normTitle = article.title.toLowerCase()
        .replace(/[^a-z0-9\s]/g, '').trim().substring(0, 50);
      if (seenUrls[url] || seenTitles[normTitle]) return;
      seenUrls[url] = true;
      seenTitles[normTitle] = true;
      unique.push(article);
    });
    return unique;
  }

  // --- RENDER ORDER ---
  // 1. For You (from Google News personalized feed)
  // 2. YouTube — For You
  // 3. Local News
  // 4. Sports
  // 5. Money
  // 6. Continue Shopping (first shopping section)
  // 7+ Additional Shopping sections

  // 1. For You — personalized Google News articles
  if (data.forYou && data.forYou.length > 0) {
    frag.appendChild(
      buildSection('For You', dedup(data.forYou), false)
    );
  }

  // 2. YouTube "For You"
  if (data.youtube && data.youtube.length > 0) {
    frag.appendChild(
      buildSection('YouTube — For You', data.youtube, true)
    );
  }

  // 3-5. RSS categories (Local News, Sports, Money)
  var categories = data.categories || [];
  for (var i = 0; i < categories.length; i++) {
    if (categories[i].articles.length > 0) {
      var dedupedArticles = dedup(categories[i].articles);
      if (dedupedArticles.length > 0) {
        frag.appendChild(
          buildSection(categories[i].name, dedupedArticles, false)
        );
      }
    }
  }

  // 6. Continue Shopping (first shopping section)
  var shopSections = data.shopping || [];
  if (shopSections.length > 0 && shopSections[0].products.length > 0) {
    frag.appendChild(
      buildShoppingSection(shopSections[0].title, shopSections[0].products)
    );
  }

  // 7+. Additional Shopping sections
  for (var s = 1; s < shopSections.length; s++) {
    if (shopSections[s].products.length > 0) {
      frag.appendChild(
        buildShoppingSection(shopSections[s].title, shopSections[s].products)
      );
    }
  }

  // Swap in all content at once — no flash!
  container.innerHTML = '';
  container.appendChild(frag);

  // --- INSERT AD UNITS between sections ---
  // After the DOM is built, inject ad iframes between feed sections.
  // We use a slight delay to ensure the sections are rendered first.
  setTimeout(function() { insertAdUnits(container); }, 100);

  console.log('Glass: Rendered all feed sections');
}


// ----------------------------------------------------------------
// AD INSERTION — places AdSense multiplex ads into the feed
//
// Ad units are inserted:
//   1. Between major feed sections (every 2 sections)
//   2. As an ad card inside article scroll rows (every 4th card)
//
// Publisher ID: ca-pub-5280081052346805
// Ad slot IDs need to be created in your AdSense dashboard.
// Replace the placeholder slot IDs below with your real ones.
//
// HOW TO GET SLOT IDs:
//   1. Go to https://adsense.google.com
//   2. Click "Ad units" → "By ad unit"
//   3. Create a "Multiplex ad" unit
//   4. Copy the data-ad-slot value
//   5. Paste it into the AD_SLOT_IDS object below
// ----------------------------------------------------------------

// --- YOUR AD SLOT IDs ---
// Replace these empty strings with real slot IDs from your AdSense account.
// Create different ad units for each placement so you can track performance.
var AD_SLOT_IDS = {
  betweenSections: '6457197369',    // Multiplex ad between feed sections
  inFeedCard: '3831034024'          // Smaller ad card inside article rows
};

// Build an ad iframe element that loads the sandboxed ad page
function createAdIframe(slotId, format, width, height) {
  var iframe = document.createElement('iframe');

  // Build the URL with config in the hash (sandboxed pages
  // can't receive postMessage from the parent easily, so
  // we pass config via the URL hash instead)
  var params = 'slot=' + encodeURIComponent(slotId) +
               '&format=' + encodeURIComponent(format || 'autorelaxed');
  if (width) params += '&width=' + width;
  if (height) params += '&height=' + height;

  iframe.src = 'ads/ad-frame.html#' + params;
  iframe.setAttribute('scrolling', 'no');

  // The sandbox attribute is required for sandboxed pages.
  // allow-scripts lets the AdSense JS run inside the frame.
  // allow-popups lets ad clicks open in new tabs.
  iframe.setAttribute('sandbox', 'allow-scripts allow-popups allow-popups-to-escape-sandbox');

  return iframe;
}

// Insert ad units into the feed
function insertAdUnits(container) {
  var sections = container.querySelectorAll('.feed-section');
  if (sections.length < 2) return;  // Not enough sections for ads

  var adCount = 0;

  // --- 1. BETWEEN-SECTION ADS ---
  // Insert a multiplex ad after every 2nd section
  for (var i = 1; i < sections.length; i += 2) {
    // Create the ad container
    var adLabel = document.createElement('div');
    adLabel.className = 'ad-label';
    adLabel.textContent = 'Sponsored';

    var adUnit = document.createElement('div');
    adUnit.className = 'ad-unit';
    adUnit.appendChild(
      createAdIframe(AD_SLOT_IDS.betweenSections, 'autorelaxed')
    );

    // Insert AFTER the current section
    var nextSibling = sections[i].nextSibling;
    if (nextSibling) {
      container.insertBefore(adLabel, nextSibling);
      container.insertBefore(adUnit, adLabel.nextSibling);
    } else {
      container.appendChild(adLabel);
      container.appendChild(adUnit);
    }
    adCount++;
  }

  // --- 2. IN-ROW AD CARDS ---
  // Insert an ad card into each section's horizontal scroll row.
  // The ad card sits after the 3rd article card.
  sections.forEach(function(section) {
    var scrollRow = section.querySelector('.scroll-row, .card-row');
    if (!scrollRow) return;

    var cards = scrollRow.querySelectorAll('.glass-card, .yt-card, .shop-card');
    if (cards.length < 4) return;  // Not enough cards to insert between

    // Create an ad card that matches the article card dimensions
    var adCard = document.createElement('div');
    adCard.className = 'ad-card-unit';
    adCard.appendChild(
      createAdIframe(AD_SLOT_IDS.inFeedCard, 'fluid', 260, 300)
    );

    // Insert after the 3rd card
    var insertAfter = cards[2];
    if (insertAfter && insertAfter.nextSibling) {
      scrollRow.insertBefore(adCard, insertAfter.nextSibling);
    } else {
      scrollRow.appendChild(adCard);
    }
  });

  console.log('Glass: Inserted ' + adCount + ' between-section ads + in-row ad cards');
}

// --- AD LOAD LISTENER ---
// Ad containers are HIDDEN by default (display:none in CSS).
// The sandboxed ad-frame.html posts an 'ad-loaded' message when
// AdSense successfully fills a slot. This listener catches those
// messages and un-hides the matching container + label.
// If AdSense never fills (account not set up, no inventory, etc.),
// the containers simply stay hidden — no blank gaps.
window.addEventListener('message', function(event) {
  if (!event.data || event.data.type !== 'ad-loaded') return;
  if (!event.data.success) return;  // Ad didn't fill — stay hidden

  // Find the iframe that sent this message so we can show its container
  var allIframes = document.querySelectorAll('.ad-unit iframe, .ad-card-unit iframe');
  allIframes.forEach(function(iframe) {
    try {
      if (iframe.contentWindow === event.source) {
        // This is the iframe that loaded an ad — show its parent container
        var container = iframe.closest('.ad-unit, .ad-card-unit');
        if (container) {
          container.classList.add('ad-loaded');
          // Also show the "Sponsored" label if it's a between-section ad
          var prev = container.previousElementSibling;
          if (prev && prev.classList.contains('ad-label')) {
            prev.classList.add('ad-loaded');
          }
        }
      }
    } catch (e) { /* cross-origin check — ignore */ }
  });
});


// ----------------------------------------------------------------
// buildSection — creates a complete category section DOM element
//
// Each section has:
//   - A header (e.g., "Top Stories")
//   - A horizontally scrolling row of glass cards
// ----------------------------------------------------------------
function buildSection(name, articles, isYouTube) {
  var section = document.createElement('div');
  section.className = 'feed-section';

  // --- Section header ---
  var header = document.createElement('div');
  header.className = 'section-header';
  var h2 = document.createElement('h2');
  h2.textContent = name;
  header.appendChild(h2);
  section.appendChild(header);

  // --- Horizontal scroll row of cards ---
  var row = document.createElement('div');
  row.className = 'feed-row';

  articles.forEach(function(article, i) {
    if (isYouTube) {
      row.appendChild(buildYouTubeCard(article, i));
    } else {
      row.appendChild(buildNewsCard(article, i));
    }
  });

  section.appendChild(row);
  return section;
}


// ================================================================
// 5. YOUTUBE RECOMMENDATIONS
//
//    We fetch the YouTube homepage HTML and extract video data from
//    the embedded ytInitialData JSON object. This gives us:
//    - Video titles, IDs, and thumbnails
//    - Channel names
//    - View counts
//
//    YouTube thumbnails follow a predictable URL pattern:
//      https://i.ytimg.com/vi/VIDEO_ID/mqdefault.jpg
//
//    Because this is a Chrome extension with host_permissions for
//    youtube.com, the fetch sends the user's cookies automatically,
//    so we get PERSONALIZED recommendations (if logged in) plus
//    trending content.
// ================================================================

function loadYouTubeVideos() {
  return fetch('https://www.youtube.com/', {
    headers: {
      'Accept': 'text/html',
      'Accept-Language': 'en-US,en;q=0.9'
    },
    credentials: 'include'   // Send cookies for personalized results
  })
  .then(function(response) {
    if (!response.ok) throw new Error('HTTP ' + response.status);
    return response.text();
  })
  .then(function(html) {
    // YouTube embeds a huge JSON object called "ytInitialData" in a
    // <script> tag. It contains all the video data for the homepage.
    // We extract it with a regex, then parse it as JSON.
    var match = html.match(/var\s+ytInitialData\s*=\s*(\{.+?\});\s*<\/script>/s);
    if (!match) {
      // Try alternate pattern (YouTube sometimes uses different formats)
      match = html.match(/ytInitialData"\s*:\s*(\{.+?\})\s*[,;]/s);
    }
    if (!match) {
      console.warn('Glass: Could not find ytInitialData in YouTube page');
      return [];
    }

    var data;
    try {
      data = JSON.parse(match[1]);
    } catch (e) {
      console.warn('Glass: Failed to parse ytInitialData JSON:', e.message);
      return [];
    }

    // Navigate YouTube's deeply nested data structure to find videos.
    //
    // YouTube's homepage JSON is organized as:
    //   contents → twoColumnBrowseResultsRenderer → tabs[0]
    //     → tabRenderer → content → richGridRenderer → contents[]
    //
    // Each item in contents[] is either:
    //   - richItemRenderer → content → lockupViewModel (a video)
    //   - richSectionRenderer (a shelf/category — may contain videos)
    //
    // The lockupViewModel format (YouTube's CURRENT format as of 2026):
    //   - contentId = the video ID
    //   - contentType = "LOCKUP_CONTENT_TYPE_VIDEO"
    //   - metadata.lockupMetadataViewModel.title.content = video title
    //   - metadata...metadataRows[0].metadataParts[0].text.content = channel
    //   - metadata...metadataRows[1].metadataParts[0].text.content = views
    //
    // NOTE: YouTube previously used "videoRenderer" but changed to
    // "lockupViewModel" in 2025-2026. If they change again, this
    // code will need updating.
    var videos = [];
    try {
      var tabs = data.contents.twoColumnBrowseResultsRenderer.tabs;
      var tabContent = tabs[0].tabRenderer.content;
      var richGrid = tabContent.richGridRenderer;
      if (!richGrid) throw new Error('No richGridRenderer');

      var gridContents = richGrid.contents || [];

      gridContents.forEach(function(item) {
        // --- NEW FORMAT: lockupViewModel ---
        if (item.richItemRenderer &&
            item.richItemRenderer.content &&
            item.richItemRenderer.content.lockupViewModel) {

          var lvm = item.richItemRenderer.content.lockupViewModel;

          // Only process actual videos (not playlists, channels, etc.)
          if (lvm.contentType !== 'LOCKUP_CONTENT_TYPE_VIDEO') return;

          var videoId = lvm.contentId;
          if (!videoId) return;

          // Extract title from lockupMetadataViewModel
          var title = '';
          try {
            title = lvm.metadata.lockupMetadataViewModel.title.content;
          } catch (e) {}

          // Extract channel name and view count from metadata rows
          var channel = '';
          var viewText = '';
          try {
            var rows = lvm.metadata.lockupMetadataViewModel
              .metadata.contentMetadataViewModel.metadataRows;
            // Row 0 = channel name
            if (rows[0] && rows[0].metadataParts[0]) {
              channel = rows[0].metadataParts[0].text.content;
            }
            // Row 1 = view count (and optionally upload time)
            if (rows[1] && rows[1].metadataParts[0]) {
              viewText = rows[1].metadataParts[0].text.content;
            }
          } catch (e) {}

          // YouTube thumbnails follow a predictable URL pattern
          var thumbnail = 'https://i.ytimg.com/vi/' + videoId + '/mqdefault.jpg';

          if (title) {
            videos.push({
              title: title,
              link: 'https://www.youtube.com/watch?v=' + videoId,
              image: thumbnail,
              channel: channel || 'YouTube',
              views: viewText || ''
            });
          }
          return;
        }

        // --- OLD FORMAT: videoRenderer (kept as fallback) ---
        if (item.richItemRenderer &&
            item.richItemRenderer.content &&
            item.richItemRenderer.content.videoRenderer) {

          var vr = item.richItemRenderer.content.videoRenderer;
          var vid = vr.videoId;
          if (!vid) return;

          var vTitle = '';
          if (vr.title && vr.title.runs) {
            vTitle = vr.title.runs.map(function(r) { return r.text; }).join('');
          }
          var vChannel = '';
          if (vr.longBylineText && vr.longBylineText.runs) {
            vChannel = vr.longBylineText.runs[0].text;
          }
          var vViews = '';
          if (vr.shortViewCountText) {
            vViews = vr.shortViewCountText.simpleText || '';
            if (!vViews && vr.shortViewCountText.runs) {
              vViews = vr.shortViewCountText.runs.map(function(r) { return r.text; }).join('');
            }
          }

          if (vTitle) {
            videos.push({
              title: vTitle,
              link: 'https://www.youtube.com/watch?v=' + vid,
              image: 'https://i.ytimg.com/vi/' + vid + '/mqdefault.jpg',
              channel: vChannel || 'YouTube',
              views: vViews || ''
            });
          }
        }
      });
    } catch (e) {
      console.warn('Glass: Error parsing YouTube data structure:', e.message);
    }

    console.log('Glass: Found ' + videos.length + ' YouTube videos');
    // Return up to 15 videos
    return videos.slice(0, 15);
  })
  .catch(function(err) {
    console.warn('Glass: Failed to load YouTube:', err.message);
    return [];
  });
}


// ================================================================
// 5b. GOOGLE SHOPPING — Multiple "For You" sections
//
//    We fetch the Google Shopping "For You" page and parse out
//    MULTIPLE sections (e.g., "Continue shopping", "Jackets for
//    the bold", "Chinos for Every Day", etc.).
//
//    Google Shopping page structure (from DOM inspection):
//      - <article> elements = individual sections
//      - Each article has a heading (h1/h2/h3) = section title
//      - Inside each article: <g-inner-card> = product cards
//      - Each card contains: img, product name, store, price
//      - Product info lives in elements like .V5fewe
//
//    When fetched via fetch(), the HTML structure may differ
//    slightly from the live DOM, so we use multiple parsing
//    strategies as fallbacks.
// ================================================================

function loadGoogleShoppingSections() {
  // Use the "For you" tab URL — shopmd=2 triggers personalized sections
  return fetch('https://www.google.com/shopping?authuser=0&udm=28&shopmd=2', {
    headers: {
      'Accept': 'text/html',
      'Accept-Language': 'en-US,en;q=0.9'
    },
    credentials: 'include'
  })
  .then(function(response) {
    if (!response.ok) throw new Error('HTTP ' + response.status);
    return response.text();
  })
  .then(function(html) {
    var parser = new DOMParser();
    var doc = parser.parseFromString(html, 'text/html');
    var sections = [];

    // --- STRATEGY 1: Parse <article> elements (Google's section containers) ---
    // Each <article> is a themed shopping section with products
    var articles = doc.querySelectorAll('article');

    articles.forEach(function(article) {
      // Get the section title from the first heading element
      var heading = article.querySelector('h1, h2, h3, [role="heading"]');
      var title = heading ? heading.textContent.trim() : '';
      // Skip sections without meaningful titles
      if (!title || title.length < 3 || title.length > 80) return;
      // Skip feedback/utility sections
      if (title.toLowerCase().includes('feedback') ||
          title.toLowerCase().includes('accessibility')) return;

      // Find product cards — try multiple selectors
      var products = [];
      var cardEls = article.querySelectorAll('g-inner-card');
      // Fallback: if no g-inner-card, look for product-like divs
      if (cardEls.length === 0) {
        cardEls = article.querySelectorAll('[role="listitem"]');
      }

      cardEls.forEach(function(cardEl) {
        var img = cardEl.querySelector('img');
        var imgSrc = '';
        if (img) {
          // Try src, then data-src, then data-iml
          imgSrc = img.getAttribute('src') || img.getAttribute('data-src') || '';
          // Skip tiny tracking pixel images
          if (imgSrc && (imgSrc.length < 20 || imgSrc.startsWith('data:image/gif'))) {
            imgSrc = '';
          }
        }

        // Extract product text — name, price, merchant
        var text = cardEl.textContent.trim().replace(/\s+/g, ' ');
        if (text.length < 3) return;

        // Extract price (e.g., "$69.99")
        var priceMatch = text.match(/\$[\d,.]+/);
        var price = priceMatch ? priceMatch[0] : '';

        // Extract discount badge (e.g., "49% OFF")
        var discountMatch = text.match(/(\d+%\s*OFF)/i);
        var discount = discountMatch ? discountMatch[1] : '';

        // Clean up the product name:
        // Remove discount badge, price, and extract just the name
        var name = text;
        if (discount) name = name.replace(discount, '');
        if (price) name = name.split(price)[0];
        // Remove merchant name (usually after the product name, separated by ·)
        var nameParts = name.split('·');
        var merchant = nameParts.length > 1 ? nameParts[nameParts.length - 1].trim() : '';
        name = nameParts[0].trim();
        // Remove "SALE" or "DEALS" prefix badges
        name = name.replace(/^(SALE|DEALS|NEW)\s*/i, '').trim();
        // Remove "Viewed Xw ago" suffix
        name = name.replace(/Viewed\s+\d+\w?\s+ago/i, '').trim();

        if (name.length < 3 || name.length > 100) return;

        // Build the product link — link to Google Shopping search
        var link = 'https://www.google.com/shopping?q=' +
          encodeURIComponent(name) + '&udm=28';
        // Try to find an actual link in the card
        var anchor = cardEl.querySelector('a[href]');
        if (anchor) {
          var href = anchor.getAttribute('href') || '';
          if (href.startsWith('/')) href = 'https://www.google.com' + href;
          if (href.length > 10) link = href;
        }

        products.push({
          name: name,
          link: link,
          image: imgSrc,
          price: price,
          merchant: merchant,
          discount: discount
        });
      });

      if (products.length > 0) {
        sections.push({ title: title, products: products });
      }
    });

    // --- STRATEGY 2: Fallback — parse by finding product images ---
    // If article parsing didn't find much, look for encrypted-tbn images
    // grouped near section headings
    if (sections.length < 2) {
      // Find all shopping images and group by nearby heading
      var allImgs = doc.querySelectorAll('img[src*="encrypted-tbn"]');
      var continueShopping = [];
      allImgs.forEach(function(img) {
        var imgSrc = img.getAttribute('src') || '';
        if (!imgSrc) return;

        // Walk up to find name text
        var parent = img.parentElement;
        var name = img.getAttribute('alt') || '';
        for (var d = 0; d < 6 && parent && !name; d++) {
          var text = parent.textContent.trim();
          if (text.length > 5 && text.length < 100) {
            name = text.split('$')[0].replace(/\s+/g, ' ').trim();
            break;
          }
          parent = parent.parentElement;
        }
        if (!name || name.length < 3) return;

        // Try to find price
        var fullText = (parent || img.parentElement).textContent || '';
        var pm = fullText.match(/\$[\d,.]+/);

        continueShopping.push({
          name: name.substring(0, 80),
          link: 'https://www.google.com/shopping?q=' + encodeURIComponent(name) + '&udm=28',
          image: imgSrc,
          price: pm ? pm[0] : '',
          merchant: '',
          discount: ''
        });
      });

      if (continueShopping.length > 0) {
        sections.unshift({ title: 'Continue Shopping', products: continueShopping.slice(0, 15) });
      }
    }

    // If we still have no "Continue Shopping" section, label the first one
    if (sections.length > 0 && sections[0].title !== 'Continue Shopping' &&
        !sections[0].title.toLowerCase().includes('continue')) {
      sections.unshift({ title: 'Continue Shopping', products: sections.shift().products });
    }

    console.log('Glass: Found ' + sections.length + ' shopping sections');
    return sections.slice(0, 8); // Max 8 shopping sections
  })
  .catch(function(err) {
    console.warn('Glass: Failed to load Google Shopping:', err.message);
    return [];
  });
}


// ================================================================
// KICK IT ALL OFF — load the feed when the page opens
// ================================================================
loadCategoryFeeds();


// ----------------------------------------------------------------
// buildShoppingCard — creates a single product glass card
// Styled differently from news: smaller width, price in green,
// product image uses "contain" fit (not "cover") so we see the
// full product against a dark background.
// ----------------------------------------------------------------
function buildShoppingCard(product, index) {
  var card = document.createElement('a');
  card.className = 'shopping-card';
  card.href = product.link;
  card.target = '_blank';
  card.rel = 'noopener';

  // --- Product Image ---
  var imgWrap = document.createElement('div');
  imgWrap.style.position = 'relative';

  if (product.image) {
    var img = document.createElement('img');
    img.className = 'product-img';
    img.alt = product.name;
    img.loading = 'lazy';
    img.referrerPolicy = 'no-referrer';
    img.addEventListener('error', function() {
      imgWrap.replaceChild(createPlaceholder('Shopping', index), img);
    });
    img.src = product.image;
    imgWrap.appendChild(img);
  } else {
    var ph = createPlaceholder('Shopping', index);
    ph.style.height = '160px';
    imgWrap.appendChild(ph);
  }

  // Deal/discount badge overlay (e.g., "49% OFF")
  if (product.discount) {
    var badge = document.createElement('div');
    badge.className = 'deal-badge';
    badge.textContent = product.discount;
    imgWrap.appendChild(badge);
  }

  card.appendChild(imgWrap);

  // --- Product Info ---
  var info = document.createElement('div');
  info.className = 'product-info';

  var nameDiv = document.createElement('div');
  nameDiv.className = 'product-name';
  nameDiv.textContent = product.name;
  info.appendChild(nameDiv);

  if (product.price) {
    var priceDiv = document.createElement('div');
    priceDiv.className = 'product-price';
    priceDiv.textContent = product.price;
    info.appendChild(priceDiv);
  }

  if (product.merchant) {
    var merchantDiv = document.createElement('div');
    merchantDiv.className = 'product-source';
    merchantDiv.textContent = product.merchant;
    info.appendChild(merchantDiv);
  }

  card.appendChild(info);
  return card;
}


// ----------------------------------------------------------------
// buildShoppingSection — creates a named shopping section
// (e.g., "Continue Shopping", "Jackets for the bold", etc.)
// ----------------------------------------------------------------
function buildShoppingSection(title, products) {
  var section = document.createElement('div');
  section.className = 'feed-section';

  var header = document.createElement('div');
  header.className = 'section-header';
  var h2 = document.createElement('h2');
  h2.textContent = title;
  header.appendChild(h2);
  section.appendChild(header);

  var row = document.createElement('div');
  row.className = 'feed-row';
  products.forEach(function(product, i) {
    row.appendChild(buildShoppingCard(product, i));
  });
  section.appendChild(row);
  return section;
}




// ================================================================
// 7. TOP-RIGHT TOOLBAR — Google Apps grid + Account indicator
//
// Two elements fixed in the top-right corner:
//   a) Apps grid icon (3×3 dots) — opens a dropdown with links
//      to Google services (Gmail, Drive, Photos, YouTube, etc.)
//   b) Account avatar — shows sign-in status and links to
//      Google account settings
// ================================================================

var _userEmail = '';  // Set by the identity check in Section 1

// --- Google Apps data ---
// Each app uses its real favicon from the actual service URL.
// Chrome's built-in _favicon endpoint gives us the exact same
// --- Google Apps list ---
// Each app has a name, URL, and brand color used as fallback.
var GOOGLE_APPS = [
  { name: 'Search',     url: 'https://www.google.com',           color: '#4285F4' },
  { name: 'Gmail',      url: 'https://mail.google.com',          color: '#EA4335' },
  { name: 'Drive',      url: 'https://drive.google.com',         color: '#34A853' },
  { name: 'Calendar',   url: 'https://calendar.google.com',      color: '#4285F4' },
  { name: 'Docs',       url: 'https://docs.google.com',          color: '#4285F4' },
  { name: 'Sheets',     url: 'https://sheets.google.com',        color: '#34A853' },
  { name: 'Slides',     url: 'https://slides.google.com',        color: '#FBBC04' },
  { name: 'Photos',     url: 'https://photos.google.com',        color: '#EA4335' },
  { name: 'YouTube',    url: 'https://www.youtube.com',          color: '#FF0000' },
  { name: 'Maps',       url: 'https://maps.google.com',          color: '#34A853' },
  { name: 'Meet',       url: 'https://meet.google.com',          color: '#00897B' },
  { name: 'Chat',       url: 'https://chat.google.com',          color: '#34A853' },
  { name: 'Contacts',   url: 'https://contacts.google.com',      color: '#4285F4' },
  { name: 'Keep',       url: 'https://keep.google.com',          color: '#FBBC04' },
  { name: 'Forms',      url: 'https://docs.google.com/forms',    color: '#673AB7' },
  { name: 'Translate',  url: 'https://translate.google.com',     color: '#4285F4' },
  { name: 'News',       url: 'https://news.google.com',          color: '#4285F4' },
  { name: 'Finance',    url: 'https://finance.google.com',       color: '#34A853' },
  { name: 'Earth',      url: 'https://earth.google.com',         color: '#4285F4' },
  { name: 'Shopping',   url: 'https://shopping.google.com',      color: '#4285F4' },
];

// --- Google App Icon SVGs ---
// Inline SVG data URIs for each Google product icon.
// WHY: Google's favicon services (s2/favicons, _favicon) return a generic
// "G" icon for most Google subdomains because they all share the same
// favicon.ico. These inline SVGs guarantee each app gets a unique,
// recognizable icon — no network request needed, never breaks.
// Each icon uses the product's official brand color with a simple white
// symbol that represents the product.
var GOOGLE_APP_ICON_SVGS = {
  // Search: blue bg, white magnifying glass
  'Search': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48"><rect width="48" height="48" rx="12" fill="#4285F4"/><circle cx="21" cy="21" r="8" fill="none" stroke="white" stroke-width="3"/><line x1="27" y1="27" x2="37" y2="37" stroke="white" stroke-width="3" stroke-linecap="round"/></svg>',

  // Gmail: red bg, white envelope with flap
  'Gmail': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48"><rect width="48" height="48" rx="12" fill="#EA4335"/><rect x="9" y="13" width="30" height="22" rx="2" fill="none" stroke="white" stroke-width="2.5"/><path d="M9 15l15 11 15-11" fill="none" stroke="white" stroke-width="2.5" stroke-linejoin="round"/></svg>',

  // Drive: yellow bg, white triangle
  'Drive': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48"><rect width="48" height="48" rx="12" fill="#FBBC04"/><path d="M24 10l14 24H10z" fill="none" stroke="white" stroke-width="2.5" stroke-linejoin="round"/></svg>',

  // Calendar: blue bg, white calendar with hooks and "31"
  'Calendar': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48"><rect width="48" height="48" rx="12" fill="#4285F4"/><rect x="11" y="14" width="26" height="24" rx="2" fill="none" stroke="white" stroke-width="2.5"/><line x1="11" y1="22" x2="37" y2="22" stroke="white" stroke-width="2.5"/><line x1="19" y1="10" x2="19" y2="17" stroke="white" stroke-width="2.5" stroke-linecap="round"/><line x1="29" y1="10" x2="29" y2="17" stroke="white" stroke-width="2.5" stroke-linecap="round"/><text x="24" y="35" text-anchor="middle" font-family="Arial,sans-serif" font-size="11" font-weight="bold" fill="white">31</text></svg>',

  // Docs: blue bg, white document page with text lines
  'Docs': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48"><rect width="48" height="48" rx="12" fill="#4285F4"/><rect x="13" y="8" width="22" height="32" rx="2" fill="none" stroke="white" stroke-width="2.5"/><line x1="18" y1="18" x2="30" y2="18" stroke="white" stroke-width="2" stroke-linecap="round"/><line x1="18" y1="24" x2="30" y2="24" stroke="white" stroke-width="2" stroke-linecap="round"/><line x1="18" y1="30" x2="26" y2="30" stroke="white" stroke-width="2" stroke-linecap="round"/></svg>',

  // Sheets: green bg, white spreadsheet grid
  'Sheets': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48"><rect width="48" height="48" rx="12" fill="#34A853"/><rect x="11" y="11" width="26" height="26" rx="2" fill="none" stroke="white" stroke-width="2.5"/><line x1="11" y1="20" x2="37" y2="20" stroke="white" stroke-width="2"/><line x1="11" y1="29" x2="37" y2="29" stroke="white" stroke-width="2"/><line x1="22" y1="11" x2="22" y2="37" stroke="white" stroke-width="2"/></svg>',

  // Slides: yellow bg, white presentation rectangle
  'Slides': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48"><rect width="48" height="48" rx="12" fill="#FBBC04"/><rect x="10" y="12" width="28" height="24" rx="2" fill="none" stroke="white" stroke-width="2.5"/><rect x="17" y="18" width="14" height="12" rx="1" fill="white" opacity="0.4"/></svg>',

  // Photos: red bg, white camera aperture / lens
  'Photos': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48"><rect width="48" height="48" rx="12" fill="#EA4335"/><circle cx="24" cy="24" r="12" fill="none" stroke="white" stroke-width="2.5"/><circle cx="24" cy="24" r="5" fill="white"/><line x1="24" y1="12" x2="24" y2="18" stroke="white" stroke-width="2"/><line x1="24" y1="30" x2="24" y2="36" stroke="white" stroke-width="2"/><line x1="12" y1="24" x2="18" y2="24" stroke="white" stroke-width="2"/><line x1="30" y1="24" x2="36" y2="24" stroke="white" stroke-width="2"/></svg>',

  // YouTube: red bg, white rounded rectangle with play triangle
  'YouTube': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48"><rect width="48" height="48" rx="12" fill="#FF0000"/><rect x="8" y="13" width="32" height="22" rx="5" fill="none" stroke="white" stroke-width="2.5"/><path d="M20 17l12 7-12 7z" fill="white"/></svg>',

  // Maps: green bg, white location pin
  'Maps': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48"><rect width="48" height="48" rx="12" fill="#34A853"/><path d="M24 40s-12-13-12-20a12 12 0 1 1 24 0c0 7-12 20-12 20z" fill="none" stroke="white" stroke-width="2.5"/><circle cx="24" cy="20" r="4" fill="white"/></svg>',

  // Meet: teal bg, white video camera
  'Meet': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48"><rect width="48" height="48" rx="12" fill="#00897B"/><rect x="10" y="15" width="20" height="18" rx="2" fill="none" stroke="white" stroke-width="2.5"/><path d="M30 20l8-5v18l-8-5z" fill="white"/></svg>',

  // Chat: green bg, white speech bubble
  'Chat': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48"><rect width="48" height="48" rx="12" fill="#34A853"/><path d="M12 14a2 2 0 0 1 2-2h20a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H22l-6 6v-6h-2a2 2 0 0 1-2-2z" fill="none" stroke="white" stroke-width="2.5" stroke-linejoin="round"/></svg>',

  // Contacts: blue bg, white person silhouette
  'Contacts': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48"><rect width="48" height="48" rx="12" fill="#4285F4"/><circle cx="24" cy="18" r="7" fill="none" stroke="white" stroke-width="2.5"/><path d="M12 40c0-8 5-14 12-14s12 6 12 14" fill="none" stroke="white" stroke-width="2.5"/></svg>',

  // Keep: yellow bg, white notepad
  'Keep': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48"><rect width="48" height="48" rx="12" fill="#FBBC04"/><rect x="14" y="8" width="20" height="32" rx="2" fill="none" stroke="white" stroke-width="2.5"/><line x1="19" y1="17" x2="29" y2="17" stroke="white" stroke-width="2" stroke-linecap="round"/><line x1="19" y1="23" x2="29" y2="23" stroke="white" stroke-width="2" stroke-linecap="round"/><line x1="19" y1="29" x2="25" y2="29" stroke="white" stroke-width="2" stroke-linecap="round"/></svg>',

  // Forms: purple bg, white checklist with radio buttons
  'Forms': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48"><rect width="48" height="48" rx="12" fill="#673AB7"/><circle cx="17" cy="17" r="3" fill="none" stroke="white" stroke-width="2"/><line x1="24" y1="17" x2="34" y2="17" stroke="white" stroke-width="2" stroke-linecap="round"/><circle cx="17" cy="27" r="3" fill="none" stroke="white" stroke-width="2"/><line x1="24" y1="27" x2="34" y2="27" stroke="white" stroke-width="2" stroke-linecap="round"/><circle cx="17" cy="37" r="3" fill="white"/><line x1="24" y1="37" x2="34" y2="37" stroke="white" stroke-width="2" stroke-linecap="round"/></svg>',

  // Translate: blue bg, white "A" letter (language symbol)
  'Translate': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48"><rect width="48" height="48" rx="12" fill="#4285F4"/><text x="17" y="34" font-family="Arial,sans-serif" font-size="22" font-weight="bold" fill="white">A</text><text x="30" y="28" font-family="Arial,sans-serif" font-size="14" fill="white" opacity="0.7">a</text></svg>',

  // News: blue bg, white newspaper icon
  'News': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48"><rect width="48" height="48" rx="12" fill="#4285F4"/><rect x="10" y="10" width="28" height="28" rx="2" fill="none" stroke="white" stroke-width="2.5"/><line x1="15" y1="17" x2="33" y2="17" stroke="white" stroke-width="2.5" stroke-linecap="round"/><line x1="15" y1="23" x2="25" y2="23" stroke="white" stroke-width="1.5" stroke-linecap="round"/><line x1="15" y1="28" x2="25" y2="28" stroke="white" stroke-width="1.5" stroke-linecap="round"/><line x1="15" y1="33" x2="25" y2="33" stroke="white" stroke-width="1.5" stroke-linecap="round"/><rect x="28" y="23" width="5" height="10" rx="1" fill="white" opacity="0.5"/></svg>',

  // Finance: green bg, white trending-up chart line
  'Finance': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48"><rect width="48" height="48" rx="12" fill="#34A853"/><polyline points="10,36 18,28 24,32 38,14" fill="none" stroke="white" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/><polyline points="30,14 38,14 38,22" fill="none" stroke="white" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/></svg>',

  // Earth: blue bg, white globe with meridian
  'Earth': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48"><rect width="48" height="48" rx="12" fill="#4285F4"/><circle cx="24" cy="24" r="13" fill="none" stroke="white" stroke-width="2.5"/><ellipse cx="24" cy="24" rx="6" ry="13" fill="none" stroke="white" stroke-width="1.5"/><line x1="11" y1="24" x2="37" y2="24" stroke="white" stroke-width="1.5"/></svg>',

  // Shopping: blue bg, white shopping bag with handle
  'Shopping': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48"><rect width="48" height="48" rx="12" fill="#4285F4"/><path d="M14 18h20l-2 20H16z" fill="none" stroke="white" stroke-width="2.5" stroke-linejoin="round"/><path d="M19 18v-4a5 5 0 0 1 10 0v4" fill="none" stroke="white" stroke-width="2.5" stroke-linecap="round"/></svg>'
};

// Convert an app name to its SVG data URI icon.
// This is 100% reliable — no network requests, works offline.
function googleAppIconDataUri(name) {
  var svg = GOOGLE_APP_ICON_SVGS[name];
  if (!svg) return '';
  return 'data:image/svg+xml,' + encodeURIComponent(svg);
}

function buildTopToolbar() {
  // Create the fixed toolbar container
  var toolbar = document.createElement('div');
  toolbar.id = 'topToolbar';

  // ========================================
  // A) GOOGLE APPS GRID BUTTON + DROPDOWN
  // ========================================

  var appsWrap = document.createElement('div');
  appsWrap.style.position = 'relative';

  // The 3×3 grid icon button (SVG matching Google's design)
  var gridBtn = document.createElement('button');
  gridBtn.className = 'apps-grid-btn';
  gridBtn.title = 'Google Apps';
  gridBtn.innerHTML =
    '<svg width="20" height="20" viewBox="0 0 24 24" fill="currentColor">' +
      '<circle cx="4" cy="4" r="2"/><circle cx="12" cy="4" r="2"/><circle cx="20" cy="4" r="2"/>' +
      '<circle cx="4" cy="12" r="2"/><circle cx="12" cy="12" r="2"/><circle cx="20" cy="12" r="2"/>' +
      '<circle cx="4" cy="20" r="2"/><circle cx="12" cy="20" r="2"/><circle cx="20" cy="20" r="2"/>' +
    '</svg>';

  // The dropdown panel that appears when you click the grid
  var dropdown = document.createElement('div');
  dropdown.className = 'apps-dropdown';

  var grid = document.createElement('div');
  grid.className = 'apps-dropdown-grid';

  // Build each app tile
  GOOGLE_APPS.forEach(function(app) {
    var tile = document.createElement('a');
    tile.className = 'app-tile';
    tile.href = app.url;
    tile.target = '_blank';
    tile.rel = 'noopener';
    tile.title = app.name;

    // App icon — uses inline SVG data URIs so each product gets
    // its own unique, recognizable icon. These never fail to load
    // because the SVG data is embedded right in the code.
    var img = document.createElement('img');
    img.src = googleAppIconDataUri(app.name);
    img.alt = app.name;
    img.style.width = '32px';
    img.style.height = '32px';
    tile.appendChild(img);

    // App name label
    var label = document.createElement('span');
    label.className = 'app-label';
    label.textContent = app.name;
    tile.appendChild(label);

    grid.appendChild(tile);
  });

  dropdown.appendChild(grid);

  // Toggle dropdown on click
  gridBtn.addEventListener('click', function(e) {
    e.stopPropagation();
    var isOpen = dropdown.classList.contains('visible');
    dropdown.classList.toggle('visible');
    gridBtn.classList.toggle('active');
    // If opening, close when clicking elsewhere
    if (!isOpen) {
      setTimeout(function() {
        document.addEventListener('click', closeAppsDropdown);
      }, 0);
    }
  });

  function closeAppsDropdown() {
    dropdown.classList.remove('visible');
    gridBtn.classList.remove('active');
    document.removeEventListener('click', closeAppsDropdown);
  }

  appsWrap.appendChild(gridBtn);
  appsWrap.appendChild(dropdown);

  // ========================================
  // CLAUDE ICON BUTTON — opens the Claude Chrome extension
  // Sits to the LEFT of the apps grid button.
  // Uses the Claude "sparkle" brand icon in a circular button.
  // Clicking it sends a message to the Claude extension to open
  // its side panel, or falls back to opening claude.ai in a new tab.
  // ========================================
  var claudeBtn = document.createElement('button');
  claudeBtn.className = 'claude-toolbar-btn';
  claudeBtn.title = 'Open Claude AI';

  // Claude brand icon — the exact Claude starburst / sunburst logo.
  // This is a multi-ray organic starburst in Claude's terracotta (#D97757).
  // Each ray is a rounded pill/leaf shape radiating from the center at
  // different angles, lengths, and thicknesses — giving it the distinctive
  // hand-drawn, organic feel of the real Claude logo.
  claudeBtn.innerHTML =
    '<svg width="24" height="24" viewBox="0 0 100 100" fill="#D97757" xmlns="http://www.w3.org/2000/svg">' +
      // Top ray (12 o'clock) — tall thin ray pointing straight up
      '<ellipse cx="50" cy="22" rx="5.5" ry="20" transform="rotate(0,50,50)" />' +
      // Upper-right ray — angled slightly right
      '<ellipse cx="50" cy="24" rx="4.8" ry="17" transform="rotate(36,50,50)" />' +
      // Right ray (3 o'clock) — pointing right
      '<ellipse cx="50" cy="23" rx="5" ry="19" transform="rotate(72,50,50)" />' +
      // Lower-right ray
      '<ellipse cx="50" cy="25" rx="4.5" ry="16" transform="rotate(108,50,50)" />' +
      // Bottom-right ray
      '<ellipse cx="50" cy="22" rx="5.2" ry="18" transform="rotate(144,50,50)" />' +
      // Bottom ray (6 o'clock) — pointing straight down
      '<ellipse cx="50" cy="24" rx="5" ry="17" transform="rotate(180,50,50)" />' +
      // Bottom-left ray
      '<ellipse cx="50" cy="23" rx="4.6" ry="19" transform="rotate(216,50,50)" />' +
      // Left ray (9 o'clock) — pointing left
      '<ellipse cx="50" cy="25" rx="5.3" ry="16" transform="rotate(252,50,50)" />' +
      // Upper-left ray
      '<ellipse cx="50" cy="22" rx="4.8" ry="18" transform="rotate(288,50,50)" />' +
      // Near-top-left ray
      '<ellipse cx="50" cy="24" rx="5" ry="17" transform="rotate(324,50,50)" />' +
      // Center dot to fill the middle
      '<circle cx="50" cy="50" r="9" />' +
    '</svg>';

  // When clicked, open the Claude for Chrome extension.
  // Uses chrome.action API to programmatically trigger the Claude extension,
  // which opens its side panel. Falls back to opening claude.ai directly.
  claudeBtn.addEventListener('click', function() {
    // Send a message to our background script to open the Claude extension.
    // The background script can use chrome.sidePanel or chrome.action APIs
    // which aren't available on regular extension pages.
    chrome.runtime.sendMessage(
      { type: 'open-claude-extension' },
      function(response) {
        if (chrome.runtime.lastError) {
          // Fallback: open claude.ai in a new tab
          window.open('https://claude.ai/new', '_blank');
        }
      }
    );
  });

  toolbar.appendChild(claudeBtn);
  toolbar.appendChild(appsWrap);

  // ========================================
  // B) ACCOUNT INDICATOR
  // ========================================
  var indicator = document.createElement('div');
  indicator.id = 'accountIndicator';
  toolbar.appendChild(indicator);

  // Add the toolbar to the page
  document.body.appendChild(toolbar);
}

function updateAccountIndicator() {
  var indicator = document.getElementById('accountIndicator');
  if (!indicator) return;  // Toolbar not built yet

  indicator.innerHTML = '';

  if (_userEmail) {
    // --- SIGNED IN: show avatar with initial ---
    var initial = _userEmail.charAt(0).toUpperCase();

    var avatar = document.createElement('div');
    avatar.className = 'account-avatar';
    avatar.textContent = initial;
    avatar.title = _userEmail + '\nClick to manage your Google account';
    indicator.appendChild(avatar);

    avatar.addEventListener('click', function() {
      window.open('https://myaccount.google.com/', '_blank');
    });
  } else {
    // --- NOT SIGNED IN: show sign-in prompt ---
    var signInBtn = document.createElement('a');
    signInBtn.className = 'account-signin';
    signInBtn.textContent = 'Sign in';
    signInBtn.title = 'Sign in to Google for personalized content';
    signInBtn.href = 'https://accounts.google.com/signin';
    signInBtn.target = '_blank';
    indicator.appendChild(signInBtn);
  }
}

// Build the toolbar immediately, then update account status when ready
buildTopToolbar();
updateAccountIndicator();


// ================================================================
// 8. BACKGROUND IMAGE ROTATION — changes daily
// ================================================================

var BG_IMAGES = [
  'https://images.unsplash.com/photo-1472396961693-142e6e269027?w=1920&q=80',
  'https://images.unsplash.com/photo-1506905925346-21bda4d32df4?w=1920&q=80',
  'https://images.unsplash.com/photo-1470071459604-3b5ec3a7fe05?w=1920&q=80',
  'https://images.unsplash.com/photo-1441974231531-c6227db76b6e?w=1920&q=80',
];
var dayIndex = new Date().getDate() % BG_IMAGES.length;
document.getElementById('bg').style.backgroundImage = "url('" + BG_IMAGES[dayIndex] + "')";
