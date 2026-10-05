# denki-yoho (電気予報)

Battery remaining-time forecast for Linux laptops that knows your usual power draw at each time of day.

Waybar's built-in battery module (and most others) estimate `energy_now / power_now`, so the number jumps with every load spike. denki-yoho reads the history upower already records, builds a "usual watts at this time of day" profile, and simulates forward from the current energy.

```
$ denki-yoho status
discharging 54%
Empty in 2 h 06 min (≈ 13:26)
now 12.4 W · usual 9.8 W
naive 1 h 54 min
1340 samples / 14 d
profile: cached
```

## How it works

1. **Profile**: discharge samples from the last 14 days of `/var/lib/upower/history-rate-<model>-*-<serial>.dat` are grouped into 30-minute bins of local time. Each bin takes the median watts. A sparse bin pools in its neighbours, then falls back to the overall median.
2. **Current draw**: EWMA (τ = 5 min) over the last 10 minutes of samples plus the live `power_now`.
3. **Forecast**: steps forward a minute at a time, blending from the current draw to the profile (τ = 30 min), until the energy reaches zero.

Charging shows `(energy_full - energy_now) / power_now`.

### Stateless and cheap

No daemon, no log of its own: upowerd is the only thing that needs to run. Each invocation reads sysfs and the last 16 KiB of the history log. The profile is cached in `$XDG_RUNTIME_DIR/denki-yoho-profile` (tmpfs) and rebuilt from the full log once an hour, so a run takes about 1–2 ms. Deleting the cache is always safe.

## Usage

```
denki-yoho [command] [options]

Commands:
  waybar     One line of Waybar custom-module JSON (default)
  status     Human-readable estimate
  profile    Usual draw per time of day

Options:
  -b, --battery NAME   power_supply device (default: BAT0)
      --no-cache       Rebuild the profile instead of using the cache
  -h, --help           Show this help
  -V, --version        Show the version
```

### Waybar

```jsonc
"modules-right": [ "custom/battery" ],
"custom/battery": {
  "exec": "denki-yoho",
  "interval": 30,
  "return-type": "json",
  "format": "{}"
}
```

The JSON carries `text`, `tooltip`, `percentage` and `class` (`warning` ≤ 30 %, `critical` ≤ 15 %, `charging`, `plugged`), so the usual selectors work as `#custom-battery.critical:not(.charging)` etc.

## Install

```sh
nix run github:rei78-4e/denki-yoho -- status
```

or add the flake's `packages.<system>.default` to your profile.

## Build

Requires Zig 0.16 and libc (for `localtime_r`).

```sh
nix develop        # zig_0_16 + zls
zig build          # zig-out/bin/denki-yoho
zig build test
```

Tunables live in `src/config.zig`.

## License

MIT © 2026 rei78-4e
