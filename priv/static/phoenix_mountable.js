// PhoenixMountable browser helper.
// Connects a mountable library's LiveSocket from the meta tags rendered by
// PhoenixMountable.HTML.meta_tags/1 (or <PhoenixMountable.Layout.meta />).
// Exposes window.PhoenixMountable. Use phoenix_mountable.esm.js with a bundler.
(function (global) {
  "use strict";

  function meta(name) {
    var el = document.querySelector("meta[name='" + name + "']");
    return el ? el.getAttribute("content") : null;
  }

  function path(relative) {
    var prefix = meta("phoenix-mountable-prefix") || "";
    if (!relative || relative === "/") return prefix || "/";
    return prefix.replace(/\/$/, "") + (relative.charAt(0) === "/" ? relative : "/" + relative);
  }

  function connect(options) {
    options = options || {};
    var LiveView = options.LiveView || global.LiveView;
    var Phoenix = options.Phoenix || global.Phoenix;

    if (!LiveView || !Phoenix) {
      throw new Error("PhoenixMountable.connect needs Phoenix and LiveView: load phoenix.js and phoenix_live_view.js first, or pass them as options");
    }

    var transport = meta("live-transport") === "longpoll" ? Phoenix.LongPoll : global.WebSocket;
    var params = Object.assign({ _csrf_token: meta("csrf-token") }, options.params || {});
    var socketOptions = Object.assign({ transport: transport }, options.socketOptions || {}, {
      params: params,
      hooks: options.hooks || {}
    });

    var liveSocket = new LiveView.LiveSocket(meta("live-path") || "/live", Phoenix.Socket, socketOptions);
    if (options.connect !== false) liveSocket.connect();
    return liveSocket;
  }

  global.PhoenixMountable = { connect: connect, meta: meta, path: path };
})(typeof window !== "undefined" ? window : this);
