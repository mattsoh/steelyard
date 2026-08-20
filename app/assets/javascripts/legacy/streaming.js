// Matcher's /transactions/page and ledger's /ledger/page both stream the same
// underlying HCB transaction rows (same TransactionPresenter shape) for this
// org -- just consumed differently by each page. Caching them client-side,
// keyed by org rather than by which page fetched them, means switching
// between matcher and ledger shortly after one has loaded skips the
// multi-page drain (and its loading UI) entirely on the second page.
const TRANSACTIONS_CACHE_TTL_MS = 600_000;

function transactionsCacheKey() {
  return `txn-rows-cache:${window.HCB_ORGANIZATION_ID}`;
}

function readCachedTransactionRows() {
  try {
    const raw = sessionStorage.getItem(transactionsCacheKey());
    if (!raw) return null;
    const { savedAt, rows, totalCount } = JSON.parse(raw);
    if (Date.now() - savedAt > TRANSACTIONS_CACHE_TTL_MS) return null;
    return { rows, totalCount };
  } catch {
    return null;
  }
}

function writeCachedTransactionRows(rows, totalCount) {
  try {
    sessionStorage.setItem(transactionsCacheKey(), JSON.stringify({ savedAt: Date.now(), rows, totalCount }));
  } catch {
    // Best-effort -- quota errors or private-mode restrictions just mean no cache, not a load failure.
  }
}

function invalidateCachedTransactionRows() {
  try {
    sessionStorage.removeItem(transactionsCacheKey());
  } catch {
    // Same best-effort reasoning as writing it.
  }
}

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
const SYNC_POLL_INTERVAL_MS = 2500;
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

async function syncNewTransactions({ onSyncing } = {}) {
  let started;
  try {
    const res = await fetch(`${orgApiBase()}/api/transactions/refresh`, { method: "POST" });
    if (!res.ok) return false;
    started = await res.json();
  } catch {
    return false;
  }

  if (started.status === "fresh") return false;

  // Anything other than "fresh" means the server's copy has moved on, so the
  // client-side row cache is stale too -- drop it before any reload reads it.
  invalidateCachedTransactionRows();
  if (started.status === "synced") return true;

  // "deep": a background job is re-walking recent history. Poll the
  // cache-only status endpoint (which never touches HCB) until it publishes a
  // drain newer than the one we started from.
  if (onSyncing) onSyncing();
  return waitForNewerDrain(started.fetched_at);
}

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
async function fullReloadTransactions({ onSyncing, onPage } = {}) {
  let started;
  try {
    const res = await fetch(`${orgApiBase()}/api/transactions/reload`, { method: "POST" });
    if (!res.ok) return false;
    started = await res.json();
  } catch {
    return false;
  }

  invalidateCachedTransactionRows();
  if (onSyncing) onSyncing();

  // "already_running": no stream_id, because the claim (and the walk) belongs
  // to whoever started it. Wait for the drain they're driving.
  if (!started.stream_id || !onPage) {
    return waitForNewerDrain(started.fetched_at, FULL_RELOAD_POLL_TIMEOUT_MS);
  }

  try {
    await loadPagesStreaming(`${orgApiBase()}/api/transactions/page`, onPage, {
      params: { reload: "1" },
      streamId: started.stream_id,
      useCache: false,
    });
    return true;
  } catch {
    return waitForNewerDrain(started.fetched_at, FULL_RELOAD_POLL_TIMEOUT_MS);
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
  "Start the full reload?";

// Polls the cache-only status endpoint (which never touches HCB, so polling it
// can't eat into the shared rate limit) until the server publishes a drain
// newer than the one the caller started from.
async function waitForNewerDrain(startedFetchedAt, timeoutMs = SYNC_POLL_TIMEOUT_MS) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    await sleep(SYNC_POLL_INTERVAL_MS);
    try {
      const res = await fetch(`${orgApiBase()}/api/transactions/sync_status`);
      if (!res.ok) continue;
      const current = await res.json();
      if (current.fetched_at && current.fetched_at !== startedFetchedAt) return true;
    } catch {
      // Transient failure mid-poll -- keep waiting until the deadline.
    }
  }
  return false;
}

// Drains a paginated .../page endpoint one HTTP round trip per page, calling
// onPage as soon as each one resolves -- lets the ledger/matcher pages render
// rows while the backing HCB drain (which can be dozens of sequential
// requests on a cold cache) is still running, instead of blocking on one long
// request. Once the page loop is done, the server's transaction cache is warm,
// so the caller's follow-up request for the fully-computed view is fast.
// `useCache: false` and an explicit `streamId` are what a full reload streams
// with: it must not be answered from the client-side row cache (re-reading
// history is the whole point), and the server only honours reload-mode pages
// for the stream_id its claim was recorded against, so the id can't be minted
// here.
async function loadPagesStreaming(pageUrl, onPage, { params = {}, streamId, useCache = true } = {}) {
  if (useCache) {
    const cached = readCachedTransactionRows();
    if (cached) {
      onPage(cached.rows, cached.totalCount);
      return;
    }
  }

  const activeStreamId = streamId || crypto.randomUUID();
  let after = null;
  let allRows = [];
  let totalCount;

  while (true) {
    const url = new URL(pageUrl, window.location.origin);
    if (after) url.searchParams.set("after", after);
    url.searchParams.set("stream_id", activeStreamId);
    for (const [key, value] of Object.entries(params)) url.searchParams.set(key, value);

    const res = await fetch(url);
    if (!res.ok) throw new Error("bad response");
    const data = await res.json();

    allRows.push(...data.rows);
    totalCount = data.total_count;
    onPage(data.rows, data.total_count);

    if (!data.has_more) break;
    after = data.next_after;
  }

  // Written once the drain is fully done, not per-page -- per-page would mean
  // JSON.stringify-ing the whole (ever-growing) row set on every round trip,
  // and would also leave a *partial* drain cached as if it were complete for
  // any load that gets interrupted before `has_more` goes false.
  writeCachedTransactionRows(allRows, totalCount);
}
