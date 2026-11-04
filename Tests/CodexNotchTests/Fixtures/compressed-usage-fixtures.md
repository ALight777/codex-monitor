# Compressed usage fixtures

Generated with Zstandard 1.5.7 (`zstd -qc --check`); tests use only the bundled decoder.

- `compressed-usage.jsonl.zst`: two concatenated frames, thread `compressed-thread`, model `gpt-5.4`, 100 tokens at 2026-11-04 02:00 UTC, a 12 MB UTF-8 response item, then 200 tokens at 03:00 UTC. Cumulative counters are 100 and 300. Exercises line/chunk/frame boundaries without retaining irrelevant message bodies.
- `compressed-updated.jsonl.zst`: the same thread with one 400-token event at 03:00 UTC, used for replacement invalidation.
- `compressed-block-boundary.zst`: one frame decoding to exactly 131072 ASCII `x` bytes, the decoder output block size.

Truncation and checksum corruption are applied to temporary copies during tests.
