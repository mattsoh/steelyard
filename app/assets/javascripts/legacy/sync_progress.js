// The progress bar both pages show while this organization's transactions are
// being fetched.
//
// A drain here is not a spinner-length wait. A cold load of a large
// organization is one HCB round trip per hundred transactions, in sequence, and
// a full reload re-walks the lot -- minutes, either of them. The old UI for
// that was a rotating ring and a count of rows received, which answers neither
// of the two questions anybody waiting actually has: how much is left, and is
// this thing still moving?
//
// So this renders the server's own progress record (Hcb::DrainProgress) of the
// one background task loading the organization, which means it reads the same
// in every tab -- the one that asked, one opened a minute later, one that came
// back after being closed. It also says who started it and that closing the
// tab is safe, because that is the single most useful thing this page can tell
// someone watching a five-minute load.

// Long enough to read "done" and see the bar full, short enough not to linger
// over the data it was describing.
const SYNC_PROGRESS_DISMISS_MS = 1200;

// A task still in "starting" after this long has not been picked up by any job
// worker: Solid Queue isn't running, or the queue it's working isn't this one.
// Said outright, once, because the bar otherwise looks merely slow.
const SYNC_PROGRESS_NO_WORKER_S = 20;
let syncProgressNoWorkerNoted = false;

let syncProgressHideTimer = null;

function syncProgressEl(id) {
  return document.getElementById(id);
}

// What the walk is, in the words someone waiting on it would use.
function syncProgressLabel(snapshot) {
  if (snapshot.phase === "failed") return "Loading failed";
  if (snapshot.phase === "done") return "Up to date";
  if (snapshot.source === "cache") return "Up to date";

  switch (snapshot.kind) {
    case "reload":      return "Re-reading the full history from HCB";
    case "incremental": return "Checking HCB for new activity";
    case "cold":        return "Loading this organization's transactions from HCB";
    default:            return "Working…";
  }
}

// The line under the bar: who started this and what the person watching is
// free to do. The walk is a background task's, never this tab's, so the answer
// to "can I close this?" is always yes.
function syncProgressNote(snapshot) {
  if (snapshot.phase === "failed") {
    return snapshot.error ? `HCB or Steelyard returned: ${snapshot.error}` : "Try again in a moment.";
  }
  const by = snapshot.requestedBy ? `Started by ${snapshot.requestedBy}. ` : "";
  if (snapshot.stalled) {
    return `${by}It has stopped responding — the next request will pick it up from where it left off.`;
  }
  if (snapshot.phase === "starting") {
    if (snapshot.age !== null && snapshot.age >= SYNC_PROGRESS_NO_WORKER_S) {
      if (!syncProgressNoWorkerNoted) {
        syncProgressNoWorkerNoted = true;
        logActivity(
          `no background worker has picked this load up in ${Math.round(snapshot.age)}s — is the job worker running? (Solid Queue: SOLID_QUEUE_IN_PUMA=true, or bin/jobs)`,
          "error",
        );
      }
      return `${by}No background worker has picked this up for ${Math.round(snapshot.age)}s — is the job worker (Solid Queue) running?`;
    }
    return `${by}Waiting for a background worker to pick it up…`;
  }
  if (snapshot.phase === "publishing") return `${by}Finishing up — organising what came back.`;
  if (snapshot.phase === "splicing")   return `${by}Joining the new activity onto what was already loaded.`;
  if (snapshot.source === "inline")    return `${by}Running inside a request on the server.`;
  if (snapshot.source === "background") return `${by}Running in the background — you can close this tab, and other tabs see the same progress.`;
  return by.trim();
}

// `loaded of ~total`, where the tilde is not decoration: HCB's total_count is
// its own count of a list that can move under a multi-page walk.
function syncProgressCount(snapshot) {
  if (!snapshot.loaded && !snapshot.total) return "";
  if (!snapshot.total) return `${snapshot.loaded.toLocaleString()} so far`;
  return `${snapshot.loaded.toLocaleString()} of ~${snapshot.total.toLocaleString()}`;
}

function renderSyncProgress(snapshot) {
  const panel = syncProgressEl("sync-progress");
  if (!panel || !snapshot) return;

  if (syncProgressHideTimer) {
    clearTimeout(syncProgressHideTimer);
    syncProgressHideTimer = null;
  }

  // Nothing worth a progress bar: a load answered entirely from this browser's
  // own copy is over before it could be rendered, and showing a bar that
  // immediately completes is just a flash.
  if (snapshot.source === "cache") {
    hideSyncProgress();
    return;
  }

  panel.classList.remove("hidden");
  panel.classList.toggle(
    "sync-progress-stalled",
    !!snapshot.stalled || (snapshot.phase === "starting" && snapshot.age !== null && snapshot.age >= SYNC_PROGRESS_NO_WORKER_S),
  );
  panel.classList.toggle("sync-progress-failed", snapshot.phase === "failed");

  syncProgressEl("sync-progress-label").textContent = syncProgressLabel(snapshot);
  syncProgressEl("sync-progress-count").textContent = syncProgressCount(snapshot);
  syncProgressEl("sync-progress-note").textContent = syncProgressNote(snapshot);

  const bar = syncProgressEl("sync-progress-bar");
  const done = snapshot.phase === "done";
  // No denominator yet (HCB hasn't said how many there are, or this is a splice
  // whose size isn't knowable up front) -- so the bar animates rather than
  // claiming a position it can't know. A made-up percentage is worse than none.
  const indeterminate = !done && (!snapshot.total || snapshot.total <= 0);

  panel.classList.toggle("sync-progress-indeterminate", indeterminate);
  if (indeterminate) {
    bar.style.width = "";
    panel.removeAttribute("aria-valuenow");
  } else {
    const pct = done ? 100 : Math.max(2, Math.min(99, Math.round((snapshot.loaded / snapshot.total) * 100)));
    bar.style.width = `${pct}%`;
    panel.setAttribute("aria-valuenow", String(pct));
  }

  if (done) syncProgressHideTimer = setTimeout(hideSyncProgress, SYNC_PROGRESS_DISMISS_MS);
}

function hideSyncProgress() {
  const panel = syncProgressEl("sync-progress");
  if (!panel) return;

  if (syncProgressHideTimer) {
    clearTimeout(syncProgressHideTimer);
    syncProgressHideTimer = null;
  }
  panel.classList.add("hidden");
  panel.classList.remove("sync-progress-stalled", "sync-progress-failed", "sync-progress-indeterminate");
  panel.removeAttribute("aria-valuenow");
}
