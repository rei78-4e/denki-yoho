// SPDX-License-Identifier: MIT
// Copyright (c) 2026 rei78-4e

//! Local wall-clock time. Zig's std has no time zone support, so this goes
//! through libc's localtime_r.

const std = @import("std");
const config = @import("config.zig");

const Tm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: ?[*:0]const u8,
};

extern "c" fn localtime_r(timer: *const c_long, result: *Tm) ?*Tm;

pub const Local = struct {
    hour: u8,
    minute: u8,
};

pub fn local(ts: i64) Local {
    var tm: Tm = undefined;
    const t: c_long = @intCast(ts);
    if (localtime_r(&t, &tm) == null) {
        // fall back to UTC rather than failing the whole run
        const day_min: u32 = @intCast(@mod(@divFloor(ts, 60), 24 * 60));
        return .{ .hour = @intCast(day_min / 60), .minute = @intCast(day_min % 60) };
    }
    return .{ .hour = @intCast(tm.tm_hour), .minute = @intCast(tm.tm_min) };
}

/// Index of the time-of-day bin that `ts` falls into.
pub fn binOf(ts: i64) usize {
    const l = local(ts);
    return (@as(usize, l.hour) * 60 + l.minute) / config.bin_min;
}

pub fn now(io: std.Io) i64 {
    const ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    return @intCast(@divFloor(ns, std.time.ns_per_s));
}
