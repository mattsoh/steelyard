const API_BASE = `/organizations/${window.HCB_ORGANIZATION_ID}`;

let allTransactions = [];
let matches = [];
let byId = new Map();

let selectedIncomingIds = [];
let selectedOutgoingIds = [];

let currentIncomingOrder = [];
let currentOutgoingOrder = [];
let lastIncomingClickId = null;
let lastOutgoingClickId = null;

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

const LOADING_HTML = `<div class="empty-msg loading-msg"><span class="loading-spinner"></span>Loading transactions…</div>`;

function showListsMessage(html) {
  document.getElementById("list-incoming").innerHTML = html;
  document.getElementById("list-outgoing").innerHTML = html;
}

async function loadAll() {
  showListsMessage(LOADING_HTML);
  let txData, matchData;
  try {
    const [txRes, matchRes] = await Promise.all([
      fetch(`${API_BASE}/api/transactions`),
      fetch(`${API_BASE}/api/matches`),
    ]);
    if (!txRes.ok || !matchRes.ok) throw new Error("bad response");
    [txData, matchData] = await Promise.all([txRes.json(), matchRes.json()]);
  } catch (e) {
    showListsMessage(`<div class="empty-msg">Could not load transactions. <a href="#" class="nav-link load-retry">Retry</a></div>`);
    document.querySelectorAll(".load-retry").forEach((el) => {
      el.addEventListener("click", (ev) => {
        ev.preventDefault();
        loadAll();
      });
    });
    return;
  }
  allTransactions = txData.transactions;
  byId = new Map(allTransactions.map((t) => [t.id, t]));
  matches = matchData.matches;

  document.getElementById("stat-zero-date").textContent = txData.zero_balance_date || "n/a";

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

function matchesRowHtml(t, extraClass) {
  const cls = t.direction + (extraClass ? " " + extraClass : "");
  return `<div class="row ${cls}" data-id="${t.id}">
    <div class="date">${t.date}</div>
    <div class="memo" title="${escapeHtml(t.memo)}">${escapeHtml(t.memo)}</div>
    <div class="amount">${fmt(t.amount)}</div>
    <div class="row-info">${infoIconHtml(t)}</div>
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
  const outgoingFilter = document.getElementById("search-outgoing").value.toLowerCase();
  const outgoingAmountFilter = document.getElementById("search-outgoing-amount").value;

  const incomingFiltered = unmatched.filter(
    (t) =>
      t.direction === "in" &&
      t.memo.toLowerCase().includes(incomingFilter) &&
      amountMatches(t.amount, incomingAmountFilter)
  );
  const incoming = sortTransactions(incomingFiltered, document.getElementById("sort-incoming").value);

  const outgoingFiltered = unmatched.filter(
    (t) =>
      t.direction === "out" &&
      t.memo.toLowerCase().includes(outgoingFilter) &&
      amountMatches(t.amount, outgoingAmountFilter)
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
        <span>${t.date} — ${escapeHtml(t.memo)}${infoIconHtml(t)} — <strong>${fmt(t.amount)}</strong></span>
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
        <span>${t.date} — ${escapeHtml(t.memo)}${infoIconHtml(t)} — ${fmt(t.amount)}</span>
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
  confirmBtn.disabled = selectedIncomingIds.length === 0 && selectedOutgoingIds.length === 0;
  confirmBtn.textContent =
    diff === 0 && selectedIncomingIds.length && selectedOutgoingIds.length ? "Confirm match" : "Confirm as discrepancy";
}

function round2(n) {
  return Math.round(n * 100) / 100;
}

function resetSearchFields() {
  ["search-incoming", "search-incoming-amount", "search-outgoing", "search-outgoing-amount"].forEach((id) => {
    const input = document.getElementById(id);
    input.value = "";
    input.dispatchEvent(new Event("input"));
  });
}

async function confirmMatch() {
  if (selectedIncomingIds.length === 0 && selectedOutgoingIds.length === 0) return;
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
  selectedIncomingIds = [];
  selectedOutgoingIds = [];
  lastIncomingClickId = null;
  lastOutgoingClickId = null;
  resetSearchFields();
  await loadAll();
}

function cancelMatch() {
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
  await loadAll();
}

function matchMetaHtml(m) {
  if (!m.created_by_name) return "";
  const when = m.created_at ? new Date(m.created_at).toLocaleDateString() : "";
  return `<div class="match-meta">Matched by ${escapeHtml(m.created_by_name)}${when ? " on " + when : ""}</div>`;
}

function matchRowHtml(m) {
  const incoming = m.incoming_ids.map((id) => byId.get(id)).filter(Boolean);
  const outgoing = m.outgoing_ids.map((id) => byId.get(id)).filter(Boolean);
  const discClass = m.discrepancy === 0 ? "discrepancy-ok" : "discrepancy-bad";
  const discText = m.discrepancy === 0 ? "balanced" : `off by ${fmt(Math.abs(m.discrepancy))}`;
  const sideIn = incoming.length
    ? incoming.map((t) => `<div>${t.date} — ${escapeHtml(t.memo)}${infoIconHtml(t)} — <strong>${fmt(t.amount)}</strong></div>`).join("")
    : `<span class="side-empty">No incoming</span>`;
  const sideOut = outgoing.length
    ? outgoing.map((t) => `<div>${t.date} — ${escapeHtml(t.memo)}${infoIconHtml(t)} — ${fmt(t.amount)}</div>`).join("")
    : `<span class="side-empty">No outgoing</span>`;
  return `<div class="match-row">
    <div class="side-in">${sideIn}</div>
    <div class="side-out">${sideOut}</div>
    <div class="${discClass}">${discText}${matchMetaHtml(m)}</div>
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

document.getElementById("btn-confirm").addEventListener("click", confirmMatch);
document.getElementById("btn-cancel").addEventListener("click", cancelMatch);
document.getElementById("search-incoming").addEventListener("input", renderLists);
document.getElementById("search-incoming-amount").addEventListener("input", renderLists);
document.getElementById("search-outgoing").addEventListener("input", renderLists);
document.getElementById("search-outgoing-amount").addEventListener("input", renderLists);
document.getElementById("sort-incoming").addEventListener("change", renderLists);
document.getElementById("sort-outgoing").addEventListener("change", renderLists);

loadAll();
