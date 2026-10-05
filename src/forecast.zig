// SPDX-License-Identifier: MIT
// Copyright (c) 2026 rei78-4e

const std = @import("std");
const config = @import("config.zig");
const Sample = @import("history.zig").Sample;
const Profile = @import("profile.zig").Profile;

/// EWMA of the recent discharge samples plus the live reading, weighting
/// newer values more.
pub fn currentRate(samples: []const Sample, now: i64, live: ?f64) ?f64 {
    var num: f64 = 0;
    var den: f64 = 0;
    for (samples) |s| {
        if (s.t < now - config.now_window or s.t > now) continue;
        const k = @exp(-@as(f64, @floatFromInt(now - s.t)) / config.now_tau);
        num += k * s.w;
        den += k;
    }
    if (live) |w| {
        num += w;
        den += 1;
    }
    return if (den > 0) num / den else null;
}

/// Seconds until `energy` (Wh) runs out, drawing `rate` (W) now and drifting
/// towards the profile's usual draw for each upcoming time of day.
pub fn timeToEmpty(energy: f64, now: i64, rate: f64, profile: ?*const Profile) f64 {
    var t: i64 = 0;
    var e = energy;
    var w = rate;
    while (e > 0 and t < config.horizon) : (t += config.step) {
        const usual = if (profile) |p| p.at(now + t) else null;
        w = if (usual) |u| blk: {
            const k = @exp(-@as(f64, @floatFromInt(t)) / config.blend_tau);
            break :blk k * rate + (1 - k) * u;
        } else rate;
        e -= w * config.step / 3600;
    }
    const secs: f64 = @floatFromInt(t);
    // back off the overshoot of the last step
    return if (e < 0 and w > 0) secs + e / w * 3600 else secs;
}

test currentRate {
    const s = [_]Sample{
        .{ .t = 0, .w = 100 }, // outside the window
        .{ .t = 1000, .w = 10 },
    };
    try std.testing.expectApproxEqAbs(@as(f64, 10), currentRate(&s, 1000, null).?, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 15), currentRate(&s, 1000, 20).?, 1e-9);
    try std.testing.expect(currentRate(&.{}, 1000, null) == null);
}

test "constant draw matches energy / power" {
    // 10 Wh at 5 W -> 2 h
    try std.testing.expectApproxEqAbs(@as(f64, 7200), timeToEmpty(10, 0, 5, null), 1e-6);
}
