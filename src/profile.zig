// SPDX-License-Identifier: MIT
// Copyright (c) 2026 rei78-4e

//! "Usual watts at this time of day", built from past discharge samples,
//! plus a disposable cache of it in $XDG_RUNTIME_DIR.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const config = @import("config.zig");
const clock = @import("clock.zig");
const Sample = @import("history.zig").Sample;

pub const Profile = struct {
    /// Median watts per bin, already widened / falling back to `overall`.
    bins: [config.nbins]?f64,
    overall: ?f64,
    samples: usize,

    pub fn at(p: *const Profile, ts: i64) ?f64 {
        return p.bins[clock.binOf(ts)];
    }
};

pub fn build(gpa: Allocator, samples: []const Sample) !Profile {
    var bins: [config.nbins]std.ArrayList(f64) = @splat(.empty);
    defer for (&bins) |*b| b.deinit(gpa);
    for (samples) |s| try bins[clock.binOf(s.t)].append(gpa, s.w);

    const all = try gpa.alloc(f64, samples.len);
    defer gpa.free(all);
    for (samples, all) |s, *w| w.* = s.w;

    var p: Profile = .{ .bins = undefined, .overall = median(all), .samples = samples.len };
    var pool: std.ArrayList(f64) = .empty;
    defer pool.deinit(gpa);
    for (&p.bins, 0..) |*slot, b| {
        slot.* = p.overall;
        // widen to neighbouring bins until there is enough data
        for (0..config.max_widen + 1) |r| {
            pool.clearRetainingCapacity();
            for (0..2 * r + 1) |k| {
                const idx = (b + config.nbins + k - r) % config.nbins;
                try pool.appendSlice(gpa, bins[idx].items);
            }
            if (pool.items.len >= config.min_bin_samples) {
                slot.* = median(pool.items);
                break;
            }
        }
    }
    return p;
}

/// Sorts `xs` in place.
fn median(xs: []f64) ?f64 {
    if (xs.len == 0) return null;
    std.mem.sort(f64, xs, {}, std.sort.asc(f64));
    const mid = xs.len / 2;
    return if (xs.len % 2 == 1) xs[mid] else (xs[mid - 1] + xs[mid]) / 2;
}

// ---- cache ---------------------------------------------------------------

const cache_name = "denki-yoho-profile";
const magic = "denki-yoho-profile 1";

fn params() [4]u32 {
    return .{ config.lookback_days, config.bin_min, config.min_bin_samples, config.max_widen };
}

/// Returns the cached profile if it was built from `source` with the same
/// parameters within the last `config.profile_ttl` seconds.
pub fn load(io: Io, dir_path: []const u8, source: []const u8, now: i64) ?Profile {
    var dir = Io.Dir.openDirAbsolute(io, dir_path, .{}) catch return null;
    defer dir.close(io);
    var buf: [8192]u8 = undefined;
    const data = dir.readFile(io, cache_name, &buf) catch return null;
    return parseCache(data, source, now);
}

fn parseCache(data: []const u8, source: []const u8, now: i64) ?Profile {
    var lines = std.mem.splitScalar(u8, data, '\n');
    if (!std.mem.eql(u8, lines.next() orelse return null, magic)) return null;

    const src = field(lines.next(), "source ") orelse return null;
    if (!std.mem.eql(u8, src, source)) return null;

    const built = std.fmt.parseInt(i64, field(lines.next(), "built ") orelse return null, 10) catch return null;
    if (built > now or now - built >= config.profile_ttl) return null;

    var ps = std.mem.tokenizeScalar(u8, field(lines.next(), "params ") orelse return null, ' ');
    for (params()) |want| {
        const got = std.fmt.parseInt(u32, ps.next() orelse return null, 10) catch return null;
        if (got != want) return null;
    }

    var p: Profile = undefined;
    p.samples = std.fmt.parseInt(usize, field(lines.next(), "samples ") orelse return null, 10) catch return null;
    p.overall = parseWatts(field(lines.next(), "overall ") orelse return null) catch return null;
    var ws = std.mem.tokenizeScalar(u8, field(lines.next(), "bins ") orelse return null, ' ');
    for (&p.bins) |*slot| slot.* = parseWatts(ws.next() orelse return null) catch return null;
    if (ws.next() != null) return null;
    return p;
}

fn field(line: ?[]const u8, comptime key: []const u8) ?[]const u8 {
    const l = line orelse return null;
    return if (std.mem.startsWith(u8, l, key)) l[key.len..] else null;
}

fn parseWatts(s: []const u8) !?f64 {
    return if (std.mem.eql(u8, s, "-")) null else try std.fmt.parseFloat(f64, s);
}

/// Best effort: a failed write just means the next run rebuilds.
pub fn store(io: Io, dir_path: []const u8, source: []const u8, now: i64, p: *const Profile) void {
    var buf: [8192]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    writeCache(&w, source, now, p) catch return;

    var dir = Io.Dir.openDirAbsolute(io, dir_path, .{}) catch return;
    defer dir.close(io);
    const tmp = cache_name ++ ".tmp";
    dir.writeFile(io, .{ .sub_path = tmp, .data = w.buffered() }) catch return;
    dir.rename(tmp, dir, cache_name, io) catch {};
}

fn writeCache(w: *Io.Writer, source: []const u8, now: i64, p: *const Profile) !void {
    const ps = params();
    try w.print("{s}\nsource {s}\nbuilt {d}\nparams {d} {d} {d} {d}\nsamples {d}\noverall ", .{
        magic, source, now, ps[0], ps[1], ps[2], ps[3], p.samples,
    });
    try writeWatts(w, p.overall);
    try w.writeAll("\nbins");
    for (p.bins) |b| {
        try w.writeByte(' ');
        try writeWatts(w, b);
    }
    try w.writeByte('\n');
}

fn writeWatts(w: *Io.Writer, v: ?f64) !void {
    if (v) |x| try w.print("{d:.3}", .{x}) else try w.writeByte('-');
}

test "cache round trip" {
    var p: Profile = .{ .bins = @splat(null), .overall = 9.5, .samples = 42 };
    p.bins[3] = 11.25;
    var buf: [8192]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeCache(&w, "/x.dat", 1000, &p);

    const got = parseCache(w.buffered(), "/x.dat", 1010).?;
    try std.testing.expectEqual(@as(usize, 42), got.samples);
    try std.testing.expectEqual(@as(?f64, 11.25), got.bins[3]);
    try std.testing.expectEqual(@as(?f64, null), got.bins[0]);

    try std.testing.expect(parseCache(w.buffered(), "/y.dat", 1010) == null);
    try std.testing.expect(parseCache(w.buffered(), "/x.dat", 1000 + config.profile_ttl) == null);
}

test "median" {
    var odd = [_]f64{ 3, 1, 2 };
    try std.testing.expectEqual(@as(?f64, 2), median(&odd));
    var even = [_]f64{ 4, 1, 3, 2 };
    try std.testing.expectEqual(@as(?f64, 2.5), median(&even));
}
