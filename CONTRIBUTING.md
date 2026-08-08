# Contributing

VhectorDB targets Zig 0.16.0 and intentionally keeps its implementation small
and auditable. Changes should preserve that scope unless benchmarks justify
additional complexity.

Before opening a pull request, run:

```sh
zig fmt --check build.zig src
zig build test
zig build -Doptimize=ReleaseFast
```

For performance-sensitive changes, also run `zig build bench
-Doptimize=ReleaseFast` and include before/after results. Use `zig build stress`
for changes involving snapshots, reclamation, TTLs, or concurrent readers.

Bug reports should include the operating system, Zig version, command used,
and the smallest reproducible input. Please do not commit AOF files, generated
videos, metrics CSV files, or Zig build output.
