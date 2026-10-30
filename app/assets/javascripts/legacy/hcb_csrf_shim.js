(function () {
  var meta = document.querySelector('meta[name="csrf-token"]');
  if (!meta) return;

  // The token authenticates a request as coming from this app's own pages, so it
  // belongs on requests going back to this app and nowhere else. Every fetch()
  // in the legacy bundle is same-origin (API_BASE is a path), but this wraps
  // window.fetch globally -- including calls this file knows nothing about --
  // and a token attached to a cross-origin request is handed to whoever answers
  // it.
  // fetch() accepts a string, a URL object or a Request; the token must be
  // attached whichever form the caller used, or a same-origin POST made with a
  // URL object fails CSRF verification (which is what happened to the
  // automatic "check for new" on every page load).
  function sameOrigin(input) {
    var url = typeof input === "string" ? input : (input && (input.href || input.url));
    if (!url) return false;
    try {
      return new URL(url, window.location.href).origin === window.location.origin;
    } catch (e) {
      return false;
    }
  }

  var original = window.fetch;
  window.fetch = function (input, init) {
    init = init || {};
    var method = (init.method || "GET").toUpperCase();
    if (method !== "GET" && method !== "HEAD" && sameOrigin(input)) {
      init.headers = Object.assign({}, init.headers, { "X-CSRF-Token": meta.content });
    }
    return original.call(this, input, init);
  };
})();
