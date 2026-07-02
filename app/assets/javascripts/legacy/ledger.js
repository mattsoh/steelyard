const API_BASE = `/organizations/${window.HCB_ORGANIZATION_ID}`;

let ledger = [];
let matchedIds = new Set();
let discrepancyIds = new Set();

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

function showLedgerMessage(html) {
  document.getElementById("ledger-body").innerHTML = `<tr><td colspan="6">${html}</td></tr>`;
}

async function load() {
  showLedgerMessage(`<div class="empty-msg loading-msg"><span class="loading-spinner"></span>Loading transactions…</div>`);
  let data, matchData;
  try {
    const [ledgerRes, matchesRes] = await Promise.all([
      fetch(`${API_BASE}/api/ledger`),
      fetch(`${API_BASE}/api/matches`),
    ]);
    if (!ledgerRes.ok || !matchesRes.ok) throw new Error("bad response");
    [data, matchData] = await Promise.all([ledgerRes.json(), matchesRes.json()]);
  } catch (e) {
    showLedgerMessage(`<div class="empty-msg">Could not load transactions. <a href="#" class="nav-link load-retry">Retry</a></div>`);
    document.querySelector(".load-retry").addEventListener("click", (ev) => {
      ev.preventDefault();
      load();
    });
    return;
  }

  matchedIds = new Set();
  discrepancyIds = new Set();
  for (const m of matchData.matches) {
    const target = m.discrepancy === 0 ? matchedIds : discrepancyIds;
    for (const iid of m.incoming_ids) target.add(iid);
    for (const oid of m.outgoing_ids) target.add(oid);
  }

  // Keep the zero-point row (as a reference) and everything after it,
  // then show newest first.
  const zeroIdx = data.ledger.findIndex((r) => r.is_zero_point);
  const kept = zeroIdx >= 0 ? data.ledger.slice(zeroIdx) : data.ledger;
  ledger = [...kept].reverse();

  document.getElementById("stat-zero-date").textContent = data.zero_balance_date || "n/a";
  document.getElementById("stat-final-balance").textContent = fmt(data.final_balance);
  document.getElementById("stat-count").textContent = ledger.length;

  render();
}

function rowStatus(r) {
  if (discrepancyIds.has(r.id)) return "discrepancy";
  if (matchedIds.has(r.id)) return "matched";
  return "unmatched";
}

function render() {
  const filter = document.getElementById("search-ledger").value.toLowerCase();
  const amountFilter = document.getElementById("search-ledger-amount").value;
  const showStatus = {
    matched: document.getElementById("filter-matched").checked,
    discrepancy: document.getElementById("filter-discrepancy").checked,
    unmatched: document.getElementById("filter-unmatched").checked,
  };
  const body = document.getElementById("ledger-body");

  const rows = ledger.filter(
    (r) =>
      showStatus[rowStatus(r)] &&
      r.memo.toLowerCase().includes(filter) &&
      amountMatches(r.amount, amountFilter)
  );

  body.innerHTML = rows.map((r) => {
    const dirClass = r.amount > 0 ? "amt-in" : "amt-out";
    const status = rowStatus(r);
    const statusClass = status === "discrepancy" ? "ledger-discrepancy" : status === "matched" ? "ledger-matched" : "";
    const rowClass = [statusClass, r.is_zero_point ? "zero-point" : ""].filter(Boolean).join(" ");
    return `<tr class="${rowClass}" ${r.is_zero_point ? 'id="zero-point-row"' : ""}>
      <td>${r.date}</td>
      <td class="memo-cell" title="${escapeHtml(r.memo)}">${escapeHtml(r.memo)}${r.is_zero_point ? ' <span class="zero-badge">balance hit $0 here</span>' : ""}</td>
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
document.getElementById("filter-matched").addEventListener("change", render);
document.getElementById("filter-discrepancy").addEventListener("change", render);
document.getElementById("filter-unmatched").addEventListener("change", render);

load();
