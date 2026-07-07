const API_BASE = `/organizations/${window.HCB_ORGANIZATION_ID}`;

let allTransactions = [];
let matches = [];
let byId = new Map();

let zeroBalanceOptions = [];
let zeroBalanceSelectedId = null;
let pendingCutoffId = null;

let selectedIncomingIds = [];
let selectedOutgoingIds = [];

let currentIncomingOrder = [];
let currentOutgoingOrder = [];
let lastIncomingClickId = null;
let lastOutgoingClickId = null;
let matchBusy = false;

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
      byId = new Map(allTransactions.map((t) => [t.id, t]));
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
    return;
  }
  clearLoadProgress();
  allTransactions = txData.transactions;
  byId = new Map(allTransactions.map((t) => [t.id, t]));
  matches = matchData.matches;

  zeroBalanceOptions = txData.zero_balance_options || [];
  zeroBalanceSelectedId = txData.zero_balance_selected_id || null;
  renderCutoffSelect();

  render();
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

function infoIconHtml(t) {
  return `<button type="button" class="info-icon" data-detail="${escapeHtml(JSON.stringify(t))}" title="View full details">ⓘ</button>`;
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

function hcbCodeHtml(t) {
  const code = hcbCode(t);
  return code ? `<div class="hcb-code" title="HCB code">${escapeHtml(code)}</div>` : "";
}

// Same as hcbCodeHtml but for single-line contexts (tray items, match rows)
// where a block-level line would break the layout.
function hcbCodeInlineHtml(t) {
  const code = hcbCode(t);
  return code ? ` <span class="hcb-code hcb-code-inline" title="HCB code">${escapeHtml(code)}</span>` : "";
}

// Memo search boxes match either the memo text or the HCB code, so pasting
// in a code from HCB's own UI finds the transaction without having to know
// its memo.
function memoOrCodeMatches(t, query) {
  if (!query) return true;
  const code = hcbCode(t);
  return t.memo.toLowerCase().includes(query) || (!!code && code.toLowerCase().includes(query));
}

function matchesRowHtml(t, extraClass) {
  const cls = t.direction + (extraClass ? " " + extraClass : "");
  return `<div class="row ${cls}" data-id="${t.id}">
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
  const unmatched = unmatchedTransactions();
  const incomingFilter = document.getElementById("search-incoming").value.toLowerCase();
  const incomingAmountFilter = document.getElementById("search-incoming-amount").value;
  const incomingAfterFilter = document.getElementById("search-incoming-after").value;
  const incomingBeforeFilter = document.getElementById("search-incoming-before").value;
  const outgoingFilter = document.getElementById("search-outgoing").value.toLowerCase();
  const outgoingAmountFilter = document.getElementById("search-outgoing-amount").value;
  const outgoingAfterFilter = document.getElementById("search-outgoing-after").value;
  const outgoingBeforeFilter = document.getElementById("search-outgoing-before").value;

  const incomingFiltered = unmatched.filter(
    (t) =>
      t.direction === "in" &&
      memoOrCodeMatches(t, incomingFilter) &&
      amountMatches(t.amount, incomingAmountFilter) &&
      dateInRange(t.date, incomingAfterFilter, incomingBeforeFilter)
  );
  const incoming = sortTransactions(incomingFiltered, document.getElementById("sort-incoming").value);

  const outgoingFiltered = unmatched.filter(
    (t) =>
      t.direction === "out" &&
      memoOrCodeMatches(t, outgoingFilter) &&
      amountMatches(t.amount, outgoingAmountFilter) &&
      dateInRange(t.date, outgoingAfterFilter, outgoingBeforeFilter)
  );
  const outgoing = sortTransactions(outgoingFiltered, document.getElementById("sort-outgoing").value);

  currentIncomingOrder = incoming.map((t) => t.id);
  currentOutgoingOrder = outgoing.map((t) => t.id);

  const inList = document.getElementById("list-incoming");
  inList.innerHTML = incoming.length
    ? incoming.map((t) => matchesRowHtml(t, selectedIncomingIds.includes(t.id) ? "active" : "")).join("")
    : `<div class="empty-msg">Nothing unmatched 🎉</div>`;

  const outList = document.getElementById("list-outgoing");
  outList.innerHTML = outgoing.length
    ? outgoing.map((t) => matchesRowHtml(t, selectedOutgoingIds.includes(t.id) ? "selected" : "")).join("")
    : `<div class="empty-msg">Nothing unmatched 🎉</div>`;

  inList.querySelectorAll(".row").forEach((el) => {
    el.addEventListener("click", (e) => onIncomingClick(el.dataset.id, e));
  });
  outList.querySelectorAll(".row").forEach((el) => {
    el.addEventListener("click", (e) => onOutgoingClick(el.dataset.id, e));
  });
  wireDetailButtons(inList);
  wireDetailButtons(outList);
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

function onIncomingClick(id, e) {
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

  const inList = document.getElementById("tray-incoming-list");
  if (selectedIncomingIds.length === 0) {
    inList.innerHTML = `<div class="empty-msg">Click incoming transactions on the left to add them here.</div>`;
  } else {
    const clearAllHtml = `<div class="tray-list-header"><button type="button" class="tray-clear-all" id="clear-incoming-all">Clear all</button></div>`;
    inList.innerHTML = clearAllHtml + selectedIncomingIds.map((id) => {
      const t = byId.get(id);
      return `<div class="tray-incoming-item" data-id="${id}">
        <span>${t.date} — ${escapeHtml(t.memo)}${hcbCodeInlineHtml(t)}${infoIconHtml(t)}${HCBLinkHtml(t)} — <strong>${fmt(t.amount)}</strong></span>
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
    const clearAllHtml = `<div class="tray-list-header"><button type="button" class="tray-clear-all" id="clear-outgoing-all">Clear all</button></div>`;
    outList.innerHTML = clearAllHtml + selectedOutgoingIds.map((id) => {
      const t = byId.get(id);
      return `<div class="tray-outgoing-item" data-id="${id}">
        <span>${t.date} — ${escapeHtml(t.memo)}${hcbCodeInlineHtml(t)}${infoIconHtml(t)}${HCBLinkHtml(t)} — ${fmt(t.amount)}</span>
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

  wireDetailButtons(document.getElementById("tray-body"));

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
  confirmBtn.textContent = matchBusy
    ? "Saving…"
    : diff === 0 && selectedIncomingIds.length && selectedOutgoingIds.length ? "Confirm match" : "Confirm as discrepancy";
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

async function confirmMatch() {
  if (matchBusy) return;
  if (selectedIncomingIds.length === 0 && selectedOutgoingIds.length === 0) return;
  matchBusy = true;
  render();
  try {
    const res = await fetch(`${API_BASE}/api/matches`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        incoming_ids: selectedIncomingIds,
        outgoing_ids: selectedOutgoingIds,
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
        await loadAll();
        return;
      }
      alert("Could not save match: " + err.error);
      return;
    }
    // The server returns the full serialized match -- splice it straight into
    // local state and re-render instead of a full loadAll(), which would
    // re-drain and re-render the entire (often multi-thousand-row) transaction
    // history just to reflect one new match.
    const newMatch = await res.json();
    matches.push(newMatch);
    selectedIncomingIds = [];
    selectedOutgoingIds = [];
    lastIncomingClickId = null;
    lastOutgoingClickId = null;
    resetSearchFields();
  } finally {
    matchBusy = false;
    render();
  }
}

function cancelMatch() {
  if (matchBusy) return;
  selectedIncomingIds = [];
  selectedOutgoingIds = [];
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

function matchMetaHtml(m) {
  if (!m.created_by_name) return "";
  const when = m.created_at ? new Date(m.created_at).toLocaleDateString() : "";
  return `<div class="match-meta">Matched by ${escapeHtml(m.created_by_name)}${when ? " on " + when : ""}</div>`;
}

function conflictBadgeHtml(m) {
  if (!m.conflict) return "";
  return `<div class="conflict-badge" title="This match has legs on both sides of the current cutoff — one side is hidden, the other visible.">⚠ Spans cutoff</div>`;
}

function matchRowHtml(m) {
  const incoming = m.incoming_ids.map((id) => byId.get(id)).filter(Boolean);
  const outgoing = m.outgoing_ids.map((id) => byId.get(id)).filter(Boolean);
  const discClass = m.discrepancy === 0 ? "discrepancy-ok" : "discrepancy-bad";
  const discText = m.discrepancy === 0 ? "balanced" : `off by ${fmt(Math.abs(m.discrepancy))}`;
  const sideIn = incoming.length
    ? incoming.map((t) => `<div>${t.date} — ${escapeHtml(t.memo)}${hcbCodeInlineHtml(t)}${infoIconHtml(t)}${HCBLinkHtml(t)} — <strong>${fmt(t.amount)}</strong></div>`).join("")
    : `<span class="side-empty">No incoming</span>`;
  const sideOut = outgoing.length
    ? outgoing.map((t) => `<div>${t.date} — ${escapeHtml(t.memo)}${hcbCodeInlineHtml(t)}${infoIconHtml(t)}${HCBLinkHtml(t)} — ${fmt(t.amount)}</div>`).join("")
    : `<span class="side-empty">No outgoing</span>`;
  return `<div class="match-row${m.conflict ? " match-row-conflict" : ""}">
    <div class="side-in">${sideIn}</div>
    <div class="side-out">${sideOut}</div>
    <div class="${discClass}">${discText}${conflictBadgeHtml(m)}${matchMetaHtml(m)}</div>
    <div><button class="danger" data-delete="${m.id}">Undo</button></div>
  </div>`;
}

function renderMatchGroup(group, listId, countId, emptyMsg) {
  document.getElementById(countId).textContent = group.length;
  const list = document.getElementById(listId);

  if (group.length === 0) {
    list.innerHTML = `<div class="empty-msg">${emptyMsg}</div>`;
    return;
  }

  const sorted = [...group].sort((a, b) => b.id - a.id);
  list.innerHTML = sorted.map(matchRowHtml).join("");

  list.querySelectorAll("[data-delete]").forEach((el) => {
    el.addEventListener("click", () => deleteMatch(Number(el.dataset.delete)));
  });
  wireDetailButtons(list);
}

function renderMatches() {
  const unbalanced = matches.filter((m) => m.discrepancy !== 0);
  const balanced = matches.filter((m) => m.discrepancy === 0);

  renderMatchGroup(unbalanced, "matches-unbalanced-list", "matches-unbalanced-count", "No discrepancies 🎉");
  renderMatchGroup(balanced, "matches-balanced-list", "matches-balanced-count", "No balanced matches yet.");
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
document.getElementById("btn-cancel").addEventListener("click", cancelMatch);
document.getElementById("search-incoming").addEventListener("input", renderLists);
document.getElementById("search-incoming-amount").addEventListener("input", renderLists);
document.getElementById("search-incoming-after").addEventListener("input", renderLists);
document.getElementById("search-incoming-before").addEventListener("input", renderLists);
document.getElementById("search-outgoing").addEventListener("input", renderLists);
document.getElementById("search-outgoing-amount").addEventListener("input", renderLists);
document.getElementById("search-outgoing-after").addEventListener("input", renderLists);
document.getElementById("search-outgoing-before").addEventListener("input", renderLists);
document.getElementById("sort-incoming").addEventListener("change", renderLists);
document.getElementById("sort-outgoing").addEventListener("change", renderLists);

loadAll();
