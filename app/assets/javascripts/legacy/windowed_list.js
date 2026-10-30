// Lists that render what has been scrolled to, not everything they hold.
//
// Every list on the matcher and the ledger used to be one innerHTML write of
// every row it had. For a large organization that is the whole page's memory:
// fifty thousand transactions is over a million DOM nodes and hundreds of
// megabytes in the tab, rebuilt from scratch on every click, keystroke and
// page of a load -- a tab following a cold load of that size went past a
// gigabyte. Nobody reads fifty thousand rows; they search, sort and scroll a
// little way down. So a list renders its first chunk and a sentinel, and an
// IntersectionObserver appends the next chunk whenever the sentinel comes near
// the viewport. The data stays whole in memory; only the DOM is windowed.
//
// Loaded before the page scripts, which call renderWindowed() where they used
// to assign innerHTML. Event handling on the lists is delegated to the
// container (see delegateRowControls in details.js), so rows appended later
// work the same as rows rendered first.

// Rows per chunk. Enough to fill a tall panel several times over, few enough
// that a render is a few milliseconds whatever the organization's size.
const WINDOWED_CHUNK = 200;

// How far ahead of the viewport the next chunk is fetched, so scrolling at a
// normal pace never reaches the end of what is rendered.
const WINDOWED_LOOKAHEAD = "600px";

const windowedState = new WeakMap();

// Renders `items` into `container` through `rowHtml`, windowed.
//
// options.root      the scrolling ancestor, when it isn't `container` itself
//                   (a table body scrolls inside its wrapper).
// options.sentinel  "div" (default) or "tr" -- what the end-of-window marker
//                   has to be to sit legally inside the container.
// options.span      colspan for a "tr" sentinel.
// options.label     what the rows are called in the "N more" note.
// options.onAppend  called with the container after each chunk lands, for the
//                   rare per-row wiring delegation can't cover.
//
// Re-rendering a container with the same number of items keeps as many rows
// rendered as before, so a redraw after a click (the common case: a selection
// changed, nothing moved) doesn't throw away the rows somebody scrolled down
// to and bounce them back to the top. A different item count is a different
// list -- a search, a filter -- and starts from the first chunk again.
function renderWindowed(container, items, rowHtml, options = {}) {
  const previous = windowedState.get(container);
  if (previous && previous.observer) previous.observer.disconnect();

  const chunk = options.chunk || WINDOWED_CHUNK;
  const keep = previous && previous.items.length === items.length ? previous.rendered : 0;
  const state = {
    items, rowHtml, options, chunk,
    rendered: 0, observer: null, sentinel: null,
  };
  windowedState.set(container, state);

  container.innerHTML = "";
  if (items.length === 0) return state;

  appendWindowedChunk(container, state, Math.max(chunk, Math.min(keep, items.length)));
  return state;
}

function windowedSentinelHtml(state, remaining) {
  const label = state.options.label || "rows";
  const note = `${remaining.toLocaleString()} more ${label} — scroll for more`;
  if (state.options.sentinel === "tr") {
    return `<tr class="windowed-sentinel"><td colspan="${state.options.span || 1}">${note}</td></tr>`;
  }
  return `<div class="windowed-sentinel">${note}</div>`;
}

function appendWindowedChunk(container, state, count) {
  const from = state.rendered;
  const to = Math.min(state.items.length, from + count);
  if (to <= from) return;

  let html = "";
  for (let i = from; i < to; i++) html += state.rowHtml(state.items[i], i);

  if (state.sentinel) {
    state.sentinel.insertAdjacentHTML("beforebegin", html);
  } else {
    container.insertAdjacentHTML("beforeend", html);
  }
  state.rendered = to;

  if (state.options.onAppend) state.options.onAppend(container, from, to);

  const remaining = state.items.length - state.rendered;
  if (state.observer) {
    state.observer.disconnect();
    state.observer = null;
  }
  if (state.sentinel) {
    state.sentinel.remove();
    state.sentinel = null;
  }
  if (remaining <= 0) return;

  container.insertAdjacentHTML("beforeend", windowedSentinelHtml(state, remaining));
  state.sentinel = container.lastElementChild;

  // A browser without IntersectionObserver (none this app supports) would
  // simply show the first chunk and the note; nothing breaks.
  if (typeof IntersectionObserver === "undefined") return;
  state.observer = new IntersectionObserver((entries) => {
    if (!entries.some((e) => e.isIntersecting)) return;
    appendWindowedChunk(container, state, state.chunk);
  }, { root: state.options.root || container, rootMargin: WINDOWED_LOOKAHEAD });
  state.observer.observe(state.sentinel);
}

// Renders chunks until the item `predicate` picks out is in the DOM, for a
// caller about to scroll to it. Returns false if no item matches.
function revealWindowedItem(container, predicate) {
  const state = windowedState.get(container);
  if (!state) return false;

  const index = state.items.findIndex(predicate);
  if (index === -1) return false;
  if (index >= state.rendered) appendWindowedChunk(container, state, index + 1 - state.rendered + state.chunk);
  return true;
}
