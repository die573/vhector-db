# VRESP protocol

VRESP is a UTF-8, line-oriented protocol. A command ends with `\r\n` or `\n`.
Arguments are separated by ASCII whitespace. Commands are case-insensitive;
keys are unsigned 64-bit integers and coordinates are 32-bit floats.

The bundled interactive client handles response framing:

```powershell
.\zig-out\bin\vhector_db.exe client --host 127.0.0.1 --port 6380
```

## Commands

| Command | Purpose |
| --- | --- |
| `PING` | Health check. |
| `PUT id [TTL milliseconds] v...` | Durably queue a vector. TTL must precede coordinates. |
| `GET id` | Read a vector from the latest published generation. |
| `DEL id` | Durably remove a vector. |
| `KNN count v...` | Exact nearest neighbors, ordered by Euclidean distance. |
| `RANGE radius v...` | All matching vectors up to the generation size. |
| `CLUSTERS` | Point-to-cluster assignments from the last optimization. |
| `REBUILD` | Synchronously publish pending mutations. |
| `STATS` | Generation, point, dirty, and recovery information. |
| `DEMO [scenario] TERMINAL [seconds]` | Stream an isolated ANSI topology simulation. |
| `DEMO [scenario] PREVIEW [seconds]` | Open a live FFplay preview on the server machine. |
| `DEMO [scenario] VIDEO [seconds] [name.mp4]` | Record the simulation through FFmpeg. |
| `QUIT` | Close the connection. |

`PUT` and `DEL` acknowledge after appending to the AOF and updating mutable
state. Reads use the latest immutable generation, so a write becomes queryable
after the background interval or an explicit `REBUILD`.

## Responses

```text
+PONG
+QUEUED
-ERR explanation
:1
$-1
@VECTOR 2 1.5 2.5
@MATCHES 2
42 0.25
91 0.75
@CLUSTERS 2
42 0
91 1
```

Multi-line responses declare their row count. The protocol deliberately does
not claim RESP compatibility.

`DEMO` is bounded to 1–30 seconds and never writes simulated points into the
server's persisted dataset. Terminal mode is an ANSI stream ending in
`+DEMO DONE`; video mode writes only a basename in the server working directory.
Preview opens on the machine running the server. Recording is intentionally
quiet unless FFmpeg reports an error.

Available scenarios are `GAUSSIAN`, `SWARM`, `TRAFFIC`, `SENSORS`, `GEOFENCE`,
`TOPOLOGY`, `COLLISION`, `PREDATOR_PREY`, `GALAXY`, `QUERIES`, and `TTL_STORM`.
Omitting the scenario selects `GAUSSIAN` for backward compatibility.
