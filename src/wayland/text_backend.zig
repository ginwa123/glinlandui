//! CPU-only text facade for platforms that do not ship the Pango/Cairo stack.
//!
//! The native Linux path continues to use wayland/text.zig, which is backed by
//! the pangocairo shim. This fallback intentionally exposes the same measurement
//! contract using the historical deterministic estimator, so layouts and the
//! headless test harness behave identically without native dependencies.
const std = @import("std");
const builtin = @import("builtin");
const native = @import("text.zig");
const portable = @import("text_portable.zig");

pub const TextExtent = if (builtin.os.tag == .linux) native.TextExtent else portable.TextExtent;
pub const ResolveFontError = if (builtin.os.tag == .linux) native.ResolveFontError else portable.ResolveFontError;
pub const resolveFont = if (builtin.os.tag == .linux) native.resolveFont else portable.resolveFont;
pub const estimatorExtent = if (builtin.os.tag == .linux) native.estimatorExtent else portable.estimatorExtent;
pub const hashMeasureKey = if (builtin.os.tag == .linux) native.hashMeasureKey else portable.hashMeasureKey;
pub const extentCacheReset = if (builtin.os.tag == .linux) native.extentCacheReset else portable.extentCacheReset;
pub const pangoFamily = if (builtin.os.tag == .linux) native.pangoFamily else portable.pangoFamily;
pub const measureText = if (builtin.os.tag == .linux) native.measureText else portable.measureText;
pub const extent_hits = if (builtin.os.tag == .linux) native.extent_hits else portable.extent_hits;
pub const extent_misses = if (builtin.os.tag == .linux) native.extent_misses else portable.extent_misses;
