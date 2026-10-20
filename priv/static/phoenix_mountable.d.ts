// Types of the PhoenixMountable browser helper.

export interface ConnectOptions {
  /** The `phoenix` module: `{Socket, LongPoll}`. Defaults to `globalThis.Phoenix`. */
  Phoenix?: { Socket: unknown; LongPoll?: unknown };
  /** The `phoenix_live_view` module: `{LiveSocket}`. Defaults to `globalThis.LiveView`. */
  LiveView?: { LiveSocket: new (path: string, socket: unknown, opts: object) => any };
  /** The LiveView hooks of the library. */
  hooks?: Record<string, object>;
  /** Connect params, sent with the CSRF token of the page. */
  params?: Record<string, unknown>;
  /** Other options of the `LiveSocket`. */
  socketOptions?: Record<string, unknown>;
  /** `false` returns the `LiveSocket` without connecting it. */
  connect?: boolean;
}

/** The content of the page's `<meta name={name}>`, or null. */
export function meta(name: string): string | null;

/** A path under the mount: `path("/items")` is `"/admin/my_lib/items"`. */
export function path(relative?: string): string;

/** Creates the `LiveSocket` from the mount's meta tags, and connects it. */
export function connect(options?: ConnectOptions): any;

declare const PhoenixMountable: {
  connect: typeof connect;
  meta: typeof meta;
  path: typeof path;
};

export default PhoenixMountable;
