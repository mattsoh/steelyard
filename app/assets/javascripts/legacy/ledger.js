const API_BASE = `/organizations/${window.HCB_ORGANIZATION_ID}`;

let ledger = [];
let provisional = [];
let matchedIds = new Set();
let discrepancyIds = new Set();

let zeroBalanceOptions = [];
let zeroBalanceSelectedId = null;
let pendingCutoffId = null;
let cutoffBusy = false;

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

function showLedgerMessage(html) {
  document.getElementById("ledger-body").innerHTML = `<tr><td colspan="6">${html}</td></tr>`;
}

// Transaction ids are HCB's public ids ("txn_<hashid>"); that hashid is also
// what HCB's own site shows/searches on, so it's exposed here as "HCB code".
function hcbCode(r) {
  const id = String(r.id);
  return id.startsWith("txn_") ? id.slice(4) : null;
}

function hcbCodeHtml(r) {
  const code = hcbCode(r);
  return code ? ` <span class="hcb-code hcb-code-inline" title="HCB code">${escapeHtml(code)}</span>` : "";
}

// Memo search matches either the memo text or the HCB code, so pasting in a
// code from HCB's own UI finds the row without having to know its memo.
// Checked both ways against the code: query-in-code for a partial code, and
// code-in-query so pasting the row's *full HCB URL* (which contains the code
// as a substring, not the other way around) still finds it.
function memoOrCodeMatches(r, query) {
  if (!query) return true;
  const code = hcbCode(r);
  return r.memo.toLowerCase().includes(query) || (!!code && (code.toLowerCase().includes(query) || query.includes(code.toLowerCase())));
}

async function load() {
  showLedgerMessage(`<div class="empty-msg loading-msg"><span class="loading-spinner"></span>Loading transactions…</div>`);
  provisional = [];
  let lastTotalCount = null;
  let data, matchData;
  try {
    const matchesPromise = fetch(`${API_BASE}/api/matches`).then((r) => {
      if (!r.ok) throw new Error("bad response");
      return r.json();
    });

    // Apply matches as soon as they arrive rather than waiting on the (often
    // much slower) full ledger drain below -- matches is a single fast
    // query, and matched/discrepancy status shouldn't sit blank for the
    // whole multi-page HCB drain just because it's bundled with it. Errors
    // here are handled below, once this same promise is awaited again.
    matchesPromise.then((matchDataEarly) => {
      applyMatches(matchDataEarly.matches);
      renderProvisional(lastTotalCount);
    }).catch(() => {});

    await loadPagesStreaming(`${API_BASE}/api/ledger/page`, (rows, totalCount) => {
      // Pages arrive newest-first, same order the table displays in -- no
      // reordering needed for this provisional view. Running balance and the
      // zero-point cutoff aren't knowable until the full history is in, so
      // they're left blank until the final, authoritative render below.
      provisional.push(...rows.map((r) => ({ ...r, running_balance: null, is_zero_point: false })));
      lastTotalCount = totalCount;
      renderProvisional(totalCount);
    });

    const [ledgerRes, matchDataResolved] = await Promise.all([
      fetch(`${API_BASE}/api/ledger`),
      matchesPromise,
    ]);
    if (!ledgerRes.ok) throw new Error("bad response");
    data = await ledgerRes.json();
    matchData = matchDataResolved;
  } catch (e) {
    showLedgerMessage(`<div class="empty-msg">Could not load transactions. <a href="#" class="nav-link load-retry">Retry</a></div>`);
    document.querySelector(".load-retry").addEventListener("click", (ev) => {
      ev.preventDefault();
      load();
    });
    return;
  }

  applyMatches(matchData.matches);

  // Keep the zero-point row (as a reference) and everything after it,
  // then show newest first.
  const zeroIdx = data.ledger.findIndex((r) => r.is_zero_point);
  const kept = zeroIdx >= 0 ? data.ledger.slice(zeroIdx) : data.ledger;
  ledger = [...kept].reverse();

  document.getElementById("stat-final-balance").textContent = fmt(data.final_balance);
  document.getElementById("stat-count").textContent = ledger.length;

  zeroBalanceOptions = data.zero_balance_options || [];
  zeroBalanceSelectedId = data.zero_balance_selected_id || null;
  renderCutoffSelect();

  render();
}

// Shown while pages are still streaming in: raw rows with no search/filter
// and no running balance yet (status styling is applied once matches load,
// independently of the drain), just so the table isn't a blank spinner for
// however long the full drain takes.
function renderProvisional(totalCount) {
  document.getElementById("stat-count").textContent = totalCount
    ? `Loading… ${provisional.length} of ~${totalCount}`
    : `Loading… ${provisional.length}…`;
  const body = document.getElementById("ledger-body");
  body.innerHTML = provisional.map((r) => {
    const dirClass = r.amount > 0 ? "amt-in" : "amt-out";
    const status = rowStatus(r);
    const statusClass = status === "discrepancy" ? "ledger-discrepancy" : status === "matched" ? "ledger-matched" : "";
    return `<tr class="${statusClass}">
      <td>${r.date}</td>
      <td class="memo-cell" title="${escapeHtml(r.memo)}">${escapeHtml(r.memo)}${hcbCodeHtml(r)}</td>
      <td class="num ${dirClass}">${fmt(r.amount)}</td>
      <td class="num">…</td>
      <td>${escapeHtml(r.user_name)}</td>
      <td>${escapeHtml(r.category_label)}</td>
    </tr>`;
  }).join("");
}

function applyMatches(matches) {
  matchedIds = new Set();
  discrepancyIds = new Set();
  for (const m of matches) {
    const target = m.discrepancy === 0 ? matchedIds : discrepancyIds;
    for (const iid of m.incoming_ids) target.add(iid);
    for (const oid of m.outgoing_ids) target.add(oid);
  }
}

function rowStatus(r) {
  if (discrepancyIds.has(r.id)) return "discrepancy";
  if (matchedIds.has(r.id)) return "matched";
  return "unmatched";
}

function render() {
  const filter = document.getElementById("search-ledger").value.trim().toLowerCase();
  const amountFilter = document.getElementById("search-ledger-amount").value;
  const afterFilter = document.getElementById("search-ledger-after").value;
  const beforeFilter = document.getElementById("search-ledger-before").value;
  const showStatus = {
    matched: document.getElementById("filter-matched").checked,
    discrepancy: document.getElementById("filter-discrepancy").checked,
    unmatched: document.getElementById("filter-unmatched").checked,
  };
  const body = document.getElementById("ledger-body");

  const rows = ledger.filter(
    (r) =>
      showStatus[rowStatus(r)] &&
      memoOrCodeMatches(r, filter) &&
      amountMatches(r.amount, amountFilter) &&
      dateInRange(r.date, afterFilter, beforeFilter)
  );

  body.innerHTML = rows.map((r) => {
    const dirClass = r.amount > 0 ? "amt-in" : "amt-out";
    const status = rowStatus(r);
    const statusClass = status === "discrepancy" ? "ledger-discrepancy" : status === "matched" ? "ledger-matched" : "";
    const rowClass = [statusClass, r.is_zero_point ? "zero-point" : ""].filter(Boolean).join(" ");
    return `<tr class="${rowClass}" ${r.is_zero_point ? 'id="zero-point-row"' : ""}>
      <td>${r.date}</td>
      <td class="memo-cell" title="${escapeHtml(r.memo)}">${escapeHtml(r.memo)}${hcbCodeHtml(r)}${r.is_zero_point ? ' <span class="zero-badge">balance hit $0 here</span>' : ""}</td>
      <td class="num ${dirClass}">${fmt(r.amount)}</td>
      <td class="num">${fmt(r.running_balance)}</td>
      <td>${escapeHtml(r.user_name)}</td>
      <td>${escapeHtml(r.category_label)}</td>
    </tr>`;
  }).join("");

  body.querySelectorAll("tr").forEach((tr, idx) => {
    tr.addEventListener("click", () => showDetailsModal(rows[idx]));
  });
}

document.getElementById("search-ledger").addEventListener("input", render);
document.getElementById("search-ledger-amount").addEventListener("input", render);
document.getElementById("search-ledger-after").addEventListener("input", render);
document.getElementById("search-ledger-before").addEventListener("input", render);
document.getElementById("filter-matched").addEventListener("change", render);
document.getElementById("filter-discrepancy").addEventListener("change", render);
document.getElementById("filter-unmatched").addEventListener("change", render);

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
      await load();
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

load();
