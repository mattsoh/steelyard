// The match detail popup: one match's two sides as full transactions, who
// made it, who last touched it, and the change history behind it. Shared by
// both legacy pages (see shared/_match_modal), and reachable by link --
// /organizations/<org>/matches/<id> is this popup opened over the matcher.
//
// Deliberately self-contained: it fetches the match it shows rather than
// reading the host page's state, so a link to a match opens in a second
// without waiting on the page's full transaction drain behind it.

const MATCH_API_BASE = `/organizations/${window.HCB_ORGANIZATION_ID}`;
const MATCH_LINK_BASE = `/organizations/${window.HCB_ORGANIZATION_SLUG || window.HCB_ORGANIZATION_ID}`;

// Where closing the popup should land. A page reached by a match link has
// nowhere behind it, so it goes to the matcher; anywhere else goes back to the
// URL the page was opened with.
const MATCH_BASE_PAGE_URL = window.FOCUS_MATCH_ID
  ? `${MATCH_LINK_BASE}/matcher`
  : window.location.pathname + window.location.search;

// The match on screen, the transactions its response resolved for us (legs
// and everything its history mentions), and whether opening it added a
// history entry we can go back through.
let matchDetailId = null;
let matchDetailMatch = null;
let matchDetailTransactions = {};
let matchDetailPushedEntry = false;

// The note editor, which is open over the match rather than instead of it --
// the sides and the history stay on screen while someone writes about them.
let matchNoteEditing = false;
let matchNoteBusy = false;
let matchNoteError = null;
// What's in the box, held outside the DOM: every state change redraws the
// popup, and a textarea rebuilt from the *saved* note would type over what
// someone is in the middle of writing.
let matchNoteDraft = "";

// Hiding is one click with nothing to fill in, so all it needs is somewhere to
// say the request is in flight -- the button is disabled meanwhile so a slow
// save can't be sent twice.
let matchHideBusy = false;

const LOADING_MATCH_HTML = `<div class="empty-msg loading-msg"><span class="loading-spinner"></span>Loading match…</div>`;

const ACTION_LABELS = {
  created: "Created",
  edited: "Edited",
  undone: "Undone",
  // Nobody did this one -- HCB restated a transaction and the app re-derived
  // what the match is now off by (see Matches::Resync).
  resynced: "Discrepancy re-derived",
};

function matchDetailPath(id) {
  return `${MATCH_LINK_BASE}/matches/${id}`;
}

// The address bar is a courtesy -- it's what makes the open popup linkable --
// and the popup's contents are the point, so a browser that refuses to write
// it (pushState throws in a sandboxed or non-http context) gets the match
// anyway rather than a popup stuck on "loading". Reports whether it took, so
// closing knows if there's an entry to go back through.
function pushMatchUrl(id) {
  try {
    history.pushState({ matchId: String(id) }, "", matchDetailPath(id));
    return true;
  } catch (e) {
    return false;
  }
}

// Same shape as app.js/ledger.js's own copies -- kept local so this file
// works on either page without depending on which one loaded after it.
function matchTxnCode(id) {
  const s = String(id);
  return s.startsWith("txn_") ? s.slice(4) : null;
}

function matchTxnCodeHtml(t) {
  const code = matchTxnCode(t.id);
  if (!code) return "";
  return ` <button type="button" class="hcb-code hcb-code-inline" data-copy="${escapeHtml(code)}" title="Copy HCB code">${escapeHtml(code)}</button>`;
}

function matchTxnLinkHtml(t) {
  const code = matchTxnCode(t.id);
  if (!code) return "";
  return ` <a class="hcb-link" href="https://hcb.hackclub.com/hcb/${escapeHtml(code)}" target="_blank" rel="noopener noreferrer" title="View on HCB">↗</a>`;
}

function matchDate(iso) {
  if (!iso) return "";
  return new Date(iso).toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });
}

function matchDateTime(iso) {
  if (!iso) return "";
  return new Date(iso).toLocaleString();
}

// A leg, or an honest placeholder for one the organization's loaded history
// can't resolve -- most likely a transaction from before the current cutoff,
// or one HCB no longer returns. Dropping it silently would leave the sides not
// adding up to the discrepancy printed beside them, with nothing to say why.
function matchLegHtml(id) {
  const t = matchDetailTransactions[id];
  if (!t) {
    return `<div class="match-leg match-leg-missing">
      <span class="match-leg-memo">${escapeHtml(String(id))} <span class="match-leg-note">not in the loaded history</span></span>
    </div>`;
  }
  return `<div class="match-leg">
    <span class="match-leg-date">${escapeHtml(t.date)}</span>
    <span class="match-leg-memo">${escapeHtml(t.memo)}${matchTxnCodeHtml(t)}</span>
    <span class="match-leg-amount">${fmtDetail(t.amount)}</span>
    <span class="match-leg-icons"><button type="button" class="match-info-icon" data-txn="${escapeHtml(String(t.id))}" title="View full details">ⓘ</button>${matchTxnLinkHtml(t)}</span>
  </div>`;
}

function matchSideHtml(title, ids, emptyMsg) {
  const sum = ids.reduce((s, id) => s + (matchDetailTransactions[id] ? matchDetailTransactions[id].amount : 0), 0);
  const body = ids.length ? ids.map(matchLegHtml).join("") : `<div class="side-empty">${emptyMsg}</div>`;
  return `<div class="match-detail-side">
    <div class="match-detail-side-head">
      <span>${title} (${ids.length})</span>
      <strong>${fmtDetail(sum)}</strong>
    </div>
    ${body}
  </div>`;
}

// One line of "what this change actually did". Legs are named by the
// transaction where we have it, so a history entry reads as "removed the
// $250 grant" rather than as an id nobody recognises.
function matchChangeHtml(c) {
  if (c.kind === "leg") {
    const t = matchDetailTransactions[c.transaction_id];
    const label = t
      ? `${escapeHtml(t.date)} — ${escapeHtml(t.memo)} — ${fmtDetail(t.amount)}`
      : escapeHtml(String(c.transaction_id));
    const verb = c.action === "added" ? "Added" : "Removed";
    const sign = c.action === "added" ? "+" : "−";
    return `<li class="match-change match-change-${escapeHtml(c.action)}"><span class="match-change-sign">${sign}</span>${verb} ${escapeHtml(c.direction)}: ${label}</li>`;
  }
  if (c.kind === "adjustment") {
    return `<li class="match-change">Adjustment: ${escapeHtml(c.memo)} — ${fmtDetail(c.amount)}</li>`;
  }
  // A yes/no the server already rendered as words (see Matches::History) --
  // quoting it the way a note's text is quoted would read as someone having
  // typed "yes" into a field.
  if (c.kind === "flag") {
    return `<li class="match-change">${escapeHtml(c.label)}: ${escapeHtml(String(c.from))} → <strong>${escapeHtml(String(c.to))}</strong></li>`;
  }
  if (c.kind === "amount") {
    return `<li class="match-change">${escapeHtml(c.label)}: ${fmtDetail(c.from || 0)} → <strong>${fmtDetail(c.to || 0)}</strong></li>`;
  }
  const from = c.from ? `“${escapeHtml(c.from)}”` : "empty";
  const to = c.to ? `“${escapeHtml(c.to)}”` : "empty";
  return `<li class="match-change">${escapeHtml(c.label)}: ${from} → <strong>${to}</strong></li>`;
}

function matchEventHtml(e) {
  const label = ACTION_LABELS[e.action] || "Changed";
  // A system entry names the process that acted, not a person, so "by resync"
  // would read as somebody's username.
  const actor = e.system
    ? `<span class="match-event-system" title="An automatic change, not one a person made">${escapeHtml(e.actor_name)}</span>`
    : `by <strong>${escapeHtml(e.actor_name)}</strong>`;
  const changes = e.changes.length ? `<ul class="match-event-changes">${e.changes.map(matchChangeHtml).join("")}</ul>` : "";
  return `<li class="match-event match-event-${escapeHtml(e.action)}">
    <div class="match-event-head">
      <span class="match-event-label">${label}</span> ${actor}
      <span class="match-event-time">${escapeHtml(matchDateTime(e.at))}</span>
    </div>
    ${changes}
  </li>`;
}

// Created/last-edited as one compact line rather than a field each: on a match
// nobody has touched since it was made there is only one thing to say, and on
// one that has been edited the person reading wants both side by side.
function matchProvenanceHtml(m) {
  const created = `Matched by <strong>${escapeHtml(m.created_by_name)}</strong> on ${escapeHtml(matchDate(m.created_at))}`;
  const edited = m.edited
    ? ` <span class="match-sep">·</span> last edited by <strong>${escapeHtml(m.last_edited_by_name)}</strong> on <span title="${escapeHtml(matchDateTime(m.last_edited_at))}">${escapeHtml(matchDate(m.last_edited_at))}</span>`
    : "";
  const undone = m.undone
    ? `<div class="match-undone-banner">Undone${m.undone_by_name ? ` by ${escapeHtml(m.undone_by_name)}` : ""}${m.undone_at ? ` on ${escapeHtml(matchDate(m.undone_at))}` : ""} — these transactions are unmatched again.</div>`
    : "";
  return `${undone}<div class="match-provenance">${created}${edited}</div>`;
}

// The note, and the means to write one. Always present, even when there's no
// note yet -- "why is this match the shape it is" is the question the popup
// exists to answer, and an empty section that invites an answer is worth more
// than no section at all.
//
// An undone match is read-only: it isn't pairing anything any more, and the
// server refuses to change it, so offering the button would only produce an
// error after someone had written something.
function matchNoteHtml(m) {
  if (m.undone) {
    if (!m.note) return "";
    return `<div class="modal-field"><div class="field-label">Note</div><div class="field-value">${escapeHtml(m.note)}</div></div>`;
  }

  const errorHtml = matchNoteError ? `<div class="match-note-error">${escapeHtml(matchNoteError)}</div>` : "";

  if (matchNoteEditing) {
    return `<div class="modal-field match-note">
      <div class="field-label">Note</div>
      <textarea id="match-note-input" class="match-note-input" rows="3" placeholder="What is this match, and how do you know?" ${matchNoteBusy ? "disabled" : ""}>${escapeHtml(matchNoteDraft)}</textarea>
      ${errorHtml}
      <div class="match-note-actions">
        <button type="button" id="match-note-save" ${matchNoteBusy ? "disabled" : ""}>${matchNoteBusy ? "Saving…" : "Save note"}</button>
        <button type="button" class="secondary" id="match-note-cancel" ${matchNoteBusy ? "disabled" : ""}>Cancel</button>
        <span class="match-note-hint">⌘/Ctrl + Enter saves</span>
      </div>
    </div>`;
  }

  const value = m.note
    ? `<div class="field-value">${escapeHtml(m.note)}</div>`
    : `<div class="field-value match-note-empty">No note yet.</div>`;
  return `<div class="modal-field match-note">
    <div class="match-note-head">
      <div class="field-label">Note</div>
      <button type="button" class="secondary match-note-edit" id="match-note-edit">${m.note ? "Edit note" : "Add note"}</button>
    </div>
    ${value}
    ${errorHtml}
  </div>`;
}

function matchDetailBodyHtml(m) {
  const balanced = m.discrepancy === 0;
  const statusHtml = `<span class="match-status ${balanced ? "discrepancy-ok" : "discrepancy-bad"}">${balanced ? "Balanced" : `Off by ${fmtDetail(m.discrepancy)}`}</span>`;
  const conflictHtml = m.conflict
    ? `<span class="conflict-badge" title="This match has legs on both sides of the current cutoff — one side is hidden, the other visible.">⚠ Spans cutoff</span>`
    : "";
  // Hidden is about the matcher's lists, not about the match, so it's stated
  // here rather than changing anything else the popup says. An undone match
  // isn't in those lists at all, so there's nothing to hide it from.
  const hiddenHtml = m.hidden
    ? `<span class="hidden-badge" title="Out of the matcher's match lists until someone ticks “Show hidden”. Nothing else about the match changed.">🙈 Hidden${m.hidden_by_name ? ` by ${escapeHtml(m.hidden_by_name)}` : ""}</span>`
    : "";
  const hideButtonHtml = m.undone
    ? ""
    : `<button type="button" class="secondary match-hide-toggle" id="match-hide-toggle" ${matchHideBusy ? "disabled" : ""} title="${m.hidden ? "Put this match back in the matcher's lists" : "Take this match out of the matcher's lists — for a discrepancy that isn't money anyone has to find"}">${matchHideBusy ? "Saving…" : m.hidden ? "Unhide" : "Hide"}</button>`;
  const noteHtml = matchNoteHtml(m);
  const adjustmentsHtml = (m.adjustments || []).length
    ? `<div class="modal-field"><div class="field-label">Adjustments</div><div class="field-value">${m.adjustments
        .map((a) => `${escapeHtml(a.memo)} — ${fmtDetail(a.amount)}`)
        .join("<br>")}</div></div>`
    : "";

  const history = m.history || [];
  // Open by default when there is something beyond the creation to read --
  // an edited match is exactly the one someone opened this popup to ask about.
  const historyOpen = history.length > 1 ? " open" : "";
  // Empty only for a match older than the change log itself (the legacy
  // import brought the matches over, not the history behind them). Saying so
  // beats an empty list that reads as "nobody has ever touched this".
  const historyHtml = history.length
    ? `<ol class="match-events">${history.map(matchEventHtml).join("")}</ol>`
    : `<div class="empty-msg">No recorded changes — this match predates the change log.</div>`;

  return `
    <div class="match-detail-top">
      <div class="match-detail-status">${statusHtml}${conflictHtml}${hiddenHtml}${hideButtonHtml}</div>
      ${matchProvenanceHtml(m)}
    </div>
    ${noteHtml}
    ${adjustmentsHtml}
    <div class="match-detail-sides">
      ${matchSideHtml("Incoming", m.incoming_ids, "No incoming")}
      ${matchSideHtml("Outgoing", m.outgoing_ids, "No outgoing")}
    </div>
    <details class="match-history"${historyOpen}>
      <summary>Change history (${history.length})</summary>
      ${historyHtml}
    </details>
  `;
}

// Opens the editor, saves what's in it, or puts it away. Each re-renders the
// whole popup from the match in hand -- there's one source of truth for what's
// on screen, and no half-updated DOM to keep in step with it.
function resetNoteEditor() {
  matchNoteEditing = false;
  matchNoteBusy = false;
  matchNoteError = null;
  matchNoteDraft = "";
}

function startNoteEdit() {
  matchNoteEditing = true;
  matchNoteError = null;
  matchNoteDraft = matchDetailMatch.note || "";
  renderMatchDetail(matchDetailMatch);
  const input = document.getElementById("match-note-input");
  if (input) {
    input.focus();
    // Caret at the end, so editing an existing note carries on from where it
    // left off rather than in front of what's already there.
    input.setSelectionRange(input.value.length, input.value.length);
  }
}

function cancelNoteEdit() {
  matchNoteEditing = false;
  matchNoteError = null;
  matchNoteDraft = "";
  renderMatchDetail(matchDetailMatch);
}

async function saveMatchNote() {
  if (matchNoteBusy) return;
  const id = matchDetailId;
  const note = matchNoteDraft.trim();
  matchNoteBusy = true;
  matchNoteError = null;
  renderMatchDetail(matchDetailMatch);

  let saved;
  try {
    // Note only: the legs aren't sent, and the server leaves them exactly as
    // they are (see Api::MatchesController#update).
    const res = await fetch(`${MATCH_API_BASE}/api/matches/${id}`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ note: note }),
    });
    if (await handledReauthRequired(res)) return;
    if (!res.ok) {
      const err = await res.json().catch(() => ({}));
      throw new Error(err.error || "Could not save this note.");
    }
    saved = await res.json();
  } catch (e) {
    matchNoteBusy = false;
    // Nothing to draw the failure onto if they've moved on to another match;
    // their text went with the popup either way.
    if (matchDetailId !== id) return;
    matchNoteError = e.message;
    renderMatchDetail(matchDetailMatch);
    return;
  }

  matchNoteBusy = false;
  matchNoteEditing = false;
  matchNoteDraft = "";
  if (matchDetailId !== id) return;

  // The response carries the match's own fields and its history, but not the
  // resolved transactions the popup is already holding -- the legs didn't
  // move, so what's on screen for them is still right.
  matchDetailMatch = { ...matchDetailMatch, ...saved };
  renderMatchDetail(matchDetailMatch);

  // The page behind the popup holds its own copy of this match (the matcher
  // lists it, and exports it), so tell it what changed rather than leaving it
  // showing the old note until the next reload.
  document.dispatchEvent(new CustomEvent("match:updated", { detail: matchDetailMatch }));
}

// Same PATCH the matcher's own Hide button sends, so a match hidden from here
// is hidden for everyone, and the page behind the popup is told rather than
// left listing it until the next reload.
async function toggleMatchHidden() {
  if (matchHideBusy || !matchDetailMatch) return;
  const id = matchDetailId;
  const hidden = !matchDetailMatch.hidden;
  matchHideBusy = true;
  renderMatchDetail(matchDetailMatch);

  let saved;
  try {
    const res = await fetch(`${MATCH_API_BASE}/api/matches/${id}`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ hidden: hidden }),
    });
    if (await handledReauthRequired(res)) return;
    if (!res.ok) {
      const err = await res.json().catch(() => ({}));
      throw new Error(err.error || `Could not ${hidden ? "hide" : "unhide"} this match.`);
    }
    saved = await res.json();
  } catch (e) {
    matchHideBusy = false;
    if (matchDetailId !== id) return;
    alert(e.message);
    renderMatchDetail(matchDetailMatch);
    return;
  }

  matchHideBusy = false;
  if (matchDetailId !== id) return;

  matchDetailMatch = { ...matchDetailMatch, ...saved };
  renderMatchDetail(matchDetailMatch);
  document.dispatchEvent(new CustomEvent("match:updated", { detail: matchDetailMatch }));
}

function wireNoteEditor(body) {
  const edit = body.querySelector("#match-note-edit");
  if (edit) edit.addEventListener("click", startNoteEdit);

  const save = body.querySelector("#match-note-save");
  if (save) save.addEventListener("click", saveMatchNote);

  const cancel = body.querySelector("#match-note-cancel");
  if (cancel) cancel.addEventListener("click", cancelNoteEdit);

  const input = body.querySelector("#match-note-input");
  if (input) {
    input.addEventListener("input", () => { matchNoteDraft = input.value; });
    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) saveMatchNote();
    });
  }
}

function renderMatchDetail(m) {
  matchDetailMatch = m;
  document.getElementById("match-modal-title").textContent = `Match #${m.id}`;
  const body = document.getElementById("match-modal-body");
  body.innerHTML = matchDetailBodyHtml(m);
  wireNoteEditor(body);

  const hideToggle = body.querySelector("#match-hide-toggle");
  if (hideToggle) hideToggle.addEventListener("click", toggleMatchHidden);

  // The transaction modal opens over this one, from a leg or from a leg named
  // in the history -- both are already resolved in the response, so it doesn't
  // matter whether the host page happens to have loaded them.
  body.querySelectorAll(".match-info-icon").forEach((el) => {
    el.addEventListener("click", (e) => {
      e.stopPropagation();
      const t = matchDetailTransactions[el.dataset.txn];
      if (t) showDetailsModal(t);
    });
  });
  wireHcbLinks(body);
  wireCopyCodes(body);
}

// What the server actually said, carried on the Error so the popup can tell a
// match that isn't there apart from one the server failed to build. Reporting
// both as "it may have been undone" sent people looking for a match that was
// sitting there perfectly intact.
//
// A 500 response carries an error_id (see
// ApplicationController#report_unexpected_error) which is the only handle on
// the failure in AppSignal afterwards -- swallowing it here is what made a
// server-side error indistinguishable from a deleted match.
async function matchLoadError(res) {
  const body = await res.json().catch(() => ({}));
  const err = new Error(body.error || `Request failed (${res.status}).`);
  err.status = res.status;
  err.errorId = body.error_id;
  return err;
}

function matchLoadErrorHtml(e) {
  if (e.status === 404) {
    return `<div class="empty-msg">Could not load this match. It may have been undone, or you may not have access to it.</div>`;
  }

  // No status at all means the response never arrived -- the network dropped,
  // or something in front of the app timed the request out. Worth saying so
  // plainly: it's the one case where trying again is likely to work.
  const detail = e.status
    ? `Could not load this match: the server couldn't build it (error ${e.status}).`
    : `Could not load this match: the request didn't complete. It may have timed out.`;
  const ref = e.errorId ? ` Reference: ${escapeHtml(String(e.errorId))}.` : "";
  return `<div class="empty-msg">${detail}${ref} <a href="#" class="nav-link match-load-retry">Retry</a></div>`;
}

function showMatchLoadError(id, e) {
  const body = document.getElementById("match-modal-body");
  body.innerHTML = matchLoadErrorHtml(e);

  const retry = body.querySelector(".match-load-retry");
  if (!retry) return;
  // Redrawing the same match in the popup that's already open, so this isn't a
  // navigation and mustn't push another history entry on top of the one
  // opening it already left.
  retry.addEventListener("click", (event) => {
    event.preventDefault();
    showMatchModal(id, { updateUrl: false });
  });
}

async function showMatchModal(id, { updateUrl = true } = {}) {
  const overlay = document.getElementById("match-modal-overlay");
  if (!overlay) return;

  matchDetailId = String(id);
  matchDetailMatch = null;
  matchDetailTransactions = {};
  resetNoteEditor();
  document.getElementById("match-modal-title").textContent = `Match #${id}`;
  document.getElementById("match-modal-body").innerHTML = LOADING_MATCH_HTML;
  document.getElementById("match-modal-link-note").textContent = "";
  overlay.classList.remove("hidden");

  if (updateUrl && pushMatchUrl(id)) matchDetailPushedEntry = true;

  let data;
  try {
    const res = await fetch(`${MATCH_API_BASE}/api/matches/${id}`);
    if (await handledReauthRequired(res)) return;
    if (!res.ok) throw await matchLoadError(res);
    data = await res.json();
  } catch (e) {
    // Still the match being looked at? They may have closed the popup, or
    // opened another match, while the request was in flight.
    if (matchDetailId !== String(id)) return;
    showMatchLoadError(id, e);
    return;
  }

  if (matchDetailId !== String(id)) return;
  matchDetailTransactions = data.transactions || {};
  renderMatchDetail(data);
}

function hideMatchModal({ updateUrl = true } = {}) {
  const overlay = document.getElementById("match-modal-overlay");
  if (!overlay || overlay.classList.contains("hidden")) return;

  matchDetailId = null;
  matchDetailMatch = null;
  matchDetailTransactions = {};
  resetNoteEditor();
  overlay.classList.add("hidden");

  if (!updateUrl) return;
  // Opening pushed an entry, so going back both restores the URL and leaves
  // the browser's own history honest. A page reached *by* a match link has no
  // such entry -- there, the URL is corrected in place.
  if (matchDetailPushedEntry) {
    matchDetailPushedEntry = false;
    history.back();
    return;
  }
  try {
    history.replaceState(null, "", MATCH_BASE_PAGE_URL);
  } catch (e) {
    // Same as pushMatchUrl: not being able to tidy the address bar is no
    // reason to leave the popup on screen.
  }
}

function matchModalIsOpen(id) {
  return matchDetailId !== null && (id === undefined || matchDetailId === String(id));
}

async function copyMatchLink() {
  if (!matchDetailId) return;
  const url = window.location.origin + matchDetailPath(matchDetailId);
  const note = document.getElementById("match-modal-link-note");
  const ok = await copyToClipboard(url);
  note.textContent = ok ? "Link copied" : url;
  note.classList.toggle("warning", !ok);
}

if (document.getElementById("match-modal-overlay")) {
  document.getElementById("match-modal-close").addEventListener("click", () => hideMatchModal());
  document.getElementById("match-modal-copy-link").addEventListener("click", copyMatchLink);
  document.getElementById("match-modal-overlay").addEventListener("click", (e) => {
    if (e.target.id === "match-modal-overlay") hideMatchModal();
  });

  // Capture phase, deliberately: the transaction modal can be open *over* this
  // one, and details.js's own Escape handler (bubble phase, on the same
  // document) closes it. Running first is what lets this see that it was open
  // and leave it to that handler, so one Escape closes one modal.
  document.addEventListener("keydown", (e) => {
    if (e.key !== "Escape") return;
    if (!document.getElementById("detail-modal-overlay").classList.contains("hidden")) return;
    // An open note editor is the innermost thing on screen, so it's what one
    // Escape puts away -- closing the whole popup out from under a half-written
    // note would throw the writing away.
    if (matchNoteEditing) {
      if (!matchNoteBusy) cancelNoteEdit();
      return;
    }
    hideMatchModal();
  }, true);

  window.addEventListener("popstate", (e) => {
    const id = e.state && e.state.matchId;
    matchDetailPushedEntry = false;
    if (id) showMatchModal(id, { updateUrl: false });
    else hideMatchModal({ updateUrl: false });
  });

  // Reached by a match link: the popup is the point of the page.
  if (window.FOCUS_MATCH_ID) showMatchModal(window.FOCUS_MATCH_ID, { updateUrl: false });
}
