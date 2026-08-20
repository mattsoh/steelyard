// A running account of what the page is doing with HCB, in a panel you can
// open when you want it and ignore when you don't.
//
// The matcher and the ledger both spend real time waiting on HCB -- a cold load
// is a round trip per hundred transactions, a full reload re-walks the whole
// history -- and until now all of that was one line of text ("loading…") and a
// spinner. When it took two minutes there was no way to tell a slow drain from
// a stuck one, or Steelyard being slow from HCB being slow. This says which.
//
// Loaded before the page scripts, so they can log from the top of a load.

// Enough to explain a load, not enough to become a memory leak on a page left
// open all day. Oldest lines drop off the top.
const ACTIVITY_MAX_ENTRIES = 200;

// Above this, a single HCB call is worth remarking on rather than just
// recording. Ordinary pages come back in a few hundred milliseconds; this is
// slow enough to be the thing someone is waiting on.
const ACTIVITY_SLOW_HCB_MS = 1500;

const activityEntries = [];
let activityPanelOpen = false;
// Entries added while the panel is shut, so the toggle can say there's
// something new without the panel having to be open to count it.
let activityUnseen = 0;
let activitySlowNoted = false;

const activityStartedAt = Date.now();

function activityElapsed() {
  const seconds = (Date.now() - activityStartedAt) / 1000;
  if (seconds < 60) return `${seconds.toFixed(1)}s`;
  const minutes = Math.floor(seconds / 60);
  return `${minutes}m${String(Math.floor(seconds % 60)).padStart(2, "0")}s`;
}

// kind drives only the colour of the line: "info" (default), "hcb" for
// something HCB did, "warn" for something worth noticing, "error" for something
// that failed, "done" for something finishing.
function logActivity(text, kind = "info") {
  activityEntries.push({ at: activityElapsed(), text, kind });
  while (activityEntries.length > ACTIVITY_MAX_ENTRIES) activityEntries.shift();

  if (!activityPanelOpen) activityUnseen += 1;
  renderActivity();
}

// The HCB half of a response (see StreamedTransactionPages), rendered as a
// clause to hang off whatever the caller is reporting -- and escalated to its
// own warning line when HCB is the reason a load is dragging.
function activityHcbClause(hcb) {
  if (!hcb || !hcb.requests) return "";

  const total = Math.round(hcb.ms);
  const clause = hcb.requests === 1
    ? ` — HCB ${total}ms`
    : ` — ${hcb.requests} HCB requests, ${total}ms`;

  if (hcb.slowest_ms >= ACTIVITY_SLOW_HCB_MS && !activitySlowNoted) {
    activitySlowNoted = true;
    // Deliberately once per page rather than per slow page: a genuinely slow
    // HCB makes *every* page slow, and a warning per page would bury the log
    // in the same sentence over and over.
    logActivity(
      `HCB is answering slowly (${(hcb.slowest_ms / 1000).toFixed(1)}s for one request) — this load will take longer than usual`,
      "warn",
    );
  }

  return clause;
}

// Answered from the cache with no HCB round trip at all, which is the good case
// and worth being able to see.
function activityCacheNote(hcb) {
  return !hcb || !hcb.requests ? " — from cache, no HCB request" : activityHcbClause(hcb);
}

function activityPanelEl() {
  return document.getElementById("activity-panel");
}

function renderActivity() {
  const panel = activityPanelEl();
  if (!panel) return;

  const toggle = document.getElementById("activity-toggle");
  if (toggle) {
    toggle.textContent = activityUnseen > 0 && !activityPanelOpen
      ? `☰ Activity (${activityUnseen})`
      : "☰ Activity";
  }

  panel.classList.toggle("hidden", !activityPanelOpen);
  if (!activityPanelOpen) return;

  const body = document.getElementById("activity-body");
  if (!body) return;

  body.innerHTML = activityEntries.length
    ? activityEntries
      .map((e) => `<li class="activity-line activity-${escapeHtml(e.kind)}">`
        + `<span class="activity-at">${escapeHtml(e.at)}</span>${escapeHtml(e.text)}</li>`)
      .join("")
    : `<li class="activity-line activity-info">Nothing yet.</li>`;

  // Pinned to the newest line, which is the one anyone opening this is looking
  // for.
  body.scrollTop = body.scrollHeight;
}

function setActivityPanelOpen(open) {
  activityPanelOpen = open;
  if (open) activityUnseen = 0;
  const toggle = document.getElementById("activity-toggle");
  if (toggle) toggle.setAttribute("aria-expanded", String(open));
  renderActivity();
}

function initActivityPanel() {
  const toggle = document.getElementById("activity-toggle");
  if (!toggle) return;

  toggle.addEventListener("click", () => setActivityPanelOpen(!activityPanelOpen));
  const close = document.getElementById("activity-close");
  if (close) close.addEventListener("click", () => setActivityPanelOpen(false));

  const copy = document.getElementById("activity-copy");
  if (copy) {
    copy.addEventListener("click", async () => {
      const text = activityEntries.map((e) => `${e.at}  ${e.text}`).join("\n");
      try {
        await navigator.clipboard.writeText(text);
        copy.textContent = "Copied";
      } catch {
        // Clipboard access can be refused outright (permissions, insecure
        // context). Saying so beats a button that looks like it worked.
        copy.textContent = "Couldn't copy";
      }
      setTimeout(() => { copy.textContent = "Copy"; }, 1500);
    });
  }

  renderActivity();
}

document.addEventListener("DOMContentLoaded", initActivityPanel);
