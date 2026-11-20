# Status timing and content workload

**Unmapped is the nominal expected case.** Timings are warm-cache medians in ms. In each MiB cell, the first value is the sum of unique file sizes selected for content validation; the second is the separate diagnostic total of returned read/pread bytes + requested mmap lengths, including repeats. Mapping lengths are not measured bytes touched or physical I/O. Unchanged rows modify zero files; modified rows change byte zero of every mapped file. `*` marks incorrect baseline output.

| Fixture | State | Fsmonitor | Baseline ms | Selective ms | Always ms | Selective MiB (unique → requested) | Always MiB (unique → requested) |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| small | **Unmapped (nominal expected)** | off | 13.72 | 16.68 | 138.12 | 0 → 0 | 5.8203 → 5.8203 |
| small | **Unmapped (nominal expected)** | valid | 13.00 | 31.52 | 164.27 | 0 → 0 | 5.8203 → 5.8203 |
| one-large | **Unmapped (nominal expected)** | off | 7.08 | 6.78 | 190.79 | 0 → 0 | 100 → 100 |
| one-large | 1 mapped, unchanged | off | 7.35 | 188.47 | 186.91 | 100 → 100 | 100 → 100 |
| one-large | 1 mapped, modified | off | 7.19* | 551.32 | 548.77 | 100 → 300 | 100 → 300 |
| ten-large | **Unmapped (nominal expected)** | off | 7.33 | 7.59 | 1822.74 | 0 → 0 | 1,000 → 1,000 |
| ten-large | 1 mapped, unchanged | off | 6.95 | 189.06 | 1806.63 | 100 → 100 | 1,000 → 1,000 |
| ten-large | 10 mapped, unchanged | off | 7.27 | 1830.29 | 1816.54 | 1,000 → 1,000 | 1,000 → 1,000 |
| ten-large | 10 mapped, modified | off | 7.80* | 5479.45 | 5465.35 | 1,000 → 3,000 | 1,000 → 3,000 |
| mixed | **Unmapped (nominal expected)** | off | 13.38 | 18.22 | 521.80 | 0 → 0 | 205.8203 → 205.8203 |
| mixed | 2 mapped, unchanged | off | 15.31 | 383.08 | 513.98 | 200 → 200 | 205.8203 → 205.8203 |

The ten-large “10 mapped” rows use the same ten paths. Unchanged: zero modified files and 1,000 MiB requested by each correct variant. Modified: ten modified files and 3,000 MiB requested by each. Repeated content comparisons explain the roughly threefold status time. Both variants follow the same content path when all files are mapped, so their close times are expected. Unique file size does not triple. When files are unmapped, Selective skips their content and Always compares it.

See [RESULTS.md](RESULTS.md) for all status/diff rows and spread, and [workloads.tsv](workloads.tsv) for exact byte totals and the separate read/pread/mmap counters. Unique counts come from the controlled fixture and mapping set; request totals are measured in untimed diagnostic processes.
