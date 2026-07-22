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

function wireDetailButtons(root) {
  root.querySelectorAll(".info-icon").forEach((el) => {
    el.addEventListener("click", (e) => {
      e.stopPropagation();
      const t = JSON.parse(el.dataset.detail);
      showDetailsModal(t);
    });
  });
  root.querySelectorAll(".hcb-link").forEach((el) => {
    el.addEventListener("click", (e) => e.stopPropagation());
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
