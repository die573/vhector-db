# Architecture

VhectorDB separates ingestion from query publication.

1. A client mutation is serialized into a checksummed AOF record.
2. The mutable record table is updated under a single-writer spin lock.
3. The rebuild worker filters TTLs and constructs a new neighborhood graph.
4. Two-dimensional data uses Delaunay edges; other dimensions use exact k-NN.
5. Randomized Ward-cost sweeps merge neighboring points into clusters.
6. The completed immutable generation is atomically published.
7. Readers pin the global read epoch and query without taking the writer lock.
8. Replaced generations are reclaimed at a quiescent point.

The coarse global epoch was chosen deliberately: it makes the safety argument
small and auditable. Per-thread epochs would reduce delayed reclamation under a
continuous read workload but add registration and lifecycle complexity.

## Durability

Every AOF entry contains a magic marker, operation, payload length, and FNV-1a
checksum. Replay ignores a partial final record, which is the expected shape of
a process crash during append, but rejects corruption in complete records.
The default relies on operating-system writeback. `--sync` fsyncs every
mutation when stronger durability is worth the additional latency.

## Current tradeoffs

- KNN queries are exact scans; topology is used for clustering. A snapshot-local
  KD-tree is the natural next optimization.
- Delaunay is limited to 2D. Exact k-NN provides a predictable N-dimensional
  fallback without the complexity explosion of general Delaunay predicates.
- Connections use native threads. This is simple and appropriate for the
  curriculum scope; a bounded worker pool is the production evolution.
- AOF compaction and authentication are not implemented.

## Stress profiles

`zig build stress` exercises the actual Store rather than a disconnected
microbenchmark. Its writer performs large ingestion, generation rebuilds,
replacements, and simulated-time TTL expiration while native reader threads pin
and query published snapshots. The final rebuild advances time beyond all
temporary records and explicitly attempts retired-generation collection.
