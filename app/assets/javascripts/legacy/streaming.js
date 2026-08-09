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
  const deadline = Date.now() + SYNC_POLL_TIMEOUT_MS;
  while (Date.now() < deadline) {
    await sleep(SYNC_POLL_INTERVAL_MS);
    try {
      const res = await fetch(`${orgApiBase()}/api/transactions/sync_status`);
      if (!res.ok) continue;
      const current = await res.json();
      if (current.fetched_at && current.fetched_at !== started.fetched_at) return true;
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
async function loadPagesStreaming(pageUrl, onPage) {
  const cached = readCachedTransactionRows();
  if (cached) {
    onPage(cached.rows, cached.totalCount);
    return;
  }

  const streamId = crypto.randomUUID();
  let after = null;
  let allRows = [];
  let totalCount;

  while (true) {
    const url = new URL(pageUrl, window.location.origin);
    if (after) url.searchParams.set("after", after);
    url.searchParams.set("stream_id", streamId);

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
