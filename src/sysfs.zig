// SPDX-License-Identifier: MIT
// Copyright (c) 2026 rei78-4e

//! Battery state from /sys/class/power_supply/<name>.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const config = @import("config.zig");

pub const Status = enum { charging, discharging, full, not_charging, unknown };

pub const Battery = struct {
    status: Status,
    capacity: u8,
    /// Wh
    energy_now: ?f64,
    energy_full: ?f64,
    /// W, always positive
    power: ?f64,
    model: []const u8,
    serial: []const u8,
};

pub fn read(io: Io, arena: Allocator, name: []const u8) !Battery {
    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ config.sysfs_dir, name });
    var dir = try Io.Dir.openDirAbsolute(io, path, .{});
    defer dir.close(io);
    const r: Attrs = .{ .io = io, .dir = dir, .arena = arena };

    return .{
        .status = parseStatus(r.str("status") orelse ""),
        .capacity = @intCast(std.math.clamp(r.int("capacity") orelse 0, 0, 100)),
        .energy_now = r.energy("now"),
        .energy_full = r.energy("full"),
        .power = r.power(),
        .model = r.str("model_name") orelse "",
        .serial = r.str("serial_number") orelse "",
    };
}

fn parseStatus(s: []const u8) Status {
    const map = std.StaticStringMap(Status).initComptime(.{
        .{ "Charging", .charging },
        .{ "Discharging", .discharging },
        .{ "Full", .full },
        .{ "Not charging", .not_charging },
    });
    return map.get(s) orelse .unknown;
}

const Attrs = struct {
    io: Io,
    dir: Io.Dir,
    arena: Allocator,

    fn str(r: Attrs, name: []const u8) ?[]const u8 {
        var buf: [256]u8 = undefined;
        const raw = r.dir.readFile(r.io, name, &buf) catch return null;
        return r.arena.dupe(u8, std.mem.trim(u8, raw, " \t\r\n")) catch null;
    }

    fn int(r: Attrs, name: []const u8) ?i64 {
        return std.fmt.parseInt(i64, r.str(name) orelse return null, 10) catch null;
    }

    /// energy_<which> (µWh), or charge_<which> (µAh) × voltage_now (µV).
    fn energy(r: Attrs, comptime which: []const u8) ?f64 {
        if (r.int("energy_" ++ which)) |e| return @as(f64, @floatFromInt(e)) / 1e6;
        const c = r.int("charge_" ++ which) orelse return null;
        const v = r.int("voltage_now") orelse return null;
        return @as(f64, @floatFromInt(c)) * @as(f64, @floatFromInt(v)) / 1e12;
    }

    /// power_now (µW), or current_now (µA) × voltage_now (µV). Some drivers
    /// report a negative current while discharging.
    fn power(r: Attrs) ?f64 {
        const w = if (r.int("power_now")) |p|
            @as(f64, @floatFromInt(p)) / 1e6
        else blk: {
            const i = r.int("current_now") orelse return null;
            const v = r.int("voltage_now") orelse return null;
            break :blk @as(f64, @floatFromInt(i)) * @as(f64, @floatFromInt(v)) / 1e12;
        };
        return if (w == 0) null else @abs(w);
    }
};
