//! The single bridge from `core/` to the platform composition root.
const platform = @import("../platform.zig");

pub const Window = platform.window.Window;
pub const WindowConfig = platform.window.WindowConfig;
pub const Delegate = platform.window.Delegate;

/// The renderer the frame path drives, resolved by the composition root.
pub const Renderer = platform.render_impl.Renderer;

/// The resolved text backend (pangocairo on Linux production, the deterministic portable estimator everywhere else and in every test build).
pub const TextBackend = platform.text_impl;

/// The system clipboard's text: the pasteboard on macOS, a no-op stub on a host with no backend and in every test build.
pub const Clipboard = platform.clipboard;

/// The persistence backend: the bytes an app keeps across a reload, in whatever store this host has.
pub const Storage = platform.storage;

/// The monotonic millisecond clock: a real one on every native backend, none in a test build (which keeps a frame's delta deterministic).
pub const Clock = platform.clock;

/// The devtool service transport: a unix socket on Linux, "unavailable" everywhere else until that host's wake hook lands.
pub const DevtoolsService = platform.devtools_service;

/// Whether this process was started to be inspected (`GLIN_DEVTOOLS=1`).
pub const devtoolsRequested = platform.devtoolsRequested;
