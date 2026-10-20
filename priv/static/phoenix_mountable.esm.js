// PhoenixMountable browser helper, as an ES module for bundlers:
//
//     import {Socket, LongPoll} from "phoenix"
//     import {LiveSocket} from "phoenix_live_view"
//     import {connect} from "phoenix_mountable"
//
//     connect({Phoenix: {Socket, LongPoll}, LiveView: {LiveSocket}, hooks})

export function meta(name) {
  const el = document.querySelector(`meta[name='${name}']`);
  return el ? el.getAttribute("content") : null;
}

export function path(relative) {
  const prefix = meta("phoenix-mountable-prefix") || "";
  if (!relative || relative === "/") return prefix || "/";
  return prefix.replace(/\/$/, "") + (relative.startsWith("/") ? relative : `/${relative}`);
}

export function connect(options = {}) {
  const LiveView = options.LiveView || globalThis.LiveView;
  const Phoenix = options.Phoenix || globalThis.Phoenix;

  if (!LiveView || !Phoenix) {
    throw new Error("connect needs the Phoenix and LiveView modules: pass them as options");
  }

  const transport = meta("live-transport") === "longpoll" ? Phoenix.LongPoll : globalThis.WebSocket;
  const liveSocket = new LiveView.LiveSocket(meta("live-path") || "/live", Phoenix.Socket, {
    transport,
    ...(options.socketOptions || {}),
    params: { _csrf_token: meta("csrf-token"), ...(options.params || {}) },
    hooks: options.hooks || {},
  });

  if (options.connect !== false) liveSocket.connect();
  return liveSocket;
}

export default { connect, meta, path };
