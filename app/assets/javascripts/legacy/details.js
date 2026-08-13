function escapeHtml(s) {
  return (s || "").replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  }[c]));
}

const fmtDetail = (n) => (n < 0 ? "-$" : "$") + Math.abs(n).toFixed(2);

// A 401 with this shape means the session's HCB token needs a full
// re-login (expired, or missing a scope this app added after the user
// last authorized) -- unlike a real page navigation, `fetch()` can't be
// redirected to the login page by the server, so without this callers
// just see a broken response and report a misleading "could not load".
// Loaded first in every legacy page's layout, so it's available globally.
async function handledReauthRequired(res) {
  if (res.status !== 401) return false;
  try {
    const data = await res.clone().json();
    if (data.error !== "reauth_required") return false;
  } catch (e) {
    return false;
  }
  window.location.href = "/";
  return true;
}

function commentsFieldHtml(html) {
  return `
    <div class="modal-field" id="detail-comments-field">
      <div class="field-label">Comments</div>
      <div class="field-value" id="detail-comments-value">${html}</div>
    </div>
  `;
}

function commentHtml(c) {
  const author = escapeHtml(c.user_name) || "Someone";
  const fileHtml = c.file_url ? ` <a href="${escapeHtml(c.file_url)}" target="_blank" rel="noopener">attachment</a>` : "";
  const dateHtml = c.created_at ? ` <span class="detail-comment-date">${escapeHtml(new Date(c.created_at).toLocaleString())}</span>` : "";
  const adminHtml = c.admin_only ? ` <span class="detail-comment-admin-only">(admin only)</span>` : "";
  return `<div class="detail-comment"><strong>${author}:</strong>${adminHtml} ${escapeHtml(c.content)}${fileHtml}${dateHtml}</div>`;
}

// Field label -> value, in display order. Shared by the initial render and the
// re-render after a refresh, and by the diff that reports what a refresh
// changed, so all three can't drift apart.
function detailFields(t) {
  const statusParts = [];
  if (t.pending) statusParts.push("Pending");
  if (t.declined) statusParts.push("Declined" + (t.decline_reason ? ` (${t.decline_reason})` : ""));
  if (t.reversed) statusParts.push("Reversed");
  if (t.missing_receipt) statusParts.push("Missing receipt");
  if (t.lost_receipt) statusParts.push("Lost receipt");

  return [
    ["Amount", fmtDetail(t.amount)],
    ["Date", t.date],
    ["Memo", t.memo],
    ["Tags", t.tags],
    ["User", t.user_name],
    ["Recipient", t.recipient_name],
    ["Category", t.category_label],
    ["Status", statusParts.join(", ")],
    // Only shown when the transaction has settled on a date other than the
    // one it was sent on -- most transactions clear same-day, so this only
    // adds noise for the ones (ACH, checks) where the two actually diverge.
    ...(t.settled_date && t.settled_date !== t.date ? [ [ "Settled", t.settled_date ] ] : []),
  ];
}

// The transaction the modal is currently showing, so the refresh button knows
// what it's refreshing (and what the values were before).
let detailTransaction = null;

function showDetailsModal(t) {
  const overlay = document.getElementById("detail-modal-overlay");

  detailTransaction = t;
  renderDetailsModal(t);
  overlay.classList.remove("hidden");

  if (isManualTransaction(t)) {
    document.getElementById("detail-delete-tx").addEventListener("click", () => deleteManualTransaction(t.id));
  } else {
    loadComments(t.id);
  }
}

// Manually-added transactions carry negative numeric ids rather than HCB's
// "txn_<hashid>" -- they were never on HCB, so there's nothing to re-check
// against it and no comments thread to load.
function isManualTransaction(t) {
  return t.id < 0;
}

// Re-rendered wholesale after a refresh, rather than patched field by field --
// any of them can have changed. The outcome of that refresh goes into the note
// slot afterwards (setRefreshNote), which is the one thing that survives a
// re-render being about the refresh rather than about the transaction.
function renderDetailsModal(t) {
  const title = document.getElementById("detail-modal-title");
  const body = document.getElementById("detail-modal-body");

  title.textContent = `${t.date} — ${fmtDetail(t.amount)}`;

  const isManual = isManualTransaction(t);
  const actionsHtml = isManual
    ? `<div class="modal-actions"><button type="button" class="danger" id="detail-delete-tx">Delete transaction</button></div>`
    : `<div class="modal-actions">
         <button type="button" class="secondary" id="detail-refresh-tx" title="Re-check this one transaction against HCB — picks up an amount, status or memo that changed since it was loaded">↻ Refresh from HCB</button>
         <span class="detail-refresh-note" id="detail-refresh-note"></span>
       </div>`;

  body.innerHTML = detailFields(t).map(([label, value]) => `
    <div class="modal-field">
      <div class="field-label">${label}</div>
      <div class="field-value">${escapeHtml(value) || "—"}</div>
    </div>
  `).join("") + (isManual ? "" : commentsFieldHtml("Loading…")) + actionsHtml;

  if (!isManual) {
    document.getElementById("detail-refresh-tx").addEventListener("click", refreshDetailTransaction);
  }
}

function setRefreshNote(html, isWarning) {
  const el = document.getElementById("detail-refresh-note");
  if (!el) return;
  el.innerHTML = html;
  el.classList.toggle("warning", !!isWarning);
}

// Re-fetches the open transaction from HCB (one request server-side) and
// reports what moved. Worth its own button rather than folding into the
// header's "check for new": that only looks at the newest page, so a change to
// an older transaction -- a pending charge settling for more, a reversal -- is
// invisible to it no matter how many times it's pressed.
async function refreshDetailTransaction() {
  const t = detailTransaction;
  if (!t) return;
  const btn = document.getElementById("detail-refresh-tx");
  btn.disabled = true;
  setRefreshNote("checking HCB…");

  let data;
  try {
    const res = await fetch(`${API_BASE}/api/transactions/${t.id}/refresh`, { method: "POST" });
    if (await handledReauthRequired(res)) return;
    if (!res.ok) throw await serverError(res);
    data = await res.json();
  } catch (e) {
    btn.disabled = false;
    // Only a message this code put there is worth showing; anything else (a
    // network failure, an HTML error page that didn't parse) reads as noise.
    setRefreshNote(escapeHtml(e.refreshMessage || "Could not refresh this transaction. Try again."), true);
    return;
  }

  const matchesChanged = data.matches_changed || [];

  // Hand the fresh values to whichever page is hosting the modal, so the row
  // behind it (and any total computed from it) stops showing the stale amount.
  // Done before the still-open check below: the answer is just as valid if the
  // modal was closed while the request was in flight, and throwing it away
  // would leave the page showing values we know are stale.
  if (typeof applyRefreshedTransaction === "function") applyRefreshedTransaction(data.transaction);

  // A leg changing amount can push a match out of balance (or back into it);
  // the server has already re-derived the stored discrepancy, so this just
  // pulls the corrected matches back into the page.
  if (matchesChanged.length && typeof reloadMatches === "function") reloadMatches();

  // Still the transaction the user is looking at? They may have closed the
  // modal, or opened another row, while the request was in flight.
  if (!detailTransaction || detailTransaction.id !== t.id) return;

  detailTransaction = data.transaction;
  const changes = detailChanges(data.previous, data.transaction);
  renderDetailsModal(data.transaction);
  setRefreshNote(refreshNoteHtml(changes, matchesChanged), changes.length > 0 || matchesChanged.length > 0);
  loadComments(t.id);
}

// The server's own explanation of a failed response, when it sent one (a
// transaction HCB no longer has, say). Errors carry it on a custom property so
// the catch can tell it apart from a browser-generated message like
// "Failed to fetch", which means nothing to the person reading it.
async function serverError(res) {
  const error = new Error(`request failed with ${res.status}`);
  try {
    const data = await res.json();
    if (data.error) error.refreshMessage = data.error;
  } catch (e) {
    // Not JSON (an error page) -- the generic message covers it.
  }
  return error;
}

function detailChanges(previous, current) {
  const before = new Map(detailFields(previous));
  return detailFields(current).filter(([label, value]) => before.get(label) !== value)
    .map(([label, value]) => ({ label, from: before.get(label), to: value }));
}

function refreshNoteHtml(changes, matchesChanged) {
  if (!changes.length && !matchesChanged.length) return "up to date — nothing changed";

  const changeText = changes
    .map((c) => `${escapeHtml(c.label)}: ${escapeHtml(c.from) || "—"} → <strong>${escapeHtml(c.to) || "—"}</strong>`)
    .join("; ");
  // Spelled out per match rather than counted: "a match is now off by $12" is
  // the part someone actually has to go and do something about.
  const matchText = matchesChanged
    .map((m) => (m.to === 0 ? "a match now balances" : `a match is now off by ${fmtDetail(m.to)}`))
    .join("; ");

  return [changeText, matchText].filter(Boolean).join(" — ");
}

async function loadComments(transactionId) {
  try {
    const res = await fetch(`${API_BASE}/api/transactions/${transactionId}/comments`);
    if (await handledReauthRequired(res)) return;
    if (!res.ok) throw new Error("bad response");
    const data = await res.json();
    const valueEl = document.getElementById("detail-comments-value");
    if (!valueEl) return; // modal was closed/reopened for another transaction before this resolved
    valueEl.innerHTML = data.comments.length ? data.comments.map(commentHtml).join("") : "—";
  } catch (e) {
    const valueEl = document.getElementById("detail-comments-value");
    if (valueEl) valueEl.textContent = "Could not load comments.";
  }
}

async function deleteManualTransaction(id) {
  if (!confirm("Delete this manually-added transaction? This cannot be undone.")) return;
  const res = await fetch(`/api/transactions/${id}`, { method: "DELETE" });
  if (!res.ok) {
    const err = await res.json();
    alert("Could not delete transaction: " + err.error);
    return;
  }
  hideDetailsModal();
  if (typeof loadAll === "function") loadAll();
  else if (typeof load === "function") load();
}

function hideDetailsModal() {
  detailTransaction = null;
  document.getElementById("detail-modal-overlay").classList.add("hidden");
}

// navigator.clipboard is only defined in a secure context. Production is https
// and dev is localhost, so that covers both -- but fall back to the deprecated
// execCommand path anyway, so reaching a dev server over a plain-http LAN
// address copies rather than silently doing nothing.
async function copyToClipboard(text) {
  if (navigator.clipboard && window.isSecureContext) {
    try {
      await navigator.clipboard.writeText(text);
      return true;
    } catch (e) {
      // Permission denied or the document wasn't focused; try the fallback.
    }
  }

  const ta = document.createElement("textarea");
  ta.value = text;
  ta.setAttribute("readonly", "");
  // Off-screen rather than display:none -- an unrendered textarea can't be
  // selected, and a visible one at the top of the page would scroll-jump.
  ta.style.position = "fixed";
  ta.style.top = "-9999px";
  document.body.appendChild(ta);
  try {
    ta.select();
    return document.execCommand("copy");
  } catch (e) {
    return false;
  } finally {
    ta.remove();
  }
}

function selectText(el) {
  const range = document.createRange();
  range.selectNodeContents(el);
  const sel = window.getSelection();
  sel.removeAllRanges();
  sel.addRange(range);
}

// Flash the outcome on the code itself. The class drives a ✓/✗ in ::after
// rather than replacing the text, so the code stays readable and the row
// doesn't reflow underneath the pointer.
function flashCopyResult(el, ok) {
  clearTimeout(el.copyFlashTimer);
  el.classList.remove("copied", "copy-failed");
  void el.offsetWidth; // restart the transition when the same code is clicked twice
  el.classList.add(ok ? "copied" : "copy-failed");
  el.copyFlashTimer = setTimeout(() => {
    el.classList.remove("copied", "copy-failed");
  }, 1400);
}

// Wires the controls every transaction row carries, on both the matcher and
// the ledger. All three stop propagation because the row itself is clickable
// -- it toggles selection on the matcher and opens the details modal on the
// ledger, neither of which should fire when the target was a control.
//
// `byId` is app.js's transaction lookup (the only page that renders .info-icon
// buttons) -- looking it up here instead of round-tripping the whole
// transaction through JSON on the button's dataset avoids re-serializing every
// visible transaction's full object on every render.
function wireRowControls(root) {
  root.querySelectorAll(".info-icon").forEach((el) => {
    el.addEventListener("click", (e) => {
      e.stopPropagation();
      const t = byId.get(el.dataset.id);
      if (t) showDetailsModal(t);
    });
  });
  root.querySelectorAll(".hcb-link").forEach((el) => {
    el.addEventListener("click", (e) => e.stopPropagation());
  });
  root.querySelectorAll(".hcb-code").forEach((el) => {
    el.addEventListener("click", async (e) => {
      e.stopPropagation();
      const code = el.dataset.copy;
      if (!code) return;
      const ok = await copyToClipboard(code);
      // Both clipboard paths refused (they shouldn't outside an exotic
      // browser/permissions setup). Leave the code selected so the ✗ comes
      // with something the user can actually act on.
      if (!ok) selectText(el);
      flashCopyResult(el, ok);
    });
  });
}

function wireSearchClears() {
  document.querySelectorAll(".search-clear").forEach((btn) => {
    const input = document.getElementById(btn.dataset.clearTarget);
    if (!input) return;
    const sync = () => btn.classList.toggle("visible", input.value.length > 0);
    input.addEventListener("input", sync);
    btn.addEventListener("click", () => {
      input.value = "";
      input.dispatchEvent(new Event("input"));
      input.focus();
    });
    sync();
  });
}

wireSearchClears();

document.getElementById("detail-modal-close").addEventListener("click", hideDetailsModal);
document.getElementById("detail-modal-overlay").addEventListener("click", (e) => {
  if (e.target.id === "detail-modal-overlay") hideDetailsModal();
});
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape") hideDetailsModal();
});
