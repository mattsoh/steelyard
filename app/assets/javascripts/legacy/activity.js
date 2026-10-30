// A running account of what is happening to this organization's HCB data, in a
// panel you can open when you want it and ignore when you don't.
//
// Two sources feed it. The server's activity log (Hcb::ActivityLog) is written
// by the background task that loads the organization -- and by the checks
// around it -- and is the same for every tab: open a second tab, or come back
// to an organization an hour later, and the panel shows the same pages, the
// same timings, the same "started by" lines that anyone else watching saw.
// This tab's own lines (what it asked for, what it rendered) are layered in
// alongside, marked so the two can be told apart.
//
// Loaded before the page scripts, so they can log from the top of a load.

// Enough to explain a load, not enough to become a memory leak on a page left
// open all day. Oldest lines drop off the top.
const ACTIVITY_MAX_ENTRIES = 400;

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
// The newest server-log seq this tab has rendered. Sent back with every poll
// (see withLogCursor in streaming.js) so the server only has to return what
// is new, and used here to drop anything that arrives twice.
let serverActivitySeq = 0;

// Wall-clock time, not elapsed-since-load: the server's lines were written by
// a task that may have started before this tab existed, and "14:02:11" reads
// the same in every tab where "+3.2s" would not.
function activityTime(atMs) {
  const d = new Date(atMs);
  const pad = (n) => String(n).padStart(2, "0");
  return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}

function pushActivity(entry) {
  activityEntries.push(entry);
  // Server lines can arrive out of step with this tab's own (a poll brings the
  // last few seconds of a task's log in one go), so the panel is kept in time
  // order rather than arrival order.
  activityEntries.sort((a, b) => a.at - b.at);
  while (activityEntries.length > ACTIVITY_MAX_ENTRIES) activityEntries.shift();
  if (!activityPanelOpen) activityUnseen += 1;
}

// This tab's own line. kind drives only the colour: "info" (default), "hcb"
// for something HCB did, "warn" for something worth noticing, "error" for
// something that failed, "done" for something finishing.
function logActivity(text, kind = "info") {
  pushActivity({ at: Date.now(), text, kind, source: "tab" });
  renderActivity();
}

// Lines from the server's log, as Hcb::ActivityLog#read returns them:
// { seq, at (epoch seconds), kind, text }. Anything already shown is skipped.
function logServerActivity(entries) {
  let added = false;
  for (const e of entries) {
    if (!e || typeof e.seq !== "number" || e.seq <= serverActivitySeq) continue;
    serverActivitySeq = e.seq;
    pushActivity({ at: Math.round(e.at * 1000), text: e.text, kind: e.kind || "info", source: "server" });
    added = true;
  }
  if (added) renderActivity();
}

function lastServerActivitySeq() {
  return serverActivitySeq;
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
      .map((e) => `<li class="activity-line activity-${escapeHtml(e.kind)} activity-from-${escapeHtml(e.source)}"`
        + ` title="${e.source === "server" ? "Recorded by the server — the same for everyone viewing this organization" : "This tab"}">`
        + `<span class="activity-at">${escapeHtml(activityTime(e.at))}</span>`
        + `<span class="activity-source" aria-hidden="true">${e.source === "server" ? "⚙" : "·"}</span>`
        + `${escapeHtml(e.text)}</li>`)
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
      const text = activityEntries
        .map((e) => `${activityTime(e.at)}  ${e.source === "server" ? "[server] " : "[tab]    "}${e.text}`)
        .join("\n");
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
