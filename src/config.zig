// SPDX-License-Identifier: MIT
// Copyright (c) 2026 rei78-4e

//! Tunables. Times are in seconds unless noted.

/// Days of upower history used to build the time-of-day profile.
pub const lookback_days = 14;
/// Profile resolution in minutes; must divide a day evenly.
pub const bin_min = 30;
pub const nbins = 24 * 60 / bin_min;
/// A bin needs this many samples (~10 min at upower's 30 s cadence) before
/// it stands on its own; otherwise neighbouring bins are pooled in.
pub const min_bin_samples = 20;
/// How far the pooling may reach on each side before falling back to the
/// overall median.
pub const max_widen = 3;

/// Samples used for the current draw, and its EWMA time constant.
pub const now_window = 10 * 60;
pub const now_tau = 5 * 60;
/// Time constant for handing the forecast over from the current draw to
/// the profile.
pub const blend_tau = 30 * 60;
pub const step = 60;
pub const horizon = 48 * 3600;

/// The profile barely moves within an hour, so a cached copy is reused for
/// this long before the full history is read again.
pub const profile_ttl = 3600;
/// Bytes read from the end of the history log for the current draw.
pub const tail_bytes = 16 * 1024;

pub const warning = 30;
pub const critical = 15;

pub const sysfs_dir = "/sys/class/power_supply";
pub const history_dir = "/var/lib/upower";
pub const default_battery = "BAT0";
