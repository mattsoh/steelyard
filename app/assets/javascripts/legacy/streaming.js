// Everything to do with getting this organization's transactions out of HCB
// and onto the page: what to ask the server for, when the copy already in this
// browser will do, how to report a long walk while it runs, and what to do
// about one that is still running when the tab goes away.
//
// The matcher (/transactions/page) and the ledger (/ledger/page) stream the
// same underlying rows -- same TransactionPresenter shape -- and differ only in
// how they lay them out, so all of it lives here once.

// ---------------------------------------------------------------------------
// The row cache
// ---------------------------------------------------------------------------
//
// Keyed by the server's drain token rather than by a timestamp. The token names
// the exact drain every server-side cache entry belongs to
// (Hcb::OrganizationTransactions#drain_token) and changes on any new drain
// anywhere, so "is my copy current?" is an equality check against one small
// field rather than a guess about how long stale is too stale. That is the
// whole difference between the old ten-minute TTL and this: a ten-minute TTL is
// simultaneously too long (it will serve rows the server replaced a minute ago)
// and too short (it throws away a perfectly current copy at minute eleven and
// re-reads the organization for nothing).
//
// In localStorage rather than sessionStorage because the point is to survive
// the tab closing. sessionStorage is emptied on close, which meant the cache
// could only ever help somebody moving between the matcher and the ledger in
// one sitting -- never the much commoner case of coming back to an
// organization later.
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
// for minutes. A drain that lands quickly is noticed almost immediately; one
// that takes ten minutes costs a few dozen polls instead of hundreds.
const POLL_MIN_MS = 1000;
const POLL_MAX_MS = 8000;
const POLL_BACKOFF = 1.6;

const SYNC_POLL_TIMEOUT_MS = 180_000;
// A full reload re-walks the whole history rather than the recent window, so it
// gets a much longer leash before the client gives up waiting on it. Giving up
// only stops the *waiting* -- the server-side drain carries on regardless, and
// the next load picks it up.
const FULL_RELOAD_POLL_TIMEOUT_MS = 600_000;

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

// Thrown when the server says a full reload is rebuilding this organization's
// history. Not a failure: there is deliberately nothing to read until that
// drain lands, so callers wait for it rather than rendering an empty
// organization or starting a second walk of their own.
class ReloadInProgressError extends Error {
  constructor() {
    super("a full reload is in progress");
    this.name = "ReloadInProgressError";
  }
}

// ---------------------------------------------------------------------------
// Handing a walk over when this page goes away
// ---------------------------------------------------------------------------
//
// A streamed drain only advances while the tab driving it asks for the next
// page, so closing the tab mid-walk stops it dead. Server-side there is a job
// standing behind every stream ready to finish it from the pages already
// buffered -- but it has to wait out the claim's heartbeat first, because from
// the outside a tab that has gone is indistinguishable from one that is merely
// slow.
//
// This is the page saying which. sendBeacon is the one request a document can
// reliably get out while it is being torn down (a normal fetch is cancelled),
// and pagehide is the one event that fires on every path away -- close,
// navigate, and the bfcache freeze that fires no unload at all on iOS.
const activeStreams = new Set();

function registerStream(streamId) {
  if (streamId) activeStreams.add(streamId);
}

function unregisterStream(streamId) {
  activeStreams.delete(streamId);
}

function handOffActiveStreams() {
  // Form-encoded rather than JSON, and carrying the CSRF token in the body:
  // sendBeacon cannot set headers, so the X-CSRF-Token the rest of this app
  // sends (see hcb_csrf_shim.js) isn't available here. Rails checks the
  // `authenticity_token` parameter as well as the header, so a form-encoded
  // beacon verifies through the ordinary path rather than needing forgery
  // protection skipped for this endpoint.
  const csrf = document.querySelector('meta[name="csrf-token"]');

  for (const streamId of activeStreams) {
    try {
      const body = new URLSearchParams({ stream_id: streamId });
      if (csrf) body.set("authenticity_token", csrf.content);
      navigator.sendBeacon(`${orgApiBase()}/api/transactions/handoff`, body);
    } catch {
      // Nothing to fall back to at this point in a page's life, and nothing
      // lost: without the beacon the server waits out the heartbeat instead,
      // which is the same outcome about ninety seconds later.
    }
  }
  activeStreams.clear();
}

window.addEventListener("pagehide", handOffActiveStreams);

// ---------------------------------------------------------------------------
// Status
// ---------------------------------------------------------------------------

// The one cheap request that decides what a load costs. Cache-only server-side
// -- it never touches HCB -- so asking it on every page load, and polling it
// while a drain runs, can't eat into the rate limit everyone shares.
//
// Answers with the drain token (is this browser's copy current?), whether a
// walk is in flight and of what kind, and how far that walk has got.
async function syncStatus() {
  try {
    const res = await fetch(`${orgApiBase()}/api/transactions/sync_status`);
    if (!res.ok) return null;
    return await res.json();
  } catch {
    return null;
  }
}

// Turns the server's progress record into the one shape every caller renders,
// so the progress bar doesn't have to know whether it is watching its own
// stream, somebody else's, or a background job.
function progressSnapshot(status, extra = {}) {
  const p = (status && status.progress) || null;
  return {
    phase: (p && p.phase) || (extra.phase ?? "draining"),
    kind: (p && p.kind) || status?.drain_kind || extra.kind || null,
    // "browser" means a tab is driving it and closing that tab stalls it;
    // "background" means a job is, and nothing the viewer does can interrupt it.
    source: (p && p.source) || extra.source || null,
    loaded: (p && p.transactions_done) ?? extra.loaded ?? 0,
    total: (p && p.total_count) ?? extra.total ?? null,
    pages: (p && p.pages_done) ?? extra.pages ?? 0,
    // The server's own judgment, made against its own clock: nothing has
    // advanced this record for long enough that whoever was writing it is
    // presumed gone. Worth showing, because a stalled walk and a slow one look
    // identical from here and mean very different things.
    stalled: !!(p && p.stalled),
    error: (p && p.error) || null,
  };
}

// ---------------------------------------------------------------------------
// Waiting on somebody else's drain
// ---------------------------------------------------------------------------

// Polls until the server publishes a drain newer than the one the caller
// started from, reporting progress as it goes. Backs off, and stops entirely
// while the tab is hidden.
//
// Resolves true when a newer drain landed, false on timeout -- which is not the
// same as failure. The server-side walk carries on regardless; the caller has
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

      // Reset the backoff whenever the walk actually moves: a drain making
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

// Waits out a full reload someone else started, then reports whether it landed.
// Deliberately keyed off no starting point: a reload purges the freshness stamp
// (Hcb::OrganizationTransactions#purge!), so any fetched_at at all is newer than
// what's there now.
function waitForReloadToLand({ onProgress } = {}) {
  return waitForNewerDrain(null, FULL_RELOAD_POLL_TIMEOUT_MS, { onProgress });
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
// includes waiting out the background redrain the server kicks off when more
// changed than one page could account for. That wait is the whole point of
// doing it this way: the page keeps its current rows on screen and stays
// usable while the sync runs, instead of blanking out behind a drain.
//
// Never throws: a refresh that fails is a no-op, not a broken page.
async function syncNewTransactions({ onSyncing, onProgress } = {}) {
  let started;
  logActivity("asking HCB whether anything new has landed…");
  try {
    const res = await fetch(`${orgApiBase()}/api/transactions/refresh`, { method: "POST" });
    if (!res.ok) {
      logActivity(`the check failed (HTTP ${res.status})`, "error");
      return false;
    }
    started = await res.json();
  } catch {
    logActivity("the check couldn't reach Steelyard", "error");
    return false;
  }

  logActivity(`HCB says: ${started.status}${activityHcbClause(started.hcb)}`, "hcb");

  if (started.status === "fresh") {
    logActivity("already up to date", "done");
    return false;
  }

  // A walk is already building this organization's history, which covers
  // everything this check would have asked for. Wait for it rather than
  // queueing a second one behind it: "reloading" is somebody's deliberate
  // re-read of the whole history, "draining" is the organization simply not
  // having been loaded yet.
  if (started.status === "reloading" || started.status === "draining") {
    logActivity(
      started.status === "reloading"
        ? "a full reload is already rebuilding this organization — waiting for it"
        : "this organization is still being loaded — waiting for that rather than starting a second load",
      "warn",
    );
    invalidateCachedTransactionRows();
    if (onSyncing) onSyncing();
    return started.status === "reloading"
      ? waitForReloadToLand({ onProgress })
      : waitForNewerDrain(started.fetched_at, SYNC_POLL_TIMEOUT_MS, { onProgress });
  }

  // Anything other than "fresh" means the server's copy has moved on, so the
  // client-side row cache is stale too -- drop it before any reload reads it.
  invalidateCachedTransactionRows();
  if (started.status === "synced") {
    logActivity("new activity found and spliced into the cache", "done");
    return true;
  }

  // "deep": a background job is re-walking recent history. Poll the
  // cache-only status endpoint (which never touches HCB) until it publishes a
  // drain newer than the one we started from.
  logActivity("more changed than one page explains — a background redrain is running", "warn");
  if (onSyncing) onSyncing();
  return waitForNewerDrain(started.fetched_at, SYNC_POLL_TIMEOUT_MS, { onProgress });
}

// ---------------------------------------------------------------------------
// The full reload
// ---------------------------------------------------------------------------

// Asks the server to re-walk the organization's ENTIRE history from HCB, rather
// than the recent window syncNewTransactions settles for, and waits for the
// result to land. Expensive enough (one HCB request per 100 transactions of
// total history, against a rate limit shared by everyone using this app) that
// callers confirm with the user first -- it's the escape hatch for a cached
// transaction that changed too far back for an incremental drain to notice.
//
// Same contract as syncNewTransactions for the result: resolves true only once
// the server has actually published fresher data, and never throws. Unlike it,
// this doesn't try to keep the current rows usable while it runs -- everything
// the drain is replacing is exactly what someone reaching for this button has
// decided not to trust, so onSyncing is where callers clear their view before
// the fresh copy starts arriving. onSyncing firing is also the signal that the
// server accepted the reload: it's skipped entirely when the request itself
// failed, so a caller can tell "never started" from "started and still running".
//
// When this tab is the one that won the claim, it drives the walk itself and
// calls onPage for every page as it lands, so a reload of a large organization
// fills the view in as it goes instead of leaving it blank for minutes. Losing
// the claim (another tab, or someone else, got there first) means someone else
// is already driving the same drain, so there's nothing to render page by page
// and this falls back to waiting for their result.
//
// Giving up on the stream isn't giving up on the reload: a background job is
// queued behind it server-side, so a stream that breaks mid-history is picked
// up and finished from the pages already buffered. That's why every bail-out
// here goes to waitForNewerDrain rather than returning false -- the drain is
// still coming.
async function fullReloadTransactions({ onSyncing, onPage, onProgress } = {}) {
  let started;
  logActivity("full reload requested — clearing this organization's cached history", "warn");
  try {
    const res = await fetch(`${orgApiBase()}/api/transactions/reload`, { method: "POST" });
    if (!res.ok) {
      logActivity(`the full reload wouldn't start (HTTP ${res.status})`, "error");
      return false;
    }
    started = await res.json();
  } catch {
    logActivity("the full reload couldn't reach Steelyard", "error");
    return false;
  }

  invalidateCachedTransactionRows();
  if (onSyncing) onSyncing();

  // "already_running": no stream_id, because the claim (and the walk) belongs
  // to whoever started it. Wait for the drain they're driving.
  if (!started.stream_id || !onPage) {
    logActivity(
      started.status === "already_running"
        ? "somebody else is already reloading this organization — waiting for their drain"
        : "waiting for the reload to land",
      "warn",
    );
    return waitForNewerDrain(started.fetched_at, FULL_RELOAD_POLL_TIMEOUT_MS, { onProgress });
  }

  logActivity("re-reading the whole history from HCB, one page at a time…");

  try {
    await loadPagesStreaming(`${orgApiBase()}/api/transactions/page`, onPage, {
      params: { reload: "1" },
      streamId: started.stream_id,
      useCache: false,
      onProgress,
    });
    logActivity("full reload complete", "done");
    return true;
  } catch {
    // The drain doesn't stop when this tab does -- a job behind it finishes from
    // the pages already fetched -- so this is a handover, not a failure.
    logActivity("lost the reload stream — a background job is finishing it", "warn");
    return waitForNewerDrain(started.fetched_at, FULL_RELOAD_POLL_TIMEOUT_MS, { onProgress });
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
  "You can close this tab once it has started — it finishes in the background either way.\n\n" +
  "Start the full reload?";

// ---------------------------------------------------------------------------
// Loading the rows
// ---------------------------------------------------------------------------

// Gets this organization's transactions onto the page by the cheapest route
// available, calling onPage with each batch as it becomes available and
// onProgress with a running account of what it is doing.
//
// In order of cost:
//
//   1. This browser already holds rows for the drain the server is currently
//      serving. One small status request, no pages, nothing from HCB.
//   2. The server's cache is warm, or a splice brings it up to date inside one
//      request. One page request that carries the whole history.
//   3. Somebody else is already walking this organization. Wait for their
//      result rather than buying a second copy of it out of the shared rate
//      limit, then take route 1 or 2.
//   4. Nothing to build on: walk HCB a page at a time, rendering as we go.
//
// `useCache: false` and an explicit `streamId` are what a full reload streams
// with: it must not be answered from any cache (re-reading history is the whole
// point), and the server only honours reload-mode pages for the stream_id its
// claim was recorded against, so the id can't be minted here.
async function loadPagesStreaming(pageUrl, onPage, { params = {}, streamId, useCache = true, onProgress } = {}) {
  const reportProgress = (snapshot) => { if (onProgress) onProgress(snapshot); };

  if (useCache) {
    // One request that answers both "is my copy still good?" and "is anything
    // happening right now?". Everything below turns on it, which is why it
    // comes before the first page rather than after it.
    const status = await syncStatus();

    if (status && status.reloading) throw new ReloadInProgressError();

    const cached = readCachedRows(status && status.token);
    if (cached) {
      logActivity(
        `${cached.rows.length} transactions from this browser's copy of the current drain — nothing to fetch`,
        "done",
      );
      reportProgress({ phase: "done", loaded: cached.rows.length, total: cached.totalCount, source: "cache" });
      onPage(cached.rows, cached.totalCount);
      return;
    }

    // Somebody else -- another tab, another person, or a background job -- is
    // already walking this organization. Two walks of the same history is the
    // most expensive mistake this app can make against the shared rate limit,
    // so wait for theirs and then read the result.
    if (status && status.draining) {
      logActivity("this organization is already being loaded — waiting for that rather than starting a second one", "warn");
      reportProgress(progressSnapshot(status));
      const timeout = status.drain_kind === "reload" ? FULL_RELOAD_POLL_TIMEOUT_MS : SYNC_POLL_TIMEOUT_MS;
      await waitForNewerDrain(status.fetched_at, timeout, { onProgress });
    }
  }

  const activeStreamId = streamId || crypto.randomUUID();
  // From here on this tab may be the one driving a walk, so a close has to hand
  // it over rather than abandon it.
  registerStream(activeStreamId);

  let after = null;
  let allRows = [];
  let totalCount;
  let token = null;
  let pageNumber = 1;
  const streamStarted = Date.now();

  try {
    while (true) {
      const url = new URL(pageUrl, window.location.origin);
      if (after) url.searchParams.set("after", after);
      url.searchParams.set("stream_id", activeStreamId);
      for (const [key, value] of Object.entries(params)) url.searchParams.set(key, value);

      const pageStarted = Date.now();
      const res = await fetch(url);
      if (!res.ok) {
        logActivity(`transactions page ${pageNumber} failed (HTTP ${res.status})`, "error");
        throw new Error("bad response");
      }
      const data = await res.json();
      if (data.reloading) {
        logActivity("a full reload owns this organization's history — waiting for it", "warn");
        throw new ReloadInProgressError();
      }

      // The walk was taken over while we were driving it -- by the job behind
      // this stream after the tab was suspended, or by another claimant. Carrying
      // on would re-walk history the owner is already walking and publish a
      // result over theirs, so wait for what they produce instead.
      if (data.waiting) {
        logActivity("another loader took this organization over — waiting for its result", "warn");
        const landed = await waitForNewerDrain(null, SYNC_POLL_TIMEOUT_MS, { onProgress });
        if (!landed) throw new Error("timed out waiting for the drain that took over");

        const owner = await syncStatus();
        const cached = readCachedRows(owner && owner.token);
        if (cached) {
          onPage(cached.rows, cached.totalCount);
          return;
        }
        // Nothing local to show for it, but the server is warm now, so a fresh
        // stream costs one page request rather than a walk.
        unregisterStream(activeStreamId);
        return loadPagesStreaming(pageUrl, onPage, { params, useCache: false, onProgress });
      }

      logActivity(
        `page ${pageNumber}: ${data.rows.length} transactions in ${Date.now() - pageStarted}ms`
        + activityCacheNote(data.hcb),
        data.hcb && data.hcb.requests ? "hcb" : "info",
      );
      pageNumber += 1;

      allRows.push(...data.rows);
      totalCount = data.total_count;
      if (data.token) token = data.token;
      onPage(data.rows, data.total_count);

      reportProgress({
        phase: data.has_more ? "draining" : "done",
        kind: data.warm || data.spliced ? "incremental" : "cold",
        source: "browser",
        loaded: data.streamed ?? allRows.length,
        total: data.total_count,
        pages: pageNumber - 1,
      });

      if (!data.has_more) break;
      after = data.next_after;
    }
  } finally {
    // Whether the walk finished, failed, or was taken over, this tab is no
    // longer driving it and must not beacon a handoff for it on the way out.
    unregisterStream(activeStreamId);
  }

  logActivity(
    `all ${allRows.length} transactions loaded in ${((Date.now() - streamStarted) / 1000).toFixed(1)}s`,
    "done",
  );

  // Written once the drain is fully done, not per-page -- per-page would mean
  // JSON.stringify-ing the whole (ever-growing) row set on every round trip,
  // and would also leave a *partial* drain cached as if it were complete for
  // any load that gets interrupted before `has_more` goes false. Keyed by the
  // token the finishing page carried, so the next load can prove it current.
  writeCachedRows(token, allRows, totalCount);
}
