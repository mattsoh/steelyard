const API_BASE = `/organizations/${window.HCB_ORGANIZATION_ID}`;

let allTransactions = [];
let matches = [];
let byId = new Map();
// False for the whole drain (including while pages are still streaming in),
// so an org whose transactions/matches just haven't landed yet doesn't get
// mistaken by renderLists() for one that's genuinely fully unmatched-empty.
let transactionsLoaded = false;

let zeroBalanceOptions = [];
let zeroBalanceSelectedId = null;
let pendingCutoffId = null;

let selectedIncomingIds = [];
let selectedOutgoingIds = [];

// When editing an existing match, its legs are pulled into the selection
// above (and the match itself removed from `matches` so its legs show up as
// selectable again) -- these track that state so confirm/cancel can tell an
// edit-in-progress from an ordinary new match, and so any match the user was
// already assembling in the tray can be stashed and restored afterward.
let editingMatchId = null;
let editingMatchOriginal = null;
let stashedSelection = null;

let currentIncomingOrder = [];
let currentOutgoingOrder = [];
let lastIncomingClickId = null;
let lastOutgoingClickId = null;
let matchBusy = false;
let traySnapshotRestored = false;
// True from the moment a full reload is accepted by the server until the
// re-stream that follows it has finished -- see clearForFullReload.
let restreamingFullReload = false;
// The tray snapshot that full reload parked, held here (rather than read back
// out of localStorage) so an in-progress match survives the re-stream even if
// the re-stream itself fails and the page carries on without one.
let parkedTraySnapshot = null;

const TRAY_STORAGE_KEY = `steelyard.tray.${window.HCB_ORGANIZATION_ID}`;

// The tray's note lives in the DOM rather than in a variable, because it's a
// static field the tray's re-renders don't touch -- reading it back on save is
// what keeps typing and re-rendering out of each other's way.
function trayNote() {
  const input = document.getElementById("tray-note");
  return input ? input.value.trim() : "";
}

function setTrayNote(value) {
  const input = document.getElementById("tray-note");
  if (input) input.value = value || "";
}

// Persists the in-progress (unsaved) match tray to localStorage, which is
// shared across every tab in the browser, so a refresh (or an accidental tab
// close) doesn't throw away work someone was assembling but hadn't confirmed
// yet. Restored once per page load, after the full transaction/match set has
// landed, so stale ids (matched or deleted elsewhere in the meantime) can be
// filtered out rather than silently re-selected.
function saveTraySnapshot() {
  // A full reload empties the tray on screen along with everything else while
  // the drain runs (see clearForFullReload). That empty tray isn't what anyone
  // chose, so it isn't written back: the stored snapshot is shared with every
  // other tab on this organization, and saving an empty tray deletes it.
  if (restreamingFullReload) return;
  try {
    if (selectedIncomingIds.length === 0 && selectedOutgoingIds.length === 0 && editingMatchId === null && !stashedSelection) {
      localStorage.removeItem(TRAY_STORAGE_KEY);
      return;
    }
    localStorage.setItem(TRAY_STORAGE_KEY, JSON.stringify({
      selectedIncomingIds,
      selectedOutgoingIds,
      editingMatchId,
      editingMatchOriginal,
      stashedSelection,
      note: trayNote(),
    }));
  } catch (e) {}
}

function restoreTraySnapshot() {
  if (traySnapshotRestored) return;
  traySnapshotRestored = true;
  let snap;
  try {
    const raw = parkedTraySnapshot ?? localStorage.getItem(TRAY_STORAGE_KEY);
    parkedTraySnapshot = null;
    if (!raw) return;
    snap = JSON.parse(raw);
  } catch (e) {
    return;
  }

  const validId = (id) => byId.has(id);
  const used = usedIds();

  if (snap.editingMatchId !== null) {
    const m = matches.find((x) => x.id === snap.editingMatchId);
    if (m) {
      matches = matches.filter((x) => x.id !== snap.editingMatchId);
      editingMatchId = snap.editingMatchId;
      editingMatchOriginal = m;
    }
  }

  selectedIncomingIds = (snap.selectedIncomingIds || []).filter(validId);
  selectedOutgoingIds = (snap.selectedOutgoingIds || []).filter(validId);
  if (editingMatchId === null) {
    selectedIncomingIds = selectedIncomingIds.filter((id) => !used.has(id));
    selectedOutgoingIds = selectedOutgoingIds.filter((id) => !used.has(id));
  }

  setTrayNote(snap.note);

  if (snap.stashedSelection) {
    const incomingIds = (snap.stashedSelection.incomingIds || []).filter(validId).filter((id) => !used.has(id));
    const outgoingIds = (snap.stashedSelection.outgoingIds || []).filter(validId).filter((id) => !used.has(id));
    stashedSelection = incomingIds.length || outgoingIds.length ? { incomingIds, outgoingIds } : null;
  }
}

// Work a navigation would walk away from: anything sitting in the tray
// unconfirmed (including a match being edited and a selection stashed behind
// that edit), the copy a full reload has parked, and a save still in flight.
// Deliberately nothing else -- the cutoff and every match action are written to
// the server as they happen, and the search/sort/width controls are just a view.
function hasUnconfirmedMatch() {
  return selectedIncomingIds.length > 0 ||
    selectedOutgoingIds.length > 0 ||
    editingMatchId !== null ||
    !!stashedSelection ||
    !!parkedTraySnapshot ||
    matchBusy;
}

// Set when the page itself is sending the browser somewhere -- see details.js's
// re-login redirect. Nobody should be asked to confirm a navigation they didn't
// choose, least of all one they can't avoid.
let navigatingAway = false;

function allowNavigationWithoutWarning() {
  navigatingAway = true;
}

// The browser's own "leave site?" prompt, on a link click, a back, or a tab
// close. Its wording isn't ours to set -- browsers ignore any custom message --
// so all a page can do is say whether there's anything worth interrupting for.
// Stays quiet unless the tray actually holds something, which is what keeps it
// from crying wolf on every trip to the ledger.
window.addEventListener("beforeunload", (e) => {
  if (navigatingAway || !hasUnconfirmedMatch()) return;
  e.preventDefault();
  e.returnValue = ""; // Safari and older Chrome still key off this rather than preventDefault
});

// Belt and braces under the prompt: whether or not someone stays, the tray goes
// to disk on the way out, so coming back restores it (see restoreTraySnapshot).
// render() has already saved every change by this point -- this is here for the
// change that somehow didn't render. pagehide rather than unload, which some
// browsers fire unreliably and iOS not at all.
window.addEventListener("pagehide", saveTraySnapshot);

const FILTER_STORAGE_KEY = `steelyard.matcherFilters.${window.HCB_ORGANIZATION_ID}`;
const FILTER_FIELD_IDS = [
  "search-incoming", "search-incoming-amount", "search-incoming-after", "search-incoming-before",
  "search-outgoing", "search-outgoing-amount", "search-outgoing-after", "search-outgoing-before",
  "sort-incoming", "sort-outgoing",
];
// Read/written through .checked rather than .value, so they're kept apart from
// the text/select fields above rather than special-cased inside the loops.
const FILTER_CHECKBOX_IDS = ["include-matched-incoming", "include-matched-outgoing"];

// Persists the search/sort controls to localStorage so an accidental refresh
// (or coming back later) doesn't silently reset a search someone was in the
// middle of -- the underlying transaction/match data reloads regardless,
// this just restores what the view was narrowed down to.
function saveFilterSnapshot() {
  try {
    const snap = {};
    for (const id of FILTER_FIELD_IDS) snap[id] = document.getElementById(id).value;
    for (const id of FILTER_CHECKBOX_IDS) snap[id] = document.getElementById(id).checked;
    localStorage.setItem(FILTER_STORAGE_KEY, JSON.stringify(snap));
  } catch (e) {}
}

function restoreFilterSnapshot() {
  let snap;
  try {
    const raw = localStorage.getItem(FILTER_STORAGE_KEY);
    if (!raw) return;
    snap = JSON.parse(raw);
  } catch (e) {
    return;
  }
  for (const id of FILTER_FIELD_IDS) {
    if (snap[id] !== undefined) document.getElementById(id).value = snap[id];
  }
  for (const id of FILTER_CHECKBOX_IDS) {
    if (snap[id] !== undefined) document.getElementById(id).checked = !!snap[id];
  }
}

const fmt = (n) => (n < 0 ? "-$" : "$") + Math.abs(n).toFixed(2);

function amountMatches(amount, query) {
  const q = query.trim();
  if (!q) return true;
  const cleaned = q.replace(/[^0-9.-]/g, "");
  if (!cleaned) return false;
  const target = parseFloat(cleaned);
  if (Number.isNaN(target)) return false;
  return Math.abs(Math.abs(amount) - Math.abs(target)) < 0.005;
}

// `date` and the `after`/`before` filter values are all "YYYY-MM-DD" (HCB's
// transaction date, and <input type="date">'s value), so plain string
// comparison sorts correctly without parsing. Both bounds are inclusive.
function dateInRange(date, after, before) {
  if (after && date < after) return false;
  if (before && date > before) return false;
  return true;
}

const LOADING_HTML = `<div class="empty-msg loading-msg"><span class="loading-spinner"></span>Loading transactions…</div>`;

function showListsMessage(html) {
  document.getElementById("list-incoming").innerHTML = html;
  document.getElementById("list-outgoing").innerHTML = html;
}

// Per-panel spans get their own direction's count. totalCount (when HCB
// provides it) covers both directions combined -- HCB doesn't report it
// per-direction, so it can't be split into a true "of N incoming" figure.
// It's shown as shared context on both panels, plus once on its own at the
// top of the page.
function updateLoadProgress(totalCount) {
  const inCount = allTransactions.filter((t) => t.direction === "in").length;
  const outCount = allTransactions.filter((t) => t.direction === "out").length;
  const suffix = totalCount ? ` (of ~${totalCount} total txns)` : "";
  document.getElementById("load-progress-div").style.display = "";
  document.getElementById("progress-incoming").textContent = `loading… ${inCount} so far${suffix}`;
  document.getElementById("progress-outgoing").textContent = `loading… ${outCount} so far${suffix}`;

  const loaded = allTransactions.length;
  document.getElementById("load-progress-overall").textContent = totalCount
    ? `Loading… ${loaded} of ~${totalCount} transactions`
    : `Loading… ${loaded} transactions so far`;
}

function clearLoadProgress() {

  document.getElementById("progress-incoming").textContent = "";
  document.getElementById("progress-outgoing").textContent = "";
  document.getElementById("load-progress-div").style.display = "none";
}

async function loadAll() {
  showListsMessage(LOADING_HTML);
  allTransactions = [];
  byId = new Map();
  transactionsLoaded = false;
  let txData, matchData;
  try {
    const matchesPromise = fetch(`${API_BASE}/api/matches`).then((r) => {
      if (!r.ok) throw new Error("bad response");
      return r.json();
    });

    // Apply matches as soon as they arrive rather than waiting on the (often
    // much slower) full transaction drain below -- matches is a single fast
    // query, and matched/unmatched status shouldn't sit blank/wrong for the
    // whole multi-page HCB drain just because it's bundled with it. Errors
    // here are handled below, once this same promise is awaited again.
    matchesPromise.then((data) => {
      matches = data.matches;
      render();
    }).catch(() => {});

    // Render rows as pages stream in so the lists aren't a blank spinner for
    // the full multi-page HCB drain. Cutoff filtering and matched/unmatched
    // status can shift once the real data lands below -- rows may appear
    // then disappear as the provisional (unfiltered) view is replaced by the
    // authoritative one.
    await loadPagesStreaming(`${API_BASE}/api/transactions/page`, (rows, totalCount) => {
      allTransactions.push(...rows);
      for (const t of rows) byId.set(t.id, t);
      updateLoadProgress(totalCount);
      render();
    });

    const [txRes, matchDataResolved] = await Promise.all([
      fetch(`${API_BASE}/api/transactions`),
      matchesPromise,
    ]);
    if (!txRes.ok) throw new Error("bad response");
    txData = await txRes.json();
    matchData = matchDataResolved;
  } catch (e) {
    clearLoadProgress();
    showListsMessage(`<div class="empty-msg">Could not load transactions. <a href="#" class="nav-link load-retry">Retry</a></div>`);
    document.querySelectorAll(".load-retry").forEach((el) => {
      el.addEventListener("click", (ev) => {
        ev.preventDefault();
        loadAll();
      });
    });
    return false;
  }
  clearLoadProgress();
  allTransactions = txData.transactions;
  byId = new Map(allTransactions.map((t) => [t.id, t]));
  matches = matchData.matches;
  transactionsLoaded = true;

  zeroBalanceOptions = txData.zero_balance_options || [];
  zeroBalanceSelectedId = txData.zero_balance_selected_id || null;
  renderCutoffSelect();

  restoreTraySnapshot();
  render();
  return true;
}

// Reloads the authoritative views in place, leaving what's currently rendered
// alone until the new data is ready -- for picking up a sync that happened
// while someone was mid-match, where loadAll()'s blank-the-lists-and-restream
// approach would yank the ground out from under them.
//
// Skips the page-streaming path entirely: this only runs right after a
// successful sync, so the server's drain cache is warm and /api/transactions
// is one fast request with no HCB round trips behind it. The tray is left
// untouched (no restoreTraySnapshot) -- whatever the user has selected right
// now is more current than any snapshot.
async function reloadInPlace() {
  let txData, matchData;
  try {
    const [txRes, matchRes] = await Promise.all([
      fetch(`${API_BASE}/api/transactions`),
      fetch(`${API_BASE}/api/matches`),
    ]);
    if (!txRes.ok || !matchRes.ok) throw new Error("bad response");
    txData = await txRes.json();
    matchData = await matchRes.json();
  } catch (e) {
    return false;
  }

  allTransactions = txData.transactions;
  byId = new Map(allTransactions.map((t) => [t.id, t]));
  transactionsLoaded = true;

  // A match being edited was pulled out of `matches` on purpose (its legs show
  // as selectable while it's in the tray); re-adding it from the server's list
  // would make them look used and drop them out of the lists mid-edit.
  matches = editingMatchId === null ? matchData.matches : matchData.matches.filter((m) => m.id !== editingMatchId);

  // A transaction can leave the working set between loads -- most likely
  // because someone else moved the cutoff past it. Drop those from the tray
  // rather than leaving renderTray to dereference an id byId no longer has.
  const stillLoaded = (id) => byId.has(id);
  selectedIncomingIds = selectedIncomingIds.filter(stillLoaded);
  selectedOutgoingIds = selectedOutgoingIds.filter(stillLoaded);
  if (stashedSelection) {
    stashedSelection = {
      incomingIds: (stashedSelection.incomingIds || []).filter(stillLoaded),
      outgoingIds: (stashedSelection.outgoingIds || []).filter(stillLoaded),
    };
  }

  zeroBalanceOptions = txData.zero_balance_options || [];
  zeroBalanceSelectedId = txData.zero_balance_selected_id || null;
  renderCutoffSelect();
  render();
  return true;
}

// Splices one freshly re-checked transaction (details.js's per-transaction
// refresh button) into local state, so the row behind the modal -- and the
// unmatched totals computed from it -- stop showing the value it had when the
// page loaded. A sign flip moves it between the incoming and outgoing panels,
// which render() handles on its own.
function applyRefreshedTransaction(fresh) {
  if (!byId.has(fresh.id)) return;

  byId.set(fresh.id, fresh);
  const index = allTransactions.findIndex((t) => t.id === fresh.id);
  if (index >= 0) allTransactions[index] = fresh;
  render();
}

let transactionsRefreshing = false;

function setSyncNote(text) {
  document.getElementById("sync-note").textContent = text;
}

// Both HCB buttons share one busy state: they hit the same drain, so letting
// one run while the other is mid-flight would just have them fight over it.
function setSyncButtonsDisabled(disabled) {
  document.getElementById("btn-refresh-transactions").disabled = disabled;
  document.getElementById("btn-full-reload").disabled = disabled;
}

// Runs the cheap server-side "anything new on HCB?" check and, if it turns
// anything up, pulls it in without disturbing what's on screen. `announce`
// distinguishes the button (which owes the user an answer either way) from the
// automatic check on load (which should stay silent unless it found something).
async function refreshTransactions({ announce }) {
  if (transactionsRefreshing) return;
  transactionsRefreshing = true;
  setSyncButtonsDisabled(true);
  if (announce) setSyncNote("checking HCB…");

  try {
    const changed = await syncNewTransactions({
      onSyncing: () => setSyncNote("new activity found, syncing in the background…"),
    });
    if (!changed) {
      setSyncNote(announce ? "up to date" : "");
      return;
    }

    const before = allTransactions.length;
    setSyncNote("new activity found, updating…");
    if (!(await reloadInPlace())) {
      setSyncNote("sync failed — reload the page");
      return;
    }
    const added = allTransactions.length - before;
    setSyncNote(added > 0 ? `${added} new transaction${added === 1 ? "" : "s"} loaded` : "updated");
  } finally {
    transactionsRefreshing = false;
    setSyncButtonsDisabled(false);
  }
}

// Drops everything the drain is about to replace and puts the page back in the
// state a cold load starts in: no transactions, no matches, lists showing their
// loading state. Unlike a sync (which patches new rows in around whatever
// someone is doing), a full reload throws the server's entire drain away and
// rebuilds it -- and the rows on screen are the ones whoever pressed the button
// has decided not to trust, so they don't get to sit there looking current for
// the minutes it takes. loadAll() streams them back in afterwards.
//
// The tray is parked rather than discarded: its snapshot is held aside and
// loadAll's restoreTraySnapshot puts the selection back once there are fresh
// transactions to validate it against -- exactly what refreshing the browser
// mid-match does.
function clearForFullReload() {
  restreamingFullReload = true;
  try {
    parkedTraySnapshot = localStorage.getItem(TRAY_STORAGE_KEY);
  } catch (e) {}
  // The modal is showing one of the rows being thrown away, and its refresh
  // button would splice a value into state that no longer holds it.
  hideDetailsModal();

  allTransactions = [];
  byId = new Map();
  matches = [];
  transactionsLoaded = false;

  selectedIncomingIds = [];
  selectedOutgoingIds = [];
  lastIncomingClickId = null;
  lastOutgoingClickId = null;
  editingMatchId = null;
  editingMatchOriginal = null;
  stashedSelection = null;
  setTrayNote("");
  traySnapshotRestored = false;

  clearLoadProgress();
  render();
}

// The expensive escape hatch: re-reads the org's entire history from HCB, for
// when an older transaction changed in a way the incremental drain keeps
// splicing back over. Confirmed first (see FULL_RELOAD_WARNING) because the
// cost lands on everyone using the app, not just whoever pressed it.
async function fullReloadTransactionsAndRender() {
  if (transactionsRefreshing) return;
  if (!confirm(FULL_RELOAD_WARNING)) return;

  transactionsRefreshing = true;
  setSyncButtonsDisabled(true);
  setSyncNote("full reload started…");

  let started = false;
  try {
    const changed = await fullReloadTransactions({
      onSyncing: () => {
        started = true;
        setSyncNote("re-reading full history from HCB — this can take a few minutes…");
        clearForFullReload();
      },
    });
    // Nothing was cleared and nothing is running: the request itself failed, so
    // the page is still showing the data it loaded with.
    if (!started) {
      setSyncNote("could not start the full reload — try again");
      return;
    }

    // Loaded from scratch either way. Giving up waiting isn't the same as the
    // drain failing -- it's still going server-side -- but the page has been
    // cleared by now, so it re-streams whatever the server currently has rather
    // than sitting empty until someone refreshes the browser.
    if (!(await loadAll())) {
      setSyncNote("full reload finished, but this page couldn't load it — reload the page");
      return;
    }
    setSyncNote(changed ? "full reload complete" : "still running — reload this page in a few minutes to see the result");
  } finally {
    restreamingFullReload = false;
    transactionsRefreshing = false;
    setSyncButtonsDisabled(false);
  }
}

function usedIds() {
  const used = new Set();
  for (const m of matches) {
    for (const iid of m.incoming_ids) used.add(iid);
    for (const oid of m.outgoing_ids) used.add(oid);
  }
  return used;
}

function unmatchedTransactions() {
  const used = usedIds();
  return allTransactions.filter((t) => !used.has(t.id));
}

function render() {
  renderStats();
  renderLists();
  renderTray();
  renderMatches();
  updateDownloadButtons();
  saveTraySnapshot();
}

function renderStats() {
  const unmatched = unmatchedTransactions();
  const incoming = unmatched.filter((t) => t.direction === "in");
  const outgoing = unmatched.filter((t) => t.direction === "out");
  const inSum = incoming.reduce((s, t) => s + t.amount, 0);
  const outSum = outgoing.reduce((s, t) => s + t.amount, 0);

  document.getElementById("stat-in-count").textContent = incoming.length;
  document.getElementById("stat-out-count").textContent = outgoing.length;
  document.getElementById("stat-in-sum").textContent = fmt(inSum);
  document.getElementById("stat-out-sum").textContent = fmt(outSum);
  document.getElementById("stat-net").textContent = fmt(inSum + outSum);
}

// A plain monochrome outline (not an emoji) so "clear all" renders as a
// small crisp glyph on every platform instead of a colorful system emoji.
const trashIconSvg = `<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><path d="M3 4h10M6 4V3a1 1 0 0 1 1-1h2a1 1 0 0 1 1 1v1M4 4l.6 9a1 1 0 0 0 1 .9h4.8a1 1 0 0 0 1-.9L12 4"/></svg>`;

function infoIconHtml(t) {
  return `<button type="button" class="info-icon" data-id="${escapeHtml(String(t.id))}" title="View full details">ⓘ</button>`;
}

// Transaction ids are HCB's public ids ("txn_<hashid>"), and HCB's own site
// resolves that same hashid at /hcb/<hashid> -- so no separate lookup is
// needed to link back to the real transaction. Manually-added transactions
// (negative numeric ids, see details.js's `isManual`) have no HCB code.
function hcbCode(t) {
  const id = String(t.id);
  return id.startsWith("txn_") ? id.slice(4) : null;
}

function hcbTransactionUrl(t) {
  const code = hcbCode(t);
  return code ? `https://hcb.hackclub.com/hcb/${code}` : null;
}

function HCBLinkHtml(t) {
  const url = hcbTransactionUrl(t);
  if (!url) return "";
  return `<a class="hcb-link" href="${escapeHtml(url)}" target="_blank" rel="noopener noreferrer" title="View on HCB">↗</a>`;
}

// A <button> rather than plain text: clicking the code copies it, so it needs
// to be reachable by keyboard and announced as an action. wireRowControls does
// the copying; legacy.css strips the default button chrome back to bare text.
function hcbCodeHtml(t) {
  const code = hcbCode(t);
  if (!code) return "";
  return `<button type="button" class="hcb-code" data-copy="${escapeHtml(code)}" title="Copy HCB code">${escapeHtml(code)}</button>`;
}

// Same as hcbCodeHtml but for single-line contexts (tray items, match rows)
// where a block-level line would break the layout.
function hcbCodeInlineHtml(t) {
  const code = hcbCode(t);
  if (!code) return "";
  return ` <button type="button" class="hcb-code hcb-code-inline" data-copy="${escapeHtml(code)}" title="Copy HCB code">${escapeHtml(code)}</button>`;
}

// Memo search boxes match either the memo text or the HCB code, so pasting
// in a code from HCB's own UI finds the transaction without having to know
// its memo. Checked both ways against the code: query-in-code for a partial
// code, and code-in-query so pasting the row's *full HCB URL* (which
// contains the code as a substring, not the other way around) still finds it.
function memoOrCodeMatches(t, query) {
  if (!query) return true;
  const code = hcbCode(t);
  return t.memo.toLowerCase().includes(query) || (!!code && (code.toLowerCase().includes(query) || query.includes(code.toLowerCase())));
}

function matchesRowHtml(t, extraClass) {
  const cls = t.direction + (extraClass ? " " + extraClass : "");
  // The greyed-out state is only half the story -- the row still looks
  // clickable, so say what clicking it does before anyone finds out.
  const rowTitle = (extraClass || "").split(" ").includes("matched")
    ? ` title="Already matched — click to jump to its match below"`
    : "";
  return `<div class="row ${cls}" data-id="${t.id}"${rowTitle}>
    <div class="date">${t.date}</div>
    <div class="memo" title="${escapeHtml(t.memo)}">
      <div class="memo-text">${escapeHtml(t.memo)}</div>
      ${hcbCodeHtml(t)}
    </div>
    <div class="amount">${fmt(t.amount)}</div>
    <div class="row-info">${infoIconHtml(t)}${HCBLinkHtml(t)}</div>
  </div>`;
}

function sortTransactions(list, sortValue) {
  const [field, dir] = sortValue.split("-");
  const mul = dir === "asc" ? 1 : -1;
  return [...list].sort((a, b) => {
    if (field === "amount") {
      return (Math.abs(a.amount) - Math.abs(b.amount)) * mul;
    }
    return (a.date < b.date ? -1 : a.date > b.date ? 1 : 0) * mul;
  });
}

function renderLists() {
  const used = usedIds();
  // Opt-in per direction: the panels are lists of work left to do, so matched
  // transactions stay out of them unless someone asks to search the matched
  // ones too (to find where a transaction ended up, most often to pull it back
  // out of the match it's in). They're listed greyed out and aren't selectable
  // -- see onIncomingClick/onOutgoingClick, which jump to the match instead.
  const showMatchedIncoming = document.getElementById("include-matched-incoming").checked;
  const showMatchedOutgoing = document.getElementById("include-matched-outgoing").checked;
  const incomingPool = showMatchedIncoming ? allTransactions : allTransactions.filter((t) => !used.has(t.id));
  const outgoingPool = showMatchedOutgoing ? allTransactions : allTransactions.filter((t) => !used.has(t.id));

  const incomingFilter = document.getElementById("search-incoming").value.trim().toLowerCase();
  const incomingAmountFilter = document.getElementById("search-incoming-amount").value;
  const incomingAfterFilter = document.getElementById("search-incoming-after").value;
  const incomingBeforeFilter = document.getElementById("search-incoming-before").value;
  const outgoingFilter = document.getElementById("search-outgoing").value.trim().toLowerCase();
  const outgoingAmountFilter = document.getElementById("search-outgoing-amount").value;
  const outgoingAfterFilter = document.getElementById("search-outgoing-after").value;
  const outgoingBeforeFilter = document.getElementById("search-outgoing-before").value;

  const incomingFiltered = incomingPool.filter(
    (t) =>
      t.direction === "in" &&
      memoOrCodeMatches(t, incomingFilter) &&
      amountMatches(t.amount, incomingAmountFilter) &&
      dateInRange(t.date, incomingAfterFilter, incomingBeforeFilter)
  );
  const incoming = sortTransactions(incomingFiltered, document.getElementById("sort-incoming").value);

  const outgoingFiltered = outgoingPool.filter(
    (t) =>
      t.direction === "out" &&
      memoOrCodeMatches(t, outgoingFilter) &&
      amountMatches(t.amount, outgoingAmountFilter) &&
      dateInRange(t.date, outgoingAfterFilter, outgoingBeforeFilter)
  );
  const outgoing = sortTransactions(outgoingFiltered, document.getElementById("sort-outgoing").value);

  // Matched rows are left out of the shift-click order: they're on screen, but
  // they can't be selected, so a range drawn across one shouldn't swallow it.
  currentIncomingOrder = incoming.filter((t) => !used.has(t.id)).map((t) => t.id);
  currentOutgoingOrder = outgoing.filter((t) => !used.has(t.id)).map((t) => t.id);

  // While the drain is still in progress (including mid-stream, before
  // transactionsLoaded flips true), an empty filtered list just means the
  // data hasn't arrived yet -- showing "Nothing unmatched" there would claim
  // the org has no unmatched transactions when it just hasn't loaded them.
  const emptyHtml = (showMatched) =>
    transactionsLoaded
      ? `<div class="empty-msg">${showMatched ? "Nothing to show." : "Nothing unmatched 🎉"}</div>`
      : LOADING_HTML;

  const rowClass = (t, selectedIds, selectedClass) =>
    used.has(t.id) ? "matched" : selectedIds.includes(t.id) ? selectedClass : "";

  const inList = document.getElementById("list-incoming");
  inList.innerHTML = incoming.length
    ? incoming.map((t) => matchesRowHtml(t, rowClass(t, selectedIncomingIds, "active"))).join("")
    : emptyHtml(showMatchedIncoming);

  const outList = document.getElementById("list-outgoing");
  outList.innerHTML = outgoing.length
    ? outgoing.map((t) => matchesRowHtml(t, rowClass(t, selectedOutgoingIds, "selected"))).join("")
    : emptyHtml(showMatchedOutgoing);

  inList.querySelectorAll(".row").forEach((el) => {
    el.addEventListener("click", (e) => onIncomingClick(el.dataset.id, e));
  });
  outList.querySelectorAll(".row").forEach((el) => {
    el.addEventListener("click", (e) => onOutgoingClick(el.dataset.id, e));
  });
  wireRowControls(inList);
  wireRowControls(outList);

  saveFilterSnapshot();
}

function rangeSelection(order, selected, anchorId, id) {
  const a = order.indexOf(anchorId);
  const b = order.indexOf(id);
  if (a === -1 || b === -1) return null;
  const [lo, hi] = a < b ? [a, b] : [b, a];
  const merged = [...selected];
  for (const rid of order.slice(lo, hi + 1)) {
    if (!merged.includes(rid)) merged.push(rid);
  }
  return merged;
}

// A matched transaction can't go into the tray -- it's already accounted for --
// so clicking its row takes you to the match it's part of instead, which is
// where it can be edited or undone. Returns whether the click belonged to a
// match at all: a matched row is never selectable, even in the corner where the
// match's own row hasn't been rendered yet and there's nothing to scroll to.
function jumpToMatchForTransaction(transactionId) {
  const matchId = matchIdForTransaction(transactionId);
  if (matchId === null) return false;
  const row = document.getElementById(`match-row-${matchId}`);
  if (!row) return true;

  // Smooth scrolling is what makes the jump legible (it shows you where you
  // went), but it's exactly the kind of motion prefers-reduced-motion is about,
  // so honour that and land there directly instead. The flash below stays
  // either way -- it's a colour change, not movement.
  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  row.scrollIntoView({ behavior: reduceMotion ? "auto" : "smooth", block: "center" });
  // Restarting the animation matters when the same match is clicked twice: the
  // page may not scroll at all the second time, so the flash is the only sign
  // the click did anything. Reading offsetWidth forces the reflow that makes
  // removing and re-adding the class count as two separate animations.
  row.classList.remove("match-row-flash");
  void row.offsetWidth;
  row.classList.add("match-row-flash");
  return true;
}

function onIncomingClick(id, e) {
  if (jumpToMatchForTransaction(id)) return;
  if (e && e.shiftKey && lastIncomingClickId !== null) {
    const merged = rangeSelection(currentIncomingOrder, selectedIncomingIds, lastIncomingClickId, id);
    if (merged) {
      selectedIncomingIds = merged;
      lastIncomingClickId = id;
      render();
      return;
    }
  }
  const idx = selectedIncomingIds.indexOf(id);
  if (idx >= 0) {
    selectedIncomingIds.splice(idx, 1);
  } else {
    selectedIncomingIds.push(id);
  }
  lastIncomingClickId = id;
  render();
}

function onOutgoingClick(id, e) {
  if (jumpToMatchForTransaction(id)) return;
  if (e && e.shiftKey && lastOutgoingClickId !== null) {
    const merged = rangeSelection(currentOutgoingOrder, selectedOutgoingIds, lastOutgoingClickId, id);
    if (merged) {
      selectedOutgoingIds = merged;
      lastOutgoingClickId = id;
      render();
      return;
    }
  }
  const idx = selectedOutgoingIds.indexOf(id);
  if (idx >= 0) {
    selectedOutgoingIds.splice(idx, 1);
  } else {
    selectedOutgoingIds.push(id);
  }
  lastOutgoingClickId = id;
  render();
}

function clearIncomingSelection() {
  selectedIncomingIds = [];
  lastIncomingClickId = null;
  render();
}

function clearOutgoingSelection() {
  selectedOutgoingIds = [];
  lastOutgoingClickId = null;
  render();
}

function renderTray() {
  const empty = document.getElementById("tray-empty");
  const body = document.getElementById("tray-body");

  if (selectedIncomingIds.length === 0 && selectedOutgoingIds.length === 0) {
    empty.classList.remove("hidden");
    body.classList.add("hidden");
    return;
  }
  empty.classList.add("hidden");
  body.classList.remove("hidden");

  document.getElementById("tray-editing-banner").classList.toggle("hidden", editingMatchId === null);

  const inList = document.getElementById("tray-incoming-list");
  if (selectedIncomingIds.length === 0) {
    inList.innerHTML = `<div class="empty-msg">Click incoming transactions on the left to add them here.</div>`;
  } else {
    const clearAllHtml = `<button type="button" class="tray-clear-all" id="clear-incoming-all" title="Clear all incoming" aria-label="Clear all incoming">${trashIconSvg}</button>`;
    inList.innerHTML = clearAllHtml + selectedIncomingIds.map((id) => {
      const t = byId.get(id);
      return `<div class="tray-incoming-item" data-id="${id}">
        <span class="tray-chip-memo"><span class="tray-chip-date">${t.date}</span> ${escapeHtml(t.memo)}${hcbCodeInlineHtml(t)}</span>
        <span class="tray-chip-icons">${infoIconHtml(t)}${HCBLinkHtml(t)}</span>
        <strong class="tray-chip-amount">${fmt(t.amount)}</strong>
        <span class="remove" data-remove-in="${id}">×</span>
      </div>`;
    }).join("");
    inList.querySelectorAll("[data-remove-in]").forEach((el) => {
      el.addEventListener("click", (e) => {
        e.stopPropagation();
        const id = el.dataset.removeIn;
        selectedIncomingIds = selectedIncomingIds.filter((x) => x !== id);
        render();
      });
    });
    document.getElementById("clear-incoming-all").addEventListener("click", clearIncomingSelection);
  }

  const outList = document.getElementById("tray-outgoing-list");
  if (selectedOutgoingIds.length === 0) {
    outList.innerHTML = `<div class="empty-msg">Click outgoing transactions on the right to add them here.</div>`;
  } else {
    const clearAllHtml = `<button type="button" class="tray-clear-all" id="clear-outgoing-all" title="Clear all outgoing" aria-label="Clear all outgoing">${trashIconSvg}</button>`;
    outList.innerHTML = clearAllHtml + selectedOutgoingIds.map((id) => {
      const t = byId.get(id);
      return `<div class="tray-outgoing-item" data-id="${id}">
        <span class="tray-chip-memo"><span class="tray-chip-date">${t.date}</span> ${escapeHtml(t.memo)}${hcbCodeInlineHtml(t)}</span>
        <span class="tray-chip-icons">${infoIconHtml(t)}${HCBLinkHtml(t)}</span>
        <span class="tray-chip-amount">${fmt(t.amount)}</span>
        <span class="remove" data-remove="${id}">×</span>
      </div>`;
    }).join("");
    outList.querySelectorAll("[data-remove]").forEach((el) => {
      el.addEventListener("click", (e) => {
        e.stopPropagation();
        const id = el.dataset.remove;
        selectedOutgoingIds = selectedOutgoingIds.filter((x) => x !== id);
        render();
      });
    });
    document.getElementById("clear-outgoing-all").addEventListener("click", clearOutgoingSelection);
  }

  wireRowControls(document.getElementById("tray-body"));

  const incomingAmount = selectedIncomingIds.reduce((s, id) => s + byId.get(id).amount, 0);
  const outSum = selectedOutgoingIds.reduce((s, id) => s + byId.get(id).amount, 0);
  const diff = round2(incomingAmount + outSum);

  document.getElementById("tray-in-amt").textContent = fmt(incomingAmount);
  document.getElementById("tray-out-amt").textContent = fmt(outSum);
  const diffRow = document.getElementById("tray-diff-row");
  document.getElementById("tray-diff").textContent = fmt(diff);
  diffRow.classList.toggle("balanced", diff === 0);
  diffRow.classList.toggle("unbalanced", diff !== 0);

  const confirmBtn = document.getElementById("btn-confirm");
  confirmBtn.disabled = matchBusy || (selectedIncomingIds.length === 0 && selectedOutgoingIds.length === 0);
  const matchLabel = diff === 0 && selectedIncomingIds.length && selectedOutgoingIds.length ? "match" : "as discrepancy";
  confirmBtn.textContent = matchBusy
    ? "Saving…"
    : editingMatchId !== null ? `Save changes (${matchLabel})` : `Confirm ${matchLabel}`;
  document.getElementById("btn-cancel").textContent = editingMatchId !== null ? "Cancel edit" : "Cancel";
  document.getElementById("btn-cancel").disabled = matchBusy;
}

function round2(n) {
  return Math.round(n * 100) / 100;
}

function resetSearchFields() {
  [
    "search-incoming", "search-incoming-amount", "search-incoming-after", "search-incoming-before",
    "search-outgoing", "search-outgoing-amount", "search-outgoing-after", "search-outgoing-before",
  ].forEach((id) => {
    const input = document.getElementById(id);
    input.value = "";
    input.dispatchEvent(new Event("input"));
  });
}

function restoreStashedSelection() {
  selectedIncomingIds = stashedSelection ? stashedSelection.incomingIds : [];
  selectedOutgoingIds = stashedSelection ? stashedSelection.outgoingIds : [];
  stashedSelection = null;
}

async function confirmMatch() {
  if (matchBusy) return;
  if (selectedIncomingIds.length === 0 && selectedOutgoingIds.length === 0) return;
  const isEdit = editingMatchId !== null;
  matchBusy = true;
  render();
  try {
    const res = await fetch(`${API_BASE}/api/matches${isEdit ? "/" + editingMatchId : ""}`, {
      method: isEdit ? "PATCH" : "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        incoming_ids: selectedIncomingIds,
        outgoing_ids: selectedOutgoingIds,
        note: trayNote(),
      }),
    });
    if (!res.ok) {
      const err = await res.json();
      if (res.status === 409) {
        alert(err.error || "Someone else just matched one of these transactions. Refreshing the lists.");
        selectedIncomingIds = [];
        selectedOutgoingIds = [];
        lastIncomingClickId = null;
        lastOutgoingClickId = null;
        editingMatchId = null;
        editingMatchOriginal = null;
        stashedSelection = null;
        setTrayNote("");
        await loadAll();
        return;
      }
      alert(`Could not save ${isEdit ? "changes" : "match"}: ` + err.error);
      return;
    }
    // The server returns the full serialized match -- splice it straight into
    // local state and re-render instead of a full loadAll(), which would
    // re-drain and re-render the entire (often multi-thousand-row) transaction
    // history just to reflect one new/updated match.
    const savedMatch = await res.json();
    matches.push(savedMatch);
    editingMatchId = null;
    editingMatchOriginal = null;
    setTrayNote("");
    restoreStashedSelection();
    lastIncomingClickId = null;
    lastOutgoingClickId = null;
    if (!isEdit) resetSearchFields();
  } finally {
    matchBusy = false;
    render();
  }
}

function editMatch(id) {
  if (matchBusy || editingMatchId !== null) return;
  const m = matches.find((x) => x.id === id);
  if (!m) return;

  stashedSelection = selectedIncomingIds.length || selectedOutgoingIds.length
    ? { incomingIds: [...selectedIncomingIds], outgoingIds: [...selectedOutgoingIds] }
    : null;

  editingMatchId = id;
  editingMatchOriginal = m;
  matches = matches.filter((x) => x.id !== id);
  // The note as it stands, so saving an edit keeps it rather than clearing it
  // by omission -- and so it can be rewritten alongside the legs it explains.
  setTrayNote(m.note);

  selectedIncomingIds = [...m.incoming_ids];
  selectedOutgoingIds = [...m.outgoing_ids];
  lastIncomingClickId = null;
  lastOutgoingClickId = null;

  render();
}

function cancelMatch() {
  if (matchBusy) return;
  if (editingMatchId !== null) {
    matches.push(editingMatchOriginal);
    editingMatchId = null;
    editingMatchOriginal = null;
  }
  setTrayNote("");
  restoreStashedSelection();
  lastIncomingClickId = null;
  lastOutgoingClickId = null;
  render();
}

async function deleteMatch(id) {
  if (!confirm("Undo this match?")) return;
  const res = await fetch(`${API_BASE}/api/matches/${id}`, { method: "DELETE" });
  if (!res.ok) {
    const err = await res.json();
    alert("Could not delete match: " + err.error);
    return;
  }
  // Undoing a match doesn't change any transaction's data, just removes the
  // link -- drop it from local state and re-render rather than a full
  // loadAll() re-drain.
  matches = matches.filter((m) => m.id !== id);
  render();
}

// The match popup (see match_detail.js) can change a match while it's open
// over this page -- someone writes a note on it. It saves against the same API
// this page does, so rather than re-fetching the list, take the match it
// already saved and put it where this page keeps its copy.
document.addEventListener("match:updated", (e) => {
  const updated = e.detail;
  // The match being edited isn't in `matches` at all; its legs are sitting in
  // the tray, and its saved form is held aside for the cancel path.
  if (editingMatchOriginal && editingMatchOriginal.id === updated.id) {
    editingMatchOriginal = { ...editingMatchOriginal, ...updated };
    return;
  }
  const i = matches.findIndex((m) => m.id === updated.id);
  if (i === -1) return;

  matches[i] = { ...matches[i], ...updated };
  render();
});

// When a match last changed hands: the last edit, or the moment it was made
// if nobody has touched it since. The sort key for both match sections and
// their exports -- what someone is looking for after coming back to the page
// is whatever moved most recently, not whatever happens to have the highest id.
// Parsed rather than string-compared: these are ISO timestamps from two
// different sources (the match row and its history), and lexicographic order
// only holds if they're always written in the same timezone offset.
function matchTouchedAtMs(m) {
  const t = Date.parse(m.last_edited_at || m.created_at || "");
  return Number.isNaN(t) ? 0 : t;
}

// Most recently touched first, id (i.e. creation order) breaking ties -- which
// is what an org whose matches were all imported with the same timestamp gets.
function byRecentlyTouched(a, b) {
  return matchTouchedAtMs(b) - matchTouchedAtMs(a) || b.id - a.id;
}

// Who made the match and, when someone has since changed it, who that was and
// when. Kept to one line: the row's job is the two sides and what they're off
// by, and the full story (with times of day and what each change did) is one
// click away in the detail popup, which is also what the tooltip here shows.
function matchMetaHtml(m) {
  if (!m.created_by_name) return "";
  const when = m.created_at ? new Date(m.created_at).toLocaleDateString() : "";
  const editedWhen = m.last_edited_at ? " on " + new Date(m.last_edited_at).toLocaleDateString() : "";
  const edited = m.edited && m.last_edited_by_name
    ? ` <span class="match-meta-edited" title="Last edited ${escapeHtml(new Date(m.last_edited_at).toLocaleString())}">· edited by ${escapeHtml(m.last_edited_by_name)}${editedWhen}</span>`
    : "";
  return `<div class="match-meta">Matched by ${escapeHtml(m.created_by_name)}${when ? " on " + when : ""}${edited}</div>`;
}

// The match a transaction belongs to, for the transaction modal's "View match"
// button (see details.js). Read straight off the match list this page already
// holds -- a match being edited is deliberately not in it, since its legs are
// sitting unsaved in the tray rather than in a match anyone can open.
function matchIdForTransaction(transactionId) {
  const m = matches.find((x) => x.incoming_ids.includes(transactionId) || x.outgoing_ids.includes(transactionId));
  return m ? m.id : null;
}

function conflictBadgeHtml(m) {
  if (!m.conflict) return "";
  return `<div class="conflict-badge" title="This match has legs on both sides of the current cutoff — one side is hidden, the other visible.">⚠ Spans cutoff</div>`;
}

function matchRowHtml(m) {
  const incoming = m.incoming_ids.map((id) => byId.get(id)).filter(Boolean);
  const outgoing = m.outgoing_ids.map((id) => byId.get(id)).filter(Boolean);
  const discClass = m.discrepancy === 0 ? "discrepancy-ok" : "discrepancy-bad";
  const discText = m.discrepancy === 0 ? "balanced" : `off by ${fmt(m.discrepancy)}`;
  const sideIn = incoming.length
    ? incoming.map((t) => `<div>${t.date} — ${escapeHtml(t.memo)}${hcbCodeInlineHtml(t)}${infoIconHtml(t)}${HCBLinkHtml(t)} — <strong>${fmt(t.amount)}</strong></div>`).join("")
    : `<span class="side-empty">No incoming</span>`;
  const sideOut = outgoing.length
    ? outgoing.map((t) => `<div>${t.date} — ${escapeHtml(t.memo)}${hcbCodeInlineHtml(t)}${infoIconHtml(t)}${HCBLinkHtml(t)} — ${fmt(t.amount)}</div>`).join("")
    : `<span class="side-empty">No outgoing</span>`;
  // Editing pulls a match out of `matches` (and into the tray) entirely, so
  // this row is never rendered for the match currently being edited -- the
  // disabled state here only guards *other* rows against starting a second
  // edit (or being undone) while one is already in progress. View is exempt:
  // reading a match changes nothing, so there's nothing to guard.
  const otherRowDisabled = editingMatchId !== null ? "disabled" : "";
  // Addressable so a click on a greyed-out matched row in the panels above can
  // scroll straight to it -- see jumpToMatchForTransaction.
  return `<div class="match-row${m.conflict ? " match-row-conflict" : ""}" id="match-row-${m.id}">
    <div class="side-in">${sideIn}</div>
    <div class="side-out">${sideOut}</div>
    <div class="${discClass}">${discText}${conflictBadgeHtml(m)}${matchMetaHtml(m)}</div>
    <div class="match-row-actions">
      <button class="secondary" data-view="${m.id}" title="Open this match — full details, and who changed what">View</button>
      <button class="secondary" data-edit="${m.id}" ${otherRowDisabled}>Edit</button>
      <button class="danger" data-delete="${m.id}" ${otherRowDisabled}>Undo</button>
    </div>
  </div>`;
}

function renderMatchGroup(group, listId, countId, emptyMsg) {
  document.getElementById(countId).textContent = group.length;
  const list = document.getElementById(listId);

  if (group.length === 0) {
    list.innerHTML = `<div class="empty-msg">${emptyMsg}</div>`;
    return;
  }

  const sorted = [...group].sort(byRecentlyTouched);
  list.innerHTML = sorted.map(matchRowHtml).join("");

  list.querySelectorAll("[data-view]").forEach((el) => {
    el.addEventListener("click", () => showMatchModal(el.dataset.view));
  });
  list.querySelectorAll("[data-edit]").forEach((el) => {
    el.addEventListener("click", () => editMatch(Number(el.dataset.edit)));
  });
  list.querySelectorAll("[data-delete]").forEach((el) => {
    el.addEventListener("click", () => deleteMatch(Number(el.dataset.delete)));
  });
  wireRowControls(list);
}

function renderMatches() {
  // Every match row is drawn from byId -- its legs *are* transactions -- so
  // before any of them have arrived there's nothing truthful to show: rows
  // would render with both sides empty, and the empty state would claim the
  // organization has no matches. Both say "loading" instead. On a normal load
  // that's a blink; through a full reload's drain it's minutes.
  if (!transactionsLoaded && allTransactions.length === 0) {
    for (const id of ["matches-unbalanced-count", "matches-balanced-count"]) {
      document.getElementById(id).textContent = "—";
    }
    for (const id of ["matches-unbalanced-list", "matches-balanced-list"]) {
      document.getElementById(id).innerHTML = LOADING_HTML;
    }
    return;
  }

  renderMatchGroup(unbalancedMatches(), "matches-unbalanced-list", "matches-unbalanced-count", "No discrepancies 🎉");
  renderMatchGroup(balancedMatches(), "matches-balanced-list", "matches-balanced-count", "No balanced matches yet.");
}

// The two buckets the page splits matches into, shared by the sections that
// render them and the buttons that export them, so a match can't be counted as
// balanced on screen and unbalanced in a downloaded file. A match being edited
// is in neither: editMatch pulls it out of `matches` entirely while it sits in
// the tray, unsaved.
function balancedMatches() {
  return matches.filter((m) => m.discrepancy === 0);
}

function unbalancedMatches() {
  return matches.filter((m) => m.discrepancy !== 0);
}

// The match-level columns each of a match's legs repeats in the CSV; the leg's
// own columns (shared with the transaction exports) follow them. See csv.js.
const MATCH_CSV_COLUMNS = [
  ["Match ID", (m) => m.id],
  ["Discrepancy", (m) => m.discrepancy],
  ["Spans cutoff", (m) => (m.conflict ? "yes" : "")],
  ["Matched by", (m) => m.created_by_name],
  ["Matched at", (m) => m.created_at],
  // The file is ordered by when each match was last touched, so it carries the
  // column it's sorted on -- otherwise the order reads as arbitrary to anyone
  // opening it in a spreadsheet. Empty for a match nobody has edited.
  ["Last edited by", (m) => m.last_edited_by_name],
  ["Last edited at", (m) => m.last_edited_at],
  ["Note", (m) => m.note],
];

// One row per leg with the match's own values repeated on each, rather than one
// row per match with its legs crammed into a cell -- the shape a spreadsheet can
// group, filter and sum without anyone having to split text first.
function matchCsvRows(m) {
  const legRow = (id, side) => [
    ...MATCH_CSV_COLUMNS.map(([, read]) => read(m)),
    side,
    // A leg whose transaction isn't loaded (most likely because someone moved
    // the cutoff past it) still gets a row carrying its id: dropping it would
    // leave the match's legs not adding up to the discrepancy beside them, with
    // nothing in the file to say why.
    ...transactionCsvCells(byId.get(id) || { id, memo: "(transaction not loaded)" }),
  ];

  return [
    ...m.incoming_ids.map((id) => legRow(id, "incoming")),
    ...m.outgoing_ids.map((id) => legRow(id, "outgoing")),
  ];
}

// Every unmatched transaction in that direction -- deliberately the whole set,
// not just what the search/date filters happen to leave on screen (which is
// what the button's title says). Ordered by the panel's own sort control, so the
// file reads in the order the panel it came from does.
function downloadUnmatchedCsv(direction) {
  const rows = sortTransactions(
    unmatchedTransactions().filter((t) => t.direction === direction),
    document.getElementById(direction === "in" ? "sort-incoming" : "sort-outgoing").value
  );

  downloadCsv(
    csvBasename(direction === "in" ? "unmatched-incoming" : "unmatched-outgoing"),
    TRANSACTION_CSV_HEADERS,
    rows.map((t) => transactionCsvCells(t))
  );
}

// Most recently touched first, the same order the sections below the panels
// list them in.
function downloadMatchesCsv(kind) {
  const group = kind === "balanced" ? balancedMatches() : unbalancedMatches();
  const sorted = [...group].sort(byRecentlyTouched);

  downloadCsv(
    csvBasename(kind === "balanced" ? "balanced-matches" : "unbalanced-matches"),
    [...MATCH_CSV_COLUMNS.map(([header]) => header), "Side", ...TRANSACTION_CSV_HEADERS],
    sorted.flatMap(matchCsvRows)
  );
}

// Each button is live only once there's something behind it to export. Mid-drain
// that's never (a file saved then is a snapshot of a half-loaded page, with
// nothing in it to say so), and an empty group would download headers with no
// rows -- which reads as a broken button rather than as an answer.
function updateDownloadButtons() {
  const unmatched = transactionsLoaded ? unmatchedTransactions() : [];
  const enabled = {
    "btn-download-unmatched-in": unmatched.some((t) => t.direction === "in"),
    "btn-download-unmatched-out": unmatched.some((t) => t.direction === "out"),
    "btn-download-balanced": transactionsLoaded && balancedMatches().length > 0,
    "btn-download-unbalanced": transactionsLoaded && unbalancedMatches().length > 0,
  };
  for (const [id, on] of Object.entries(enabled)) {
    document.getElementById(id).disabled = !on;
  }
}

let matchesRefreshing = false;

// Re-fetches just /api/matches (a single fast query) and re-renders -- unlike
// loadAll(), it doesn't touch allTransactions, so it doesn't re-drain the full
// (often multi-thousand-row) HCB transaction history just to pick up matches a
// collaborator created or undid while this tab was open. That response is also
// where a match whose discrepancy the server re-derived (see Matches::Resync)
// arrives with its corrected value, which is why details.js calls this after a
// refresh moves a matched transaction's amount.
//
// Never throws: callers that aren't a button have nothing useful to do with a
// failure beyond leaving the page as it was.
async function reloadMatches() {
  try {
    const res = await fetch(`${API_BASE}/api/matches`);
    if (!res.ok) throw new Error("bad response");
    const data = await res.json();
    // A match being edited was pulled out of `matches` on purpose (its legs
    // show as selectable while it's in the tray) -- same reasoning as
    // reloadInPlace().
    matches = editingMatchId === null ? data.matches : data.matches.filter((m) => m.id !== editingMatchId);
    render();
    return true;
  } catch (e) {
    return false;
  }
}

async function refreshMatches() {
  if (matchesRefreshing) return;
  matchesRefreshing = true;
  const btn = document.getElementById("btn-refresh-matches");
  btn.disabled = true;
  try {
    if (!(await reloadMatches())) alert("Could not refresh matches. Please try again.");
  } finally {
    matchesRefreshing = false;
    btn.disabled = false;
  }
}

function cutoffOptionLabel(o) {
  return o.beginning ? "Beginning of history (show everything)" : o.date;
}

function renderCutoffSelect() {
  const select = document.getElementById("cutoff-select");
  select.innerHTML = zeroBalanceOptions
    .map((o) => `<option value="${o.transaction_id}"${o.transaction_id === zeroBalanceSelectedId ? " selected" : ""}>${escapeHtml(cutoffOptionLabel(o))}</option>`)
    .join("");
}

function cutoffConflictItemHtml(m) {
  const sideIn = m.incoming.length
    ? m.incoming.map((t) => `<div>${t.date} — ${escapeHtml(t.memo)} — <strong>${fmt(t.amount)}</strong></div>`).join("")
    : `<span class="side-empty">No incoming</span>`;
  const sideOut = m.outgoing.length
    ? m.outgoing.map((t) => `<div>${t.date} — ${escapeHtml(t.memo)} — ${fmt(t.amount)}</div>`).join("")
    : `<span class="side-empty">No outgoing</span>`;
  return `<div class="cutoff-conflict-item">
    <div class="side-in">${sideIn}</div>
    <div class="side-out">${sideOut}</div>
  </div>`;
}

function showCutoffConflictModal(transactionId, conflicts) {
  pendingCutoffId = transactionId;
  document.getElementById("cutoff-modal-count").textContent = conflicts.length;
  document.getElementById("cutoff-modal-list").innerHTML = conflicts.map(cutoffConflictItemHtml).join("");
  document.getElementById("cutoff-modal-overlay").classList.remove("hidden");
}

let cutoffBusy = false;

// Held for the whole operation, including the post-success reload -- not
// just the PATCH -- so a second change can't race the first, and so Cancel
// can't wave through a request that's already been sent to the server.
function setCutoffBusy(busy) {
  cutoffBusy = busy;
  document.getElementById("cutoff-select").disabled = busy;
  document.getElementById("cutoff-modal-confirm").disabled = busy;
  document.getElementById("cutoff-modal-cancel").disabled = busy;
  document.getElementById("cutoff-modal-close").disabled = busy;
}

function hideCutoffModal() {
  if (cutoffBusy) return;
  pendingCutoffId = null;
  document.getElementById("cutoff-modal-overlay").classList.add("hidden");
  renderCutoffSelect();
}

async function changeCutoff(transactionId, confirmRemoval) {
  if (cutoffBusy) return;
  setCutoffBusy(true);
  try {
    const res = await fetch(`${API_BASE}/api/cutoff`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ transaction_id: transactionId, confirm: confirmRemoval }),
    });

    if (res.ok) {
      document.getElementById("cutoff-modal-overlay").classList.add("hidden");
      pendingCutoffId = null;
      await loadAll();
      return;
    }

    const err = await res.json();
    if (res.status === 409 && Array.isArray(err.conflicts)) {
      showCutoffConflictModal(transactionId, err.conflicts);
      return;
    }

    alert("Could not change cutoff: " + (err.error || "unknown error"));
    renderCutoffSelect();
  } finally {
    setCutoffBusy(false);
  }
}

document.getElementById("cutoff-select").addEventListener("change", (e) => {
  changeCutoff(e.target.value, false);
});
document.getElementById("cutoff-modal-confirm").addEventListener("click", () => {
  if (pendingCutoffId) changeCutoff(pendingCutoffId, true);
});
document.getElementById("cutoff-modal-cancel").addEventListener("click", hideCutoffModal);
document.getElementById("cutoff-modal-close").addEventListener("click", hideCutoffModal);
document.getElementById("cutoff-modal-overlay").addEventListener("click", (e) => {
  if (e.target.id === "cutoff-modal-overlay") hideCutoffModal();
});

document.getElementById("btn-confirm").addEventListener("click", confirmMatch);
// Typed text is part of the unsaved tray, so it goes to disk with the rest of
// it rather than only when something else happens to re-render the page.
document.getElementById("tray-note").addEventListener("input", saveTraySnapshot);
document.getElementById("btn-cancel").addEventListener("click", cancelMatch);
document.getElementById("btn-refresh-matches").addEventListener("click", refreshMatches);
document.getElementById("btn-refresh-transactions").addEventListener("click", () => refreshTransactions({ announce: true }));
document.getElementById("btn-full-reload").addEventListener("click", fullReloadTransactionsAndRender);
document.getElementById("btn-download-unmatched-in").addEventListener("click", () => downloadUnmatchedCsv("in"));
document.getElementById("btn-download-unmatched-out").addEventListener("click", () => downloadUnmatchedCsv("out"));
document.getElementById("btn-download-balanced").addEventListener("click", () => downloadMatchesCsv("balanced"));
document.getElementById("btn-download-unbalanced").addEventListener("click", () => downloadMatchesCsv("unbalanced"));
// Search/amount/date fields fire on every keystroke -- without debouncing,
// each one rebuilds both full row lists (and re-renders every visible row)
// once per character typed. Sort selects fire once per choice, so those stay
// on the immediate handler.
function debounce(fn, wait) {
  let timer;
  return (...args) => {
    clearTimeout(timer);
    timer = setTimeout(() => fn(...args), wait);
  };
}

const debouncedRenderLists = debounce(renderLists, 150);

document.getElementById("search-incoming").addEventListener("input", debouncedRenderLists);
document.getElementById("search-incoming-amount").addEventListener("input", debouncedRenderLists);
document.getElementById("search-incoming-after").addEventListener("input", debouncedRenderLists);
document.getElementById("search-incoming-before").addEventListener("input", debouncedRenderLists);
document.getElementById("search-outgoing").addEventListener("input", debouncedRenderLists);
document.getElementById("search-outgoing-amount").addEventListener("input", debouncedRenderLists);
document.getElementById("search-outgoing-after").addEventListener("input", debouncedRenderLists);
document.getElementById("search-outgoing-before").addEventListener("input", debouncedRenderLists);
document.getElementById("sort-incoming").addEventListener("change", renderLists);
document.getElementById("sort-outgoing").addEventListener("change", renderLists);
// Like the sort selects, one change per click -- no debouncing needed.
for (const id of FILTER_CHECKBOX_IDS) {
  document.getElementById(id).addEventListener("change", renderLists);
}


const TRAY_WIDTH_STORAGE_KEY = "steelyard.trayWidth";
const TRAY_WIDTH_MIN = 300;
const TRAY_WIDTH_MAX = 600;

function applyTrayWidth(px) {
  document.querySelector("main").style.setProperty("--tray-width", `${px}px`);
}

function wireColumnResizer(handle, side) {
  handle.addEventListener("pointerdown", (e) => {
    if (window.matchMedia("(max-width: 1100px)").matches) return;
    e.preventDefault();

    const startX = e.clientX;
    const startWidth = document.getElementById("panel-tray").getBoundingClientRect().width;
    handle.classList.add("dragging");
    handle.setPointerCapture(e.pointerId);

    function onMove(ev) {
      const delta = ev.clientX - startX;
      const signedDelta = side === "left" ? -delta : delta;
      applyTrayWidth(Math.min(TRAY_WIDTH_MAX, Math.max(TRAY_WIDTH_MIN, startWidth + signedDelta)));
    }

    function onUp() {
      handle.classList.remove("dragging");
      handle.releasePointerCapture(e.pointerId);
      document.removeEventListener("pointermove", onMove);
      document.removeEventListener("pointerup", onUp);
      const finalWidth = document.getElementById("panel-tray").getBoundingClientRect().width;
      localStorage.setItem(TRAY_WIDTH_STORAGE_KEY, Math.round(finalWidth));
    }

    document.addEventListener("pointermove", onMove);
    document.addEventListener("pointerup", onUp);
  });
}

const storedTrayWidth = parseInt(localStorage.getItem(TRAY_WIDTH_STORAGE_KEY), 10);
if (!Number.isNaN(storedTrayWidth)) {
  applyTrayWidth(Math.min(TRAY_WIDTH_MAX, Math.max(TRAY_WIDTH_MIN, storedTrayWidth)));
}
wireColumnResizer(document.getElementById("resizer-left"), "left");
wireColumnResizer(document.getElementById("resizer-right"), "right");

restoreFilterSnapshot();
// Every load ends with a check for HCB activity that landed since whatever
// cache (client-side rows, server-side drain) served this page -- otherwise a
// transaction made minutes ago stays invisible for the rest of the drain's TTL
// no matter how many times someone reloads. Not awaited: the page is already
// rendered and usable by then, and the check quietly folds anything it finds in
// on top.
loadAll().then(() => refreshTransactions({ announce: false }));
