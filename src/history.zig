// SPDX-License-Identifier: MIT
// Copyright (c) 2026 rei78-4e

//! upower's rate history: /var/lib/upower/history-rate-<model>-<Wh>-<serial>.dat
//! One sample per line: "<unix time>\t<watts>\t<state>".

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const config = @import("config.zig");

pub const Sample = struct {
    t: i64,
    w: f64,
};

pub fn findRateFile(io: Io, arena: Allocator, model: []const u8, serial: []const u8) ?[]const u8 {
    if (model.len == 0 or serial.len == 0) return null;
    const prefix = std.fmt.allocPrint(arena, "history-rate-{s}-", .{model}) catch return null;
    const suffix = std.fmt.allocPrint(arena, "-{s}.dat", .{serial}) catch return null;

    var dir = Io.Dir.openDirAbsolute(io, config.history_dir, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (std.mem.startsWith(u8, entry.name, prefix) and std.mem.endsWith(u8, entry.name, suffix))
            return std.fmt.allocPrint(arena, "{s}/{s}", .{ config.history_dir, entry.name }) catch null;
    }
    return null;
}

/// Discharge samples at or after `since`, in file order.
pub fn parseDischarge(gpa: Allocator, data: []const u8, since: i64) ![]Sample {
    var out: std.ArrayList(Sample) = .empty;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const ts = fields.next() orelse continue;
        const ws = fields.next() orelse continue;
        const state = fields.next() orelse continue;
        if (!std.mem.eql(u8, state, "discharging")) continue;
        const t = std.fmt.parseInt(i64, ts, 10) catch continue;
        const w = std.fmt.parseFloat(f64, ws) catch continue;
        if (t >= since and w > 0) try out.append(gpa, .{ .t = t, .w = w });
    }
    return out.toOwnedSlice(gpa);
}

pub fn readAll(io: Io, gpa: Allocator, path: []const u8) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 20));
}

/// The last `config.tail_bytes` of the log, starting at a line boundary.
pub fn readTail(io: Io, gpa: Allocator, path: []const u8) ![]u8 {
    var file = try Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    const len = try file.length(io);
    const offset = len -| config.tail_bytes;
    const buf = try gpa.alloc(u8, @intCast(len - offset));
    const n = try file.readPositionalAll(io, buf, offset);
    var data = buf[0..n];
    if (offset > 0) {
        const nl = std.mem.indexOfScalar(u8, data, '\n') orelse return data[0..0];
        data = data[nl + 1 ..];
    }
    return data;
}

test parseDischarge {
    const data = "100\t5.0\tcharging\n" ++
        "200\t10.5\tdischarging\n" ++
        "300\t0.000\tdischarging\n" ++
        "400\t12.0\tdischarging\n" ++
        "garbage";
    const got = try parseDischarge(std.testing.allocator, data, 150);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqual(@as(i64, 200), got[0].t);
    try std.testing.expectEqual(@as(f64, 12.0), got[1].w);
}
