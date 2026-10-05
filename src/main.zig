// SPDX-License-Identifier: MIT
// Copyright (c) 2026 rei78-4e

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");
const config = @import("config.zig");
const clock = @import("clock.zig");
const sysfs = @import("sysfs.zig");
const history = @import("history.zig");
const profile = @import("profile.zig");
const forecast = @import("forecast.zig");

const usage =
    \\denki-yoho — battery remaining-time forecast from upower history
    \\
    \\Usage:
    \\  denki-yoho [command] [options]
    \\
    \\Commands:
    \\  waybar     One line of Waybar custom-module JSON (default)
    \\  status     Human-readable estimate
    \\  profile    Usual draw per time of day
    \\
    \\Options:
    \\  -b, --battery NAME   power_supply device (default: BAT0)
    \\      --no-cache       Rebuild the profile instead of using the cache
    \\  -h, --help           Show this help
    \\  -V, --version        Show the version
    \\
;

const Command = enum { waybar, status, profile };

const Options = struct {
    command: Command = .waybar,
    battery: []const u8 = config.default_battery,
    use_cache: bool = true,
};

const icons = [_][]const u8{
    "\u{f007a}", "\u{f007b}", "\u{f007c}", "\u{f007d}", "\u{f007e}",
    "\u{f007f}", "\u{f0080}", "\u{f0081}", "\u{f0082}", "\u{f0079}",
};
const icon_charging = "\u{f0084}";
const icon_plugged = "\u{f1e6}";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var buf: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), io, &buf);
    const out = &stdout.interface;

    const opts = parseArgs(init.minimal.args) catch |err| {
        var ebuf: [256]u8 = undefined;
        var stderr: Io.File.Writer = .init(.stderr(), io, &ebuf);
        stderr.interface.print("denki-yoho: {s}\n\n{s}", .{ @errorName(err), usage }) catch {};
        stderr.interface.flush() catch {};
        std.process.exit(2);
    } orelse {
        try out.writeAll(if (helpRequested(init.minimal.args)) usage else build_options.version ++ "\n");
        return out.flush();
    };

    const ctx: Ctx = .{
        .io = io,
        .arena = arena,
        .now = clock.now(io),
        .runtime_dir = init.environ_map.get("XDG_RUNTIME_DIR"),
        .opts = opts,
    };
    const est = try ctx.estimate();
    switch (opts.command) {
        .waybar => try writeWaybar(out, arena, &est),
        .status => try writeStatus(out, arena, &est),
        .profile => try writeProfile(out, &est, ctx.now),
    }
    try out.flush();
}

/// Returns null when --help or --version was given.
fn parseArgs(args: std.process.Args) !?Options {
    var opts: Options = .{};
    var it = args.iterate();
    _ = it.next();
    while (it.next()) |a| {
        if (eql(a, "-h") or eql(a, "--help") or eql(a, "-V") or eql(a, "--version")) {
            return null;
        } else if (eql(a, "-b") or eql(a, "--battery")) {
            opts.battery = it.next() orelse return error.MissingBatteryName;
        } else if (eql(a, "--no-cache")) {
            opts.use_cache = false;
        } else if (std.meta.stringToEnum(Command, a)) |c| {
            opts.command = c;
        } else {
            return error.UnknownArgument;
        }
    }
    return opts;
}

fn helpRequested(args: std.process.Args) bool {
    var it = args.iterate();
    while (it.next()) |a| if (eql(a, "-h") or eql(a, "--help")) return true;
    return false;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const Estimate = struct {
    now: i64,
    bat: sysfs.Battery,
    rate: ?f64 = null,
    usual: ?f64 = null,
    empty_in: ?f64 = null,
    full_in: ?f64 = null,
    naive: ?f64 = null,
    profile: ?profile.Profile = null,
    cached: bool = false,
};

const Ctx = struct {
    io: Io,
    arena: Allocator,
    now: i64,
    runtime_dir: ?[]const u8,
    opts: Options,

    fn estimate(ctx: Ctx) !Estimate {
        const bat = try sysfs.read(ctx.io, ctx.arena, ctx.opts.battery);
        var est: Estimate = .{ .now = ctx.now, .bat = bat };

        if (bat.status == .charging) {
            if (bat.energy_now != null and bat.energy_full != null and bat.power != null)
                est.full_in = (bat.energy_full.? - bat.energy_now.?) / bat.power.? * 3600;
            if (ctx.opts.command != .profile) return est;
        } else if (bat.status != .discharging and ctx.opts.command != .profile) {
            return est;
        }

        const path = history.findRateFile(ctx.io, ctx.arena, bat.model, bat.serial);
        if (path) |p| ctx.loadProfile(p, &est) catch {};
        if (bat.status != .discharging) return est;

        const recent = if (path) |p| blk: {
            const tail = history.readTail(ctx.io, ctx.arena, p) catch break :blk &.{};
            break :blk history.parseDischarge(ctx.arena, tail, ctx.now - config.now_window) catch &.{};
        } else &.{};

        est.rate = forecast.currentRate(recent, ctx.now, bat.power);
        if (est.profile) |*p| est.usual = p.at(ctx.now);
        if (bat.energy_now) |e| {
            if (est.rate) |r| est.empty_in = forecast.timeToEmpty(e, ctx.now, r, if (est.profile) |*p| p else null);
            if (bat.power) |w| est.naive = e / w * 3600;
        }
        return est;
    }

    fn loadProfile(ctx: Ctx, path: []const u8, est: *Estimate) !void {
        if (ctx.opts.use_cache) if (ctx.runtime_dir) |dir| {
            if (profile.load(ctx.io, dir, path, ctx.now)) |p| {
                est.profile = p;
                est.cached = true;
                return;
            }
        };
        const data = try history.readAll(ctx.io, ctx.arena, path);
        const samples = try history.parseDischarge(ctx.arena, data, ctx.now - config.lookback_days * 86400);
        est.profile = try profile.build(ctx.arena, samples);
        if (ctx.runtime_dir) |dir| profile.store(ctx.io, dir, path, ctx.now, &est.profile.?);
    }
};

fn fmtDur(arena: Allocator, secs: f64) ![]const u8 {
    const m: u64 = @intFromFloat(@round(@max(secs, 0) / 60));
    return std.fmt.allocPrint(arena, "{d} h {d:0>2} min", .{ m / 60, m % 60 });
}

fn fmtClock(arena: Allocator, ts: i64) ![]const u8 {
    const l = clock.local(ts);
    return std.fmt.allocPrint(arena, "{d:0>2}:{d:0>2}", .{ l.hour, l.minute });
}

/// The tooltip / status body.
fn describe(arena: Allocator, est: *const Estimate) ![]const u8 {
    var lines: std.ArrayList(u8) = .empty;
    switch (est.bat.status) {
        .discharging => {
            if (est.empty_in) |s| {
                const eta = try fmtClock(arena, est.now + @as(i64, @intFromFloat(s)));
                try lines.print(arena, "Empty in {s} (≈ {s})\n", .{ try fmtDur(arena, s), eta });
            }
            if (est.rate) |r| {
                try lines.print(arena, "now {d:.1} W", .{r});
                if (est.usual) |u| try lines.print(arena, " · usual {d:.1} W", .{u});
                try lines.append(arena, '\n');
            }
            if (est.naive) |s| try lines.print(arena, "naive {s}\n", .{try fmtDur(arena, s)});
            if (est.profile) |p| try lines.print(arena, "{d} samples / {d} d\n", .{ p.samples, config.lookback_days });
        },
        .charging => if (est.full_in) |s| try lines.print(arena, "Full in {s}\n", .{try fmtDur(arena, s)}),
        .full => try lines.appendSlice(arena, "Full\n"),
        .not_charging => try lines.appendSlice(arena, "Not charging\n"),
        .unknown => try lines.appendSlice(arena, "Unknown\n"),
    }
    if (lines.items.len > 0) lines.items.len -= 1;
    return lines.items;
}

fn writeWaybar(out: *Io.Writer, arena: Allocator, est: *const Estimate) !void {
    const cap = est.bat.capacity;
    var classes: std.ArrayList([]const u8) = .empty;
    if (cap <= config.critical)
        try classes.append(arena, "critical")
    else if (cap <= config.warning)
        try classes.append(arena, "warning");

    const text = switch (est.bat.status) {
        .discharging => try std.fmt.allocPrint(arena, "{s}{d}%", .{ icons[@min(@as(usize, cap) * icons.len / 100, icons.len - 1)], cap }),
        .charging => blk: {
            try classes.append(arena, "charging");
            break :blk try std.fmt.allocPrint(arena, icon_charging ++ " {d}%", .{cap});
        },
        else => blk: {
            try classes.append(arena, "plugged");
            break :blk try std.fmt.allocPrint(arena, icon_plugged ++ " {d}%", .{cap});
        },
    };

    try std.json.Stringify.value(.{
        .text = text,
        .tooltip = try describe(arena, est),
        .class = classes.items,
        .percentage = cap,
    }, .{}, out);
    try out.writeByte('\n');
}

fn writeStatus(out: *Io.Writer, arena: Allocator, est: *const Estimate) !void {
    try out.print("{s} {d}%\n{s}\n", .{ @tagName(est.bat.status), est.bat.capacity, try describe(arena, est) });
    if (est.profile != null) try out.print("profile: {s}\n", .{if (est.cached) "cached" else "rebuilt"});
}

fn writeProfile(out: *Io.Writer, est: *const Estimate, now: i64) !void {
    const p = est.profile orelse {
        try out.writeAll("no upower history found\n");
        return;
    };
    var max: f64 = 0;
    for (p.bins) |b| max = @max(max, b orelse 0);
    const here = clock.binOf(now);
    const width = 40;

    for (p.bins, 0..) |b, i| {
        const mins = i * config.bin_min;
        try out.print("{s} {d:0>2}:{d:0>2} ", .{ if (i == here) ">" else " ", mins / 60, mins % 60 });
        const w = b orelse {
            try out.writeAll("     -\n");
            continue;
        };
        try out.print("{d:>6.1} W ", .{w});
        const n: usize = if (max > 0) @intFromFloat(@round(w / max * width)) else 0;
        for (0..n) |_| try out.writeAll("█");
        try out.writeByte('\n');
    }
    try out.print("\n{d} samples / {d} d, overall ", .{ p.samples, config.lookback_days });
    if (p.overall) |o| try out.print("{d:.1} W", .{o}) else try out.writeAll("-");
    try out.print(" ({s})\n", .{if (est.cached) "cached" else "rebuilt"});
}
