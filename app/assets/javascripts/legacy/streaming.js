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
