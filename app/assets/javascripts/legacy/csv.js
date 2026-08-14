// CSV export, built in the browser from the rows the page has already loaded
// rather than from an endpoint of its own. The page is holding exactly the
// working set a server-side export would have to re-derive (post-cutoff, split
// matched/unmatched), so building the file here costs no HCB requests and can't
// disagree with the figures on screen. Loaded on every legacy page; the
// per-page exports (which groups, in what order) live with that page's script.

// Spreadsheets read a leading =, +, -, @ (or a tab/CR) as the start of a
// formula, so a memo of "=HYPERLINK(...)" -- and memos here include text typed
// by donors and merchants -- would be evaluated by Excel rather than shown.
// An apostrophe in front forces it back to text. Anything that parses as a
// number is left alone, or every outgoing amount (all negative) would be
// prefixed and land in the sheet as text instead of a number.
function csvSafeText(value) {
  const s = String(value);
  if (!/^[=+\-@\t\r]/.test(s)) return s;
  return Number.isNaN(Number(s)) ? "'" + s : s;
}

function csvCell(value) {
  if (value === null || value === undefined) return "";
  const s = csvSafeText(value);
  // Quoted only when the value would otherwise change the shape of the row.
  return /[",\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

// CRLF between records, per RFC 4180 -- the one line ending every spreadsheet
// on every platform reads without being told.
function buildCsv(headers, rows) {
  return [headers, ...rows].map((cells) => cells.map(csvCell).join(",")).join("\r\n") + "\r\n";
}

// Local date, not toISOString's UTC one, so a file downloaded late in the
// evening isn't stamped with tomorrow's date.
function csvDateStamp() {
  const d = new Date();
  const pad = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

// e.g. "steelyard-org_1a2b-unmatched-incoming-2026-08-14". The organization and
// the date are both in the name because reconciling more than one organization
// (or the same one twice in a week) otherwise leaves a downloads folder full of
// files nobody can tell apart.
function csvBasename(label) {
  const slug = String(window.HCB_ORGANIZATION_ID || "org").replace(/[^a-zA-Z0-9._-]/g, "-");
  return `steelyard-${slug}-${label}-${csvDateStamp()}`;
}

function downloadCsv(basename, headers, rows) {
  // The UTF-8 BOM is for Excel on Windows, which otherwise decodes the file as
  // the machine's local codepage and mangles any non-ASCII memo (an emoji, an
  // accented name). Sheets and Numbers ignore it.
  const blob = new Blob(["\ufeff" + buildCsv(headers, rows)], { type: "text/csv;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = `${basename}.csv`;
  document.body.appendChild(link);
  link.click();
  link.remove();
  // Revoked a tick later rather than immediately: Safari reads the blob after
  // the click handler has already returned.
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

// Header -> value for one transaction, in column order. Shared by the exports
// of plain transaction lists and by the per-leg rows of a match export, so a
// column added here appears in every file rather than in one of them.
//
// hcbCode/hcbTransactionUrl are the host page's (both the matcher and the
// ledger define them); the raw id is exported alongside them because a
// manually-added transaction has no HCB code at all.
const TRANSACTION_CSV_COLUMNS = [
  ["Date", (t) => t.date],
  ["Memo", (t) => t.memo],
  ["Amount", (t) => t.amount],
  ["Direction", (t) => (t.direction === "in" ? "incoming" : t.direction === "out" ? "outgoing" : "")],
  ["HCB code", (t) => hcbCode(t)],
  ["HCB URL", (t) => hcbTransactionUrl(t)],
  ["User", (t) => t.user_name],
  ["Recipient", (t) => t.recipient_name],
  ["Category", (t) => t.category_label],
  ["Tags", (t) => t.tags],
  ["Reason", (t) => t.reason],
  ["Status", (t) => transactionStatusText(t)],
  // Always exported, even when it equals the sent date the modal hides it
  // behind: a column that's only sometimes filled in is worse to sort a
  // spreadsheet by than one that's always there.
  ["Settled date", (t) => t.settled_date],
  ["Transaction ID", (t) => t.id],
];

const TRANSACTION_CSV_HEADERS = TRANSACTION_CSV_COLUMNS.map(([header]) => header);

// Tolerates a partial transaction (`{ id }` and little else) so a match leg the
// page never loaded can still be exported as a row -- every column it has no
// answer for comes out empty rather than as "undefined".
function transactionCsvCells(t) {
  return TRANSACTION_CSV_COLUMNS.map(([, read]) => read(t) ?? "");
}
