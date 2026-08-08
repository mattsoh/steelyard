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

function showDetailsModal(t) {
  const overlay = document.getElementById("detail-modal-overlay");
  const title = document.getElementById("detail-modal-title");
  const body = document.getElementById("detail-modal-body");

  title.textContent = `${t.date} — ${fmtDetail(t.amount)}`;

  const statusParts = [];
  if (t.pending) statusParts.push("Pending");
  if (t.declined) statusParts.push("Declined" + (t.decline_reason ? ` (${t.decline_reason})` : ""));
  if (t.reversed) statusParts.push("Reversed");
  if (t.missing_receipt) statusParts.push("Missing receipt");
  if (t.lost_receipt) statusParts.push("Lost receipt");

  const fields = [
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

  const isManual = t.id < 0;
  const deleteHtml = isManual
    ? `<div class="modal-field"><button type="button" class="danger" id="detail-delete-tx">Delete transaction</button></div>`
    : "";

  body.innerHTML = fields.map(([label, value]) => `
    <div class="modal-field">
      <div class="field-label">${label}</div>
      <div class="field-value">${escapeHtml(value) || "—"}</div>
    </div>
  `).join("") + (isManual ? "" : commentsFieldHtml("Loading…")) + deleteHtml;

  overlay.classList.remove("hidden");

  if (isManual) {
    document.getElementById("detail-delete-tx").addEventListener("click", () => deleteManualTransaction(t.id));
  } else {
    loadComments(t.id);
  }
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
