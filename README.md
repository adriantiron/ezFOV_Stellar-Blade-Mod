# ezFOV — Comprehensive FOV & Camera Control for Stellar Blade

A beginner-friendly [UE4SS](https://github.com/Rev-OG-UwU/SB-UE4SS) Lua mod that gives you independent
field-of-view and camera control for every gameplay context — exploration, combat, lock-on, third-person,
and the idle / walk / sprint locomotion states. Everything is driven by hotkeys and tuned live; editing the
config file is optional.

## Features

- **Per-context FOV & camera offsets** — separate settings for Default, Combat, Lock-on, Idle, Walk, Sprint, and TPS.
- **Smooth transitions** — eased FOV/position moves, with a dedicated lock-on entry and exit blend so the camera never snaps.
- **Lock-on target framing** — yaw/pitch bias for over-the-shoulder composition.
- **Live reload** — press `F8` to apply `ezFOV.cfg` changes instantly, no restart.
- **Presets** — four save/load slots for whole camera layouts.
- **Context-aware hotkey tuning** — the FOV/position keys edit whichever profile is currently active, and changes are written back to `ezFOV.cfg` automatically.
- **Optional camera-collision disable** for unobstructed cinematic framing.

## Requirements

- Stellar Blade (PC)
- [UE4SS](https://github.com/Rev-OG-UwU/SB-UE4SS) installed for the game

## Installation

1. Install UE4SS for Stellar Blade.
2. Copy the inner `ezFOV/` folder — the one containing `enabled.txt`, `ezFOV.cfg`, and `Scripts/` — into your
   UE4SS `Mods/` directory, so the game sees `.../ue4ss/Mods/ezFOV/`.
3. Make sure `enabled.txt` is present (it marks the mod as enabled).
4. Launch the game.

## Controls

The FOV and position keys act on the **currently active profile** and are saved to `ezFOV.cfg` automatically.

| Keys | Action |
| --- | --- |
| `F5` / `F6` / `F7` | Active-profile FOV: −25 / −5 / +5 |
| `F8` | Live-reload `ezFOV.cfg` |
| `Ctrl` + `↑` / `↓` | Camera depth — X axis: +50 / −50 |
| `Alt` + `↑` / `↓` | Camera height — Z axis: +10 / −10 |
| `Alt` + `←` / `→` | Camera lateral — Y axis: −10 / +10 |
| `Shift` + `↑` / `↓` | Lock-on pitch bias: +1° / −1° |
| `Shift` + `→` / `←` | Lock-on yaw bias: +1° / −1° |
| `Alt` + `1`–`4` | Save current layout to preset slot |
| `Ctrl` + `1`–`4` | Load & apply preset slot |

> Note: the position axes differ between standard modes (X = depth/zoom, Y = lateral, Z = height) and lock-on
> mode (rotation-corrected). See `ezFOV/ezFOV.cfg` for the full explanation.

## Configuration

All options live in `ezFOV/ezFOV.cfg`, which is thoroughly commented — coordinate systems, every offset, the
lock-on biases, feature toggles, and transition tuning. Edit it and press `F8` in-game to reload instantly.

## Development

The mod is written in Lua 5.4 (the UE4SS runtime) as a set of small, single-responsibility modules.

### Project layout

```text
ezFOV/                       repo root
├─ ezFOV/                    mod payload (this folder is installed under UE4SS Mods/)
│  ├─ enabled.txt            marks the mod enabled for UE4SS
│  ├─ ezFOV.cfg              user configuration (self-documented)
│  └─ Scripts/               Lua 5.4 source
│     ├─ main.lua            entry point: init, keybinds, live FOV/position/bias tuning, F8 reload
│     ├─ hooks.lua           UE4SS hook registration + bootstrap/cold-apply state machine
│     ├─ stance.lua          per-frame profile selection (with lock-on grace) and application
│     ├─ camera.lua          FOV/position transitions, lock-on enforcement loop, lock-on exit blend
│     ├─ camera_originals.lua save/restore of the camera's original offset & rotation
│     ├─ profiles.lua        pure state → profile → (fov, position) resolution
│     ├─ playercontext.lua   reads player/camera/boom + TPS/lock-on/battle/locomotion state
│     ├─ config.lua          schema-driven .cfg load/save + presets
│     ├─ constants.lua       shared tuning constants (FOV bounds, bias limit, locomotion thresholds)
│     ├─ easing.lua          quadratic easing + millisecond clock
│     ├─ ue_object.lua       UE object validity guard
│     ├─ env.lua             host-boundary adapter (guarded game-thread calls, keybinds, hooks)
│     ├─ logging.lua         component-scoped, throttled logging
│     ├─ heartbeat.lua       periodic pulse driver
│     └─ ...                 runtime mod scripts only
├─ tests/
│  └─ sanity_test.lua        offline smoke / characterization tests
├─ run-tests.cmd             offline test runner
├─ stylua.toml               formatter config
├─ selene.toml               linter config
└─ ue4ss.yml                 selene standard library (UE4SS-injected globals)
```

Module dependency order (low → high): `logging → env → heartbeat → playercontext → config → camera → stance →
hooks → main`. `profiles`, `constants`, `easing`, `ue_object`, and `camera_originals` are dependency-light helpers.

### Tooling

- **Formatting** — [StyLua](https://github.com/JohnnyMorganz/StyLua) (`stylua.toml`: 120 columns, 4-space indent, Windows line endings).
- **Linting** — [selene](https://github.com/Kampfkarren/selene) (`selene.toml` plus `ue4ss.yml`, which declares the UE4SS-injected globals).

> selene resolves its config and standard library from the current working directory. Open the **repo root**
> as your workspace so `selene.toml` / `ue4ss.yml` load; otherwise you'll see one false positive
> (`FindFirstOf is not defined` in `playercontext.lua`) because the UE4SS std isn't picked up.

### Testing

An offline suite runs without the game and is the first line of defense before shipping:

```sh
run-tests.cmd            # uses "lua" from PATH
run-tests.cmd lua54      # use a specific interpreter
```

Run it from the repo root — the test resolves modules by relative path (`./ezFOV/Scripts/...`). It compiles
every module and runs behavior/characterization checks: the config write → save-preset → load-preset round-trip,
FOV clamping, the profile-resolution truth table, easing boundaries, and the UE validity guard. It exits
non-zero on failure, so it's CI-friendly.

The offline suite can't drive the live camera, so after changes to `camera.lua` or `stance.lua`, smoke-test
in-game: FOV keys, camera-position keys, lock-on enter/exit, presets, and `F8` reload.
