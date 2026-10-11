# Spelunky Classic HD -- Zig port (packaged sources)

Standalone sources of the Zig port of Spelunky Classic HD: the transpiled game, the
runtime, the SDL2 host, and the game's assets and datafiles (packaged from commit
`9d530bda`).

## Requirements

- [Zig](https://ziglang.org) 0.16.0
- SDL2, SDL2_image, SDL2_mixer (development packages; found via pkg-config)

## Build & Run

```sh
zig build run -Doptimize=ReleaseFast
```

The executable is installed to `zig-out/bin/spelunky`. `zig build test` runs the unit
tests and boots the game headlessly to the title screen.

The executable reads sprites and sounds from `assets/` and uses `data/` as the game's
working directory (settings, `keys.json` and saves are written there). Both default to
the absolute paths of this directory at build time. Override them with
`--assets DIR` / `--data DIR` at run time, or with
`zig build -Dassets-dir=... -Ddata-dir=...`.

Other options: `--frames N`, `--screenshot FILE.bmp`, `--press F:VK[:N]`, `--mute`,
`--item OBJECT`.

## License

Spelunky was created by Derek Yu (Mossmouth, LLC). Spelunky Classic HD is by
yancharkin. Distributed under the Spelunky User License v1.1b; see `LICENSE`.
Non-commercial use only.
