# VhectorDB

VhectorDB is a compact streaming spatial database written in Zig. It combines
computational geometry and Redis-like ergonomics: points arrive continuously,
the engine rebuilds immutable spatial snapshots in the background, and clients
query or cluster them through a small command protocol.

The project is intentionally not a Tessera port. Its first original design
choice is a hybrid neighborhood graph:

- two-dimensional data uses exact Bowyer-Watson Delaunay triangulation;
- higher-dimensional data uses an exact symmetric k-nearest-neighbor graph;
- a randomized Ward-cost optimizer merges neighboring points into clusters.

This retains the interesting topology-driven optimization while keeping the
implementation small enough to study, benchmark, and explain.

## Status

Implemented:

- compact 2D Bowyer-Watson triangulation;
- exact symmetric k-nearest-neighbor topology for higher dimensions;
- randomized Ward-cost topology-aware clustering;
- keyed vector mutation and TTL expiration;
- atomic immutable generation publication;
- lock-free read acquisition with quiescent-state snapshot reclamation;
- exact nearest-neighbor and range queries against a pinned generation;
- checksummed append-only persistence and crash-tail recovery;
- TTL-aware background generation rebuilding;
- concurrent TCP clients and the VRESP command protocol;
- a ReleaseFast benchmark target and Windows/Linux CI.

## Build

Requires Zig 0.16.0.

```sh
zig build test
zig build -Doptimize=ReleaseFast
zig build run -- --dim 2 --port 6380 --aof data.aof
zig build bench -Doptimize=ReleaseFast
zig build demo -- --mode terminal --seconds 8
```

VhectorDB has no third-party Zig dependencies. FFmpeg is optional and only
required for graphical demo preview and MP4 recording.

## Try it

Build once, then use two terminals. Terminal 1 runs the server:

```powershell
.\zig-out\bin\vhector_db.exe server --dim 2 --port 6380 --aof data.aof
```

Terminal 2 runs the bundled cross-platform client:

```powershell
.\zig-out\bin\vhector_db.exe client --host 127.0.0.1 --port 6380
```

The client provides a `vhector>` prompt and understands multiline and streamed
responses. Enter `HELP` to list commands; no `nc`, Telnet, or PowerShell socket
script is required. Enter `CLS` or `CLEAR` to clear the client terminal without
sending a command to the server.

Example client session:

```text
vhector> PING
+PONG
vhector> PUT 1 0.0 0.0
+QUEUED
vhector> REBUILD
:2
vhector> KNN 1 0.2 0.0
@MATCHES 1
1 0.2
```

## Animated simulation

Run the ANSI simulation locally:

```powershell
zig build demo -- --mode terminal --seconds 8
```

Or, after installing FFmpeg and putting `ffmpeg` on `PATH`, record an MP4:

```powershell
zig build demo -Doptimize=ReleaseFast -- --mode video --seconds 8 --output vhector-demo.mp4 --csv demo-metrics.csv
```

For a live graphical preview in a separate `ffplay` window without creating a
file:

```powershell
zig build demo -Doptimize=ReleaseFast -- --mode preview --seconds 8
```

`preview` pipes raw frames to `ffplay`; `video` quietly pipes the same frames to
FFmpeg and writes the MP4. A traditional terminal cannot render ordinary video,
which is why `terminal` remains the portable ANSI option.

The server exposes the same isolated showcase through VRESP:

```text
DEMO TERMINAL 8
DEMO PREVIEW 8
DEMO VIDEO 8 vhector-demo.mp4
```

The simulation generates moving Gaussian populations with staggered lifetimes,
streams TTL-bound points through the real store, rebuilds and clusters every
frame, and renders the resulting Delaunay topology. It does not modify the
server's persisted user dataset.

### Demo scenarios

Every scenario supports `terminal`, `preview`, and `video` modes:

| Scenario | Engine behavior demonstrated |
| --- | --- |
| `gaussian` | Moving populations, cluster birth/death, and TTLs. |
| `swarm` | Emergent groups that orbit, compress, and separate. |
| `traffic` | Orthogonal lanes and continuously moving spatial objects. |
| `sensors` | Drifting high-density sensor hotspots. |
| `geofence` | Objects crossing a rendered circular boundary. |
| `topology` | Continuous circle-to-grid Delaunay transformation. |
| `collision` | Bouncing particles and rapidly changing neighborhoods. |
| `predator_prey` | A dense moving population followed by sparse predators. |
| `galaxy` | Differentially rotating spiral arms. |
| `queries` | A moving query point and rendered range boundary. |
| `ttl_storm` | Alternating ingestion bursts and aggressive expiration. |

Examples:

```powershell
zig build demo -- --scenario topology --mode terminal --seconds 8
zig build demo -Doptimize=ReleaseFast -- --scenario galaxy --mode preview --seconds 12
zig build demo -Doptimize=ReleaseFast -- --scenario traffic --mode video --seconds 12 --output traffic.mp4
```

From the bundled client:

```text
DEMO SWARM PREVIEW 12
DEMO TTL_STORM TERMINAL 8
DEMO QUERIES VIDEO 10 queries.mp4
```

The older `DEMO PREVIEW 8` form remains supported and defaults to `gaussian`.

## Stress testing

The stress target always compiles in `ReleaseFast` and is kept out of normal CI
so large exact graph builds do not slow ordinary development:

```powershell
# Default: 10,000 points, 8 dimensions, 2,000 queries, 8 churn rounds,
# and 4 concurrent snapshot readers.
zig build stress

# Custom profile
zig build stress -- --points 25000 --dim 12 --queries 5000 --rounds 12 --readers 8
```

It validates large ingestion, exact high-dimensional k-NN topology construction,
query load, TTL expiration, mutation churn, concurrent lock-free readers,
generation retirement, and quiescent reclamation.

Writes are durable and immediately enter mutable state. Queries intentionally
observe the latest published generation; wait for the configured rebuild
interval or use `REBUILD` when read-after-write publication is required.

See [the protocol reference](docs/PROTOCOL.md) and
[architecture notes](docs/ARCHITECTURE.md) for the complete interface and
engineering tradeoffs.

## Design goals

- one native binary and no runtime dependencies;
- predictable reads through immutable snapshots;
- topology-aware clustering rather than embedding-only nearest-neighbor search;
- measurable behavior, with benchmarks for ingestion, rebuild latency, query
  latency, and cluster convergence;
- a focused codebase whose tradeoffs can be defended in a systems interview.

## Read/write model

Writes update a mutable record table under a short single-writer lock. A rebuild
filters expired records, constructs the neighborhood topology, runs clustering,
and atomically publishes a new immutable generation. Queries increment a global
reader epoch counter before loading that generation and need no writer lock.
Replaced generations enter a retirement list and are reclaimed at the next
quiescent point. This deliberately favors a small, auditable implementation;
per-thread epochs can replace the global counter if benchmarks show reclamation
latency matters.

## Inspiration

Tessera inspired the use of spatial topology, background optimization, TTL-aware
streaming updates, and snapshots. VhectorDB adds a networked database surface
and uses a hybrid graph so arbitrary-dimensional vectors do not require a large
general-dimensional Delaunay implementation.

## License

Released under the [MIT License](LICENSE).
