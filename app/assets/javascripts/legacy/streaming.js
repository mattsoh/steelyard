// Everything to do with getting this organization's transactions out of HCB
// and onto the page: what to ask the server for, when the copy already in this
// browser will do, and how to follow a long load while it runs.
//
// The load itself does not happen here. It runs server-side as one background
// task per organization (Hcb::OrganizationTransactions#run_task!), started by
// whichever request first finds the organization cold and shared by every tab
// after that. This file only watches that task: it polls the same progress
// record and the same activity log every other viewer polls, renders the pages
// the task has fetched so far, and reads the finished result once it lands.
// Closing the tab changes nothing about the walk -- there is no handoff,
// because there is nothing to hand off.
//
// The matcher (/transactions/page) and the ledger (/ledger/page) load the same
// underlying rows -- same TransactionPresenter shape -- and differ only in how
// they lay them out, so all of it lives here once.

// ---------------------------------------------------------------------------
// The row cache
// ---------------------------------------------------------------------------
//
// Keyed by the server's drain token rather than by a timestamp. The token names
// the exact drain every server-side cache entry belongs to
// (Hcb::OrganizationTransactions#drain_token) and changes on any new drain
// anywhere, so "is my copy current?" is an equality check against one small
// field rather than a guess about how long stale is too stale.
//
// In localStorage rather than sessionStorage because the point is to survive
// the tab closing.
const ROWS_CACHE_PREFIX = "steelyard.rows.";

// Above this a write is doing more harm than good: JSON.stringify of several
// megabytes blocks the main thread, and localStorage is a shared ~5MB budget
// this app also keeps unsaved match trays in. A very large organization simply
// doesn't get a client-side cache; it still gets the server's.
const ROWS_CACHE_MAX_BYTES = 3_500_000;

// Not a freshness check -- the token is that. This only stops a cache entry for
// an organization nobody opens any more from sitting in localStorage forever.
const ROWS_CACHE_MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000;

function rowsCacheKey() {
  return `${ROWS_CACHE_PREFIX}${window.HCB_ORGANIZATION_ID}`;
}

// The rows this browser holds, but only if they belong to the drain the server
// is currently serving. A mismatch isn't an error -- it's the ordinary "the
// organization moved on" case -- and answers null so the caller loads properly.
function readCachedRows(token) {
  if (!token) return null;
  try {
    const raw = localStorage.getItem(rowsCacheKey());
    if (!raw) return null;
    const entry = JSON.parse(raw);
    if (entry.token !== token) return null;
    if (Date.now() - entry.savedAt > ROWS_CACHE_MAX_AGE_MS) return null;
    return { rows: entry.rows, totalCount: entry.totalCount };
  } catch {
    return null;
  }
}

function writeCachedRows(token, rows, totalCount) {
  // No token means the drain that produced these rows has no name yet, so
  // nothing could ever prove the copy current again. Caching it would only
  // create something to mistrust later.
  if (!token) return;
  try {
    // Sized from a sample before serializing the lot: stringifying fifty
    // thousand rows to discover they don't fit is tens of megabytes of string
    // built and thrown away on every load of a large organization.
    const sample = rows.slice(0, 50);
    const estimate = sample.length ? (JSON.stringify(sample).length / sample.length) * rows.length : 0;
    if (estimate > ROWS_CACHE_MAX_BYTES) {
      localStorage.removeItem(rowsCacheKey());
      return;
    }
    const payload = JSON.stringify({ token, savedAt: Date.now(), rows, totalCount });
    if (payload.length > ROWS_CACHE_MAX_BYTES) {
      // Drop whatever is there rather than leaving an older, smaller entry to
      // be served for a drain it no longer describes.
      localStorage.removeItem(rowsCacheKey());
      return;
    }
    localStorage.setItem(rowsCacheKey(), payload);
  } catch {
    // Quota, private mode, storage disabled. Best-effort by design: no cache is
    // a slower load, not a broken one.
    try { localStorage.removeItem(rowsCacheKey()); } catch { /* nothing left to try */ }
  }
}

function invalidateCachedTransactionRows() {
  try {
    localStorage.removeItem(rowsCacheKey());
  } catch {
    // Same best-effort reasoning as writing it.
  }
}

// ---------------------------------------------------------------------------
// Timings
// ---------------------------------------------------------------------------

// Polling starts responsive and backs off, rather than hammering a fixed 2.5s
// for minutes. A task that lands quickly is noticed almost immediately; one
// that takes ten minutes costs a few dozen polls instead of hundreds. The
// backoff resets whenever the task visibly moves.
const POLL_MIN_MS = 1000;
const POLL_MAX_MS = 8000;
const POLL_BACKOFF = 1.6;

const SYNC_POLL_TIMEOUT_MS = 180_000;
// A full walk of the history takes minutes on a large organization, so a
// cold load or a reload gets a much longer leash before the client gives up
// waiting on it. Giving up only stops the *waiting* -- the server-side task
// carries on regardless, and the next load picks it up.
const FULL_LOAD_POLL_TIMEOUT_MS = 600_000;

function orgApiBase() {
  return `/organizations/${window.HCB_ORGANIZATION_ID}`;
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Waits while the tab is in the background. Timers are throttled to once a
// minute or worse in a hidden tab, so a poll loop there isn't polling so much
// as occasionally twitching -- and every one of those twitches is a request
// nobody is looking at the answer to. Better to stop, and pick up promptly when
// somebody comes back.
function whenVisible() {
  if (!document.hidden) return Promise.resolve();
  return new Promise((resolve) => {
    const onVisible = () => {
      if (document.hidden) return;
      document.removeEventListener("visibilitychange", onVisible);
      resolve();
    };
    document.addEventListener("visibilitychange", onVisible);
  });
}

// Thrown when the task building this organization's history reported a
// failure and the server is not restarting it on its own (see
// Hcb::OrganizationTransactions::FAILURE_BACKOFF). The caller shows a retry;
// the retry asks for a fresh task explicitly.
class LoadFailedError extends Error {
  constructor(message) {
    super(message || "the load failed");
    this.name = "LoadFailedError";
  }
}

// ---------------------------------------------------------------------------
// Status
// ---------------------------------------------------------------------------

// Appended to every status and page request: the server sends back only the
// activity-log lines after this seq, so a poll a second carries what is new
// rather than the whole history each time. See activity.js, which owns the seq.
function withLogCursor(url) {
  const seq = typeof lastServerActivitySeq === "function" ? lastServerActivitySeq() : null;
  if (seq) url.searchParams.set("log_after", String(seq));
  return url;
}

// Pulls the server's activity-log lines and progress out of a response and
// into the panel and the bar. Every response that carries them goes through
// this, so a tab that just joined shows the same account as one that watched
// from the start.
function absorbServerActivity(payload) {
  if (payload && Array.isArray(payload.log) && typeof logServerActivity === "function") {
    logServerActivity(payload.log);
  }
}

// The one cheap request that decides what a load costs. Cache-only server-side
// -- it never touches HCB -- so asking it on every page load, and polling it
// while a task runs, can't eat into the rate limit everyone shares.
//
// Answers with the drain token (is this browser's copy current?), whether a
// task is in flight and of what kind, how far it has got, and what it has
// logged since the caller last asked.
async function syncStatus() {
  try {
    const res = await fetch(withLogCursor(new URL(`${orgApiBase()}/api/transactions/sync_status`, window.location.origin)).toString());
    if (!res.ok) return null;
    const status = await res.json();
    absorbServerActivity(status);
    return status;
  } catch {
    return null;
  }
}

// Turns the server's progress record into the one shape the progress bar
// renders, so it doesn't have to know whether it is watching a task this tab
// started, somebody else's, or the periodic background refresh.
function progressSnapshot(status, extra = {}) {
  const p = (status && status.progress) || null;
  return {
    phase: (p && p.phase) || (extra.phase ?? "draining"),
    kind: (p && p.kind) || status?.drain_kind || extra.kind || null,
    // "background" is a job; "inline" is a request that had to drain on its
    // own thread. Neither depends on any tab staying open.
    source: (p && p.source) || extra.source || null,
    requestedBy: (p && p.requested_by) || null,
    loaded: (p && p.transactions_done) ?? extra.loaded ?? 0,
    total: (p && p.total_count) ?? extra.total ?? null,
    pages: (p && p.pages_done) ?? extra.pages ?? 0,
    // The server's own judgment, made against its own clock: nothing has
    // advanced this record for long enough that whoever was writing it is
    // presumed gone. Worth showing, because a stalled walk and a slow one look
    // identical from here and mean very different things.
    stalled: !!(p && p.stalled),
    // Seconds since the server last advanced the record. A task that has sat
    // in "starting" for long is one no job worker has picked up, which is
    // worth saying outright rather than leaving as a bar that never moves.
    age: (p && typeof p.age === "number") ? p.age : null,
    error: (p && p.error) || null,
  };
}

// ---------------------------------------------------------------------------
// Waiting on a task
// ---------------------------------------------------------------------------

// Polls until the server publishes a drain newer than the one the caller
// started from, reporting progress as it goes. Backs off, and stops entirely
// while the tab is hidden.
//
// Resolves true when a newer drain landed, false on timeout -- which is not the
// same as failure. The server-side task carries on regardless; the caller has
// simply stopped watching it.
async function waitForNewerDrain(startedFetchedAt, timeoutMs = SYNC_POLL_TIMEOUT_MS, { onProgress } = {}) {
  const deadline = Date.now() + timeoutMs;
  let interval = POLL_MIN_MS;
  let sawProgress = false;

  while (Date.now() < deadline) {
    await sleep(interval);
    await whenVisible();

    const current = await syncStatus();
    if (current) {
      if (current.fetched_at && current.fetched_at !== startedFetchedAt) {
        if (onProgress) onProgress(progressSnapshot(current, { phase: "done" }));
        return true;
      }
      if (onProgress) onProgress(progressSnapshot(current));

      // Reset the backoff whenever the task actually moves: a drain making
      // visible progress is one worth watching closely, and a long quiet spell
      // is the only thing that should push the polls apart.
      const moved = current.progress && current.progress.updated_at;
      if (moved && moved !== sawProgress) {
        sawProgress = moved;
        interval = POLL_MIN_MS;
        continue;
      }
    }

    interval = Math.min(Math.round(interval * POLL_BACKOFF), POLL_MAX_MS);
  }
  return false;
}

// ---------------------------------------------------------------------------
// The "anything new?" check
// ---------------------------------------------------------------------------

// Cheap "has anything landed on HCB since this page's data was drained?"
// check. Server-side this is a single HCB request for the newest page of
// transactions (both directions, no filters) compared against the cached
// drain -- see Hcb::OrganizationTransactions#sync_head!.
//
// Resolves true only once the server's data has *actually* changed, which
// includes waiting out the background task the server starts when more
// changed than one page could account for. That wait is the whole point of
// doing it this way: the page keeps its current rows on screen and stays
// usable while the sync runs, instead of blanking out behind a drain.
//
// Never throws: a refresh that fails is a no-op, not a broken page.
async function syncNewTransactions({ onSyncing, onProgress } = {}) {
  let started;
  logActivity("asking HCB whether anything new has landed…");
  try {
    // A string, not a URL object: the CSRF shim (hcb_csrf_shim.js) attaches the
    // token to same-origin non-GET requests, and it has to be able to read the
    // URL off whatever is passed.
    const res = await fetch(withLogCursor(new URL(`${orgApiBase()}/api/transactions/refresh`, window.location.origin)).toString(), { method: "POST" });
    if (!res.ok) {
      logActivity(`the check failed (HTTP ${res.status})`, "error");
      return false;
    }
    started = await res.json();
  } catch {
    logActivity("the check couldn't reach Steelyard", "error");
    return false;
  }
  absorbServerActivity(started);

  if (started.status === "fresh") return false;

  // A task is already building this organization's history, which covers
  // everything this check would have asked for. Wait for it rather than
  // queueing a second one behind it: "reloading" is somebody's deliberate
  // re-read of the whole history, "draining" is a load already under way.
  if (started.status === "reloading" || started.status === "draining") {
    logActivity(
      started.status === "reloading"
        ? "a full reload is already rebuilding this organization — waiting for it"
        : "a load of this organization is already running — waiting for it rather than starting another",
      "warn",
    );
    invalidateCachedTransactionRows();
    if (onSyncing) onSyncing();
    return waitForNewerDrain(started.fetched_at, FULL_LOAD_POLL_TIMEOUT_MS, { onProgress });
  }

  // Anything other than "fresh" means the server's copy has moved on, so the
  // client-side row cache is stale too -- drop it before any reload reads it.
  invalidateCachedTransactionRows();
  if (started.status === "synced") return true;

  // "deep": a background task is re-walking recent history. Poll the
  // cache-only status endpoint (which never touches HCB) until it publishes a
  // drain newer than the one we started from.
  if (onSyncing) onSyncing();
  return waitForNewerDrain(started.fetched_at, SYNC_POLL_TIMEOUT_MS, { onProgress });
}

// ---------------------------------------------------------------------------
// The full reload
// ---------------------------------------------------------------------------

// Asks the server to re-walk the organization's ENTIRE history from HCB, rather
// than the recent window syncNewTransactions settles for, and follows the
// task until the result lands. Expensive enough (one HCB request per 100
// transactions of total history, against a rate limit shared by everyone using
// this app) that callers confirm with the user first -- it's the escape hatch
// for a cached transaction that changed too far back for an incremental drain
// to notice.
//
// Same contract as syncNewTransactions for the result: resolves true only once
// the server has actually published fresher data, and never throws. Unlike it,
// this doesn't try to keep the current rows usable while it runs -- everything
// the drain is replacing is exactly what someone reaching for this button has
// decided not to trust, so onSyncing is where callers clear their view before
// the fresh copy starts arriving. onSyncing firing is also the signal that the
// server accepted the request: it's skipped entirely when the request itself
// failed, so a caller can tell "never started" from "started and still running".
//
// Whether this tab started the reload or somebody else's did, the pages are
// rendered as the task fetches them -- onPage is called for each batch -- so a
// reload of a large organization fills the view in as it goes instead of
// leaving it blank for minutes.
async function fullReloadTransactions({ onSyncing, onPage, onProgress } = {}) {
  let started;
  logActivity("full reload requested…", "warn");
  try {
    const res = await fetch(withLogCursor(new URL(`${orgApiBase()}/api/transactions/reload`, window.location.origin)).toString(), { method: "POST" });
    if (!res.ok) {
      logActivity(`the full reload wouldn't start (HTTP ${res.status})`, "error");
      return false;
    }
    started = await res.json();
  } catch {
    logActivity("the full reload couldn't reach Steelyard", "error");
    return false;
  }
  absorbServerActivity(started);

  invalidateCachedTransactionRows();
  if (onSyncing) onSyncing();

  if (started.status === "already_running") {
    logActivity("a load of this organization is already running — following that one instead of starting a second", "warn");
  }

  try {
    await loadPagesStreaming(`${orgApiBase()}/api/transactions/page`, onPage || (() => {}), {
      useCache: false,
      timeoutMs: FULL_LOAD_POLL_TIMEOUT_MS,
      onProgress,
    });
    return true;
  } catch (e) {
    if (e instanceof LoadFailedError) {
      logActivity(`the reload failed: ${e.message}`, "error");
      return false;
    }
    // Timed out watching, which is not the drain stopping -- it is a job's,
    // and carries on. The caller re-reads whatever the server has.
    logActivity("stopped waiting on the reload — it is still running in the background", "warn");
    return false;
  }
}

// Shown before a full reload is started, on both pages. Deliberately blunt
// about the cost: "check for new" covers everything a full reload does *except*
// re-reading history that was already drained, so the only reason to reach for
// this one is a value that changed further back than that -- and it's paid for
// out of a rate limit the whole organization shares.
const FULL_RELOAD_WARNING =
  "Full reload re-reads this organization's entire transaction history from HCB.\n\n" +
  "It is slow (minutes, on a large organization) and uses a big share of the HCB rate limit everyone here shares. " +
  "“Check for new” already picks up new and recently-changed transactions — only use this if you think an older transaction changed.\n\n" +
  "This page clears its transactions while the reload runs, then loads the fresh copy from scratch when it lands.\n\n" +
  "It runs in the background — you can close this tab, and anyone else looking at this organization will see the same progress.\n\n" +
  "Start the full reload?";

// An authoritative response (/api/transactions, /api/ledger) that came back
// empty because a task is still building this organization's history -- not
// because the organization has no transactions.
//
// The two are identical on the wire apart from this flag, and getting it wrong
// means rendering "Nothing to show" over an organization that is mid-load. The
// server answers empty rather than waiting on the task because holding a web
// request open for a multi-minute drain is worse; the caller's job is to wait
// for it and ask again.
function isStillLoading(data, rows) {
  return !!(data && (data.draining || data.reloading)) && (!rows || rows.length === 0);
}

// ---------------------------------------------------------------------------
// Loading the rows
// ---------------------------------------------------------------------------

// Set once a load has ended in failure, so the very next load asks the server
// for a fresh task explicitly rather than being handed the failed record back
// (which is what every other poll gets, deliberately, for a minute).
let retryNextLoad = false;

// Gets this organization's transactions onto the page by the cheapest route
// available, calling onPage with each batch as it becomes available and
// onProgress with a running account of what is happening.
//
// onPage(rows, totalCount, { replace }) -- `replace: true` means these rows
// are the whole history and supersede anything rendered so far; otherwise
// they are the next pages of a walk in progress, to be added to it.
//
// In order of cost:
//
//   1. This browser already holds rows for the drain the server is currently
//      serving. One small status request, no pages, nothing from HCB.
//   2. The server's cache is warm. One request that carries the whole history.
//   3. A task is building the history -- started by whoever asked first, this
//      tab included. Render every page it has fetched so far, then poll for
//      more until the result lands, and read that.
//
// `useCache: false` is what a full reload uses: it must not be answered from
// this browser's copy (re-reading history is the whole point).
async function loadPagesStreaming(pageUrl, onPage, { useCache = true, onProgress, timeoutMs } = {}) {
  const reportProgress = (snapshot) => { if (onProgress) onProgress(snapshot); };

  if (useCache) {
    // One request that answers both "is my copy still good?" and "is anything
    // happening right now?". It also brings in the activity log, so the panel
    // shows the organization's history before a single row is fetched.
    const status = await syncStatus();
    const cached = readCachedRows(status && status.token);
    if (cached) {
      logActivity(
        `${cached.rows.length} transactions from this browser's copy of the current drain — nothing to fetch`,
        "done",
      );
      reportProgress({ phase: "done", loaded: cached.rows.length, total: cached.totalCount, source: "cache" });
      onPage(cached.rows, cached.totalCount, { replace: true });
      return;
    }
  }

  const retry = retryNextLoad;
  retryNextLoad = false;

  let afterPage = 0;
  let taskId = null;
  let rendered = 0;
  let interval = POLL_MIN_MS;
  let lastUpdated = null;
  let deadline = null;
  const loadStarted = Date.now();

  while (true) {
    const url = new URL(pageUrl, window.location.origin);
    url.searchParams.set("after_page", String(afterPage));
    if (retry && afterPage === 0 && taskId === null) url.searchParams.set("retry", "1");
    withLogCursor(url);

    const res = await fetch(url);
    if (!res.ok) {
      logActivity(`loading the transactions failed (HTTP ${res.status})`, "error");
      throw new Error("bad response");
    }
    const data = await res.json();
    absorbServerActivity(data);

    if (data.warm) {
      logActivity(
        `${data.rows.length} transactions from the server's cache`
        + (rendered ? ` — replaces the ${rendered} rendered while the load ran` : "")
        + ` (${((Date.now() - loadStarted) / 1000).toFixed(1)}s)`,
        "done",
      );
      onPage(data.rows, data.total_count, { replace: true });
      reportProgress({ phase: "done", kind: data.progress?.kind, loaded: data.rows.length, total: data.total_count, source: data.progress?.source });
      writeCachedRows(data.token, data.rows, data.total_count);
      return;
    }

    const task = data.progress;

    // The task failed and the server has decided not to restart it on its own.
    // Nothing is coming; say so, and let the caller offer a retry.
    // (A failure the server *is* retrying comes back as the new task's record,
    // not as "failed", so seeing the phase here always means it has stopped.)
    if (task && task.phase === "failed") {
      retryNextLoad = true;
      reportProgress(progressSnapshot(data));
      throw new LoadFailedError(task.error);
    }

    // A different task from the one whose pages we have been rendering -- the
    // previous one died and was taken over, or a reload replaced it. Its page
    // numbering may not line up with what is on screen, so start over from its
    // first page rather than appending.
    if (task && taskId !== null && task.task_id !== taskId) {
      logActivity("a new load task has taken over — re-reading its pages from the start", "warn");
      onPage([], task.total_count, { replace: true });
      rendered = 0;
      afterPage = 0;
      taskId = task.task_id;
      continue;
    }

    // No task record at all (nothing claimed, nothing cached) is not a state
    // the server should answer with, but a poll loop with no way out would be
    // worse than trusting it: give it the ordinary leash.
    if (!task && deadline === null) deadline = Date.now() + (timeoutMs ?? SYNC_POLL_TIMEOUT_MS);

    if (task && taskId === null) {
      taskId = task.task_id;
      deadline = Date.now() + (timeoutMs ?? (task.kind === "incremental" ? SYNC_POLL_TIMEOUT_MS : FULL_LOAD_POLL_TIMEOUT_MS));
      const who = task.requested_by ? ` started by ${task.requested_by}` : "";
      logActivity(
        task.pages_done
          ? `following the load${who} — ${task.pages_done} page${task.pages_done === 1 ? "" : "s"} fetched so far`
          : `following the load${who}`,
      );
    }

    if (data.rows && data.rows.length) {
      rendered += data.rows.length;
      onPage(data.rows, data.total_count, { replace: false });
    }
    afterPage = Math.max(afterPage, data.pages_done || 0);
    reportProgress(progressSnapshot(data));

    if (deadline && Date.now() > deadline) {
      logActivity("stopped waiting on this load — it is still running in the background", "warn");
      throw new Error("timed out waiting for the load");
    }

    // Poll again, backing off while nothing moves and snapping back to the
    // floor whenever the task advances.
    const moved = task && task.updated_at;
    if (moved && moved !== lastUpdated) {
      lastUpdated = moved;
      interval = POLL_MIN_MS;
    } else {
      interval = Math.min(Math.round(interval * POLL_BACKOFF), POLL_MAX_MS);
    }
    await sleep(interval);
    await whenVisible();
  }
}
