# Local macOS experiment results

Benchmark only. **Do not merge or submit upstream.** Warm cache; medians in ms. Every cell is median ± median absolute deviation (MAD), with 9 measured samples after 2 warmup rounds. `*` means incorrect output for every sample (silent mapped writes); its speed is not an equally-correct result.

Measured 2026-11-09T16:36:42Z through 2026-11-09T17:02:57Z.

Apple M2 Max MacBook Pro (Mac14,6), 32 GB, arm64; macOS 27.2 (26B123), Darwin 27.2.0; Apple clang 21.0.0. Hardware fields verified with `system_profiler`, while the sandbox denied the `sysctl` read. All executables use `make -j8 NO_GETTEXT=YesPlease CFLAGS='-O2 -g' git`.

| Variant | Exact source SHA |
| --- | --- |
| baseline | `fb255012acbcbe81189cb8014da0280b09c66ecc` |
| selective | `8e6340c0b705182db2840f99343f327373034411` |
| always | `4be2dcea27b9af28b4a8d9ceb14b412ad0e7fad5` |

Raw samples, per-sample exact output, index hashes, correctness flags, metadata, build flags and diagnostic counters: [results.json](results.json). Binary hashes and build records: [builds.json](builds.json).

All fixture bytes were explicitly written and fsynced, using repeated ASCII `A` (highly compressible, identical content at equal sizes); no sparse, clone, reflink or hardlink fixture construction. They were processed serially.

| Fixture | Files | Bytes | MiB | Allocated worktree bytes |
| --- | ---: | ---: | ---: | ---: |
| small | 5000 | 6,103,040 | 5.8203 | 21,266,432 |
| one-large | 1 | 104,857,600 | 100.0000 | 104,857,600 |
| ten-large | 10 | 1,048,576,000 | 1000.0000 | 1,048,576,000 |
| mixed | 5002 | 215,818,240 | 205.8203 | 230,981,632 |

**Unmapped is the nominal expected case.** Mapped rows deliberately stress the fallback. “Unchanged” means zero files modified; “modified” means byte zero of every mapped file was changed. The ten-large many rows use the same ten 100 MiB paths: ten mapped / zero modified versus ten mapped / ten modified.

Workload tables distinguish **unique file size** from **total content requests**, which include repeated work. Unique counts and byte sums are derived from the controlled mapped set (Selective) and all fixture files (Always); they are not per-path tracing measurements. Request totals are measured in separate diagnostic processes: returned read + pread bytes plus successful mmap requested lengths. **Requested mapping length is not bytes touched, bytes hashed, or physical I/O.** Exact bytes and the component counters for every row are in [workloads.tsv](workloads.tsv).

For ten-large status, both variants cover 1,000 MiB of unique files when all ten are mapped. Unchanged requests total 1,000 MiB and modified requests total 3,000 MiB, explaining the roughly 1.83 s versus 5.47 s times. These are the same ten paths, with different content state. Diff requests 4,000 MiB in the modified case; the extra mapping need not be fully touched, so its requested extent cannot be read as extra full-file hashing. When all large data requires content comparison, the current Selective and Always implementations take essentially the same content path and their times are expected to be close.

## small

| State | Fsmonitor | Command | Baseline | Selective | Always | Always − selective ms | Always / selective |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| **Unmapped (nominal expected)** | off | status | 13.72 ± 0.93 | 16.68 ± 0.57 | 138.12 ± 16.97 | +121.44 | 8.28× |
| **Unmapped (nominal expected)** | off | diff | 12.16 ± 0.14 | 16.56 ± 0.23 | 164.49 ± 9.44 | +147.93 | 9.94× |
| **Unmapped (nominal expected)** | valid | status | 13.00 ± 0.37 | 31.52 ± 0.97 | 164.27 ± 12.79 | +132.75 | 5.21× |
| **Unmapped (nominal expected)** | valid | diff | 10.80 ± 0.36 | 29.41 ± 1.30 | 142.78 ± 17.56 | +113.36 | 4.85× |
| 1 mapped, unchanged | off | status | 13.73 ± 0.27 | 18.11 ± 1.21 | 167.78 ± 5.70 | +149.66 | 9.26× |
| 1 mapped, unchanged | off | diff | 12.98 ± 0.52 | 16.81 ± 0.89 | 168.68 ± 6.00 | +151.87 | 10.03× |
| 1 mapped, unchanged | valid | status | 13.70 ± 0.49 | 31.80 ± 1.20 | 141.52 ± 12.84 | +109.72 | 4.45× |
| 1 mapped, unchanged | valid | diff | 11.14 ± 0.26 | 29.31 ± 0.92 | 122.71 ± 2.29 | +93.39 | 4.19× |
| 1 mapped, modified | off | status | 13.66 ± 0.55* | 18.47 ± 0.75 | 166.68 ± 4.70 | +148.20 | 9.02× |
| 1 mapped, modified | off | diff | 12.57 ± 0.17* | 17.55 ± 0.31 | 163.98 ± 3.03 | +146.43 | 9.34× |
| 1 mapped, modified | valid | status | 12.93 ± 0.58* | 32.76 ± 0.51 | 168.61 ± 15.94 | +135.85 | 5.15× |
| 1 mapped, modified | valid | diff | 11.04 ± 0.33* | 31.20 ± 1.03 | 142.22 ± 16.42 | +111.01 | 4.56× |
| 64 mapped, unchanged | off | status | 14.22 ± 0.17 | 20.81 ± 0.97 | 139.15 ± 18.64 | +118.33 | 6.69× |
| 64 mapped, unchanged | off | diff | 12.36 ± 0.42 | 20.22 ± 1.05 | 163.15 ± 10.00 | +142.92 | 8.07× |
| 64 mapped, unchanged | valid | status | 12.84 ± 0.52 | 36.25 ± 1.62 | 162.89 ± 14.42 | +126.65 | 4.49× |
| 64 mapped, unchanged | valid | diff | 11.01 ± 0.30 | 34.83 ± 1.61 | 170.54 ± 3.46 | +135.71 | 4.90× |
| 64 mapped, modified | off | status | 14.41 ± 0.32* | 27.84 ± 0.79 | 145.05 ± 19.29 | +117.21 | 5.21× |
| 64 mapped, modified | off | diff | 13.05 ± 0.42* | 31.66 ± 1.18 | 177.95 ± 9.89 | +146.29 | 5.62× |
| 64 mapped, modified | valid | status | 13.41 ± 0.13* | 43.43 ± 1.46 | 178.09 ± 5.69 | +134.66 | 4.10× |
| 64 mapped, modified | valid | diff | 11.43 ± 0.45* | 45.88 ± 1.43 | 182.52 ± 8.22 | +136.64 | 3.98× |

File sizes and separate diagnostic work for each timing row:

| State | Fsmonitor | Command | Modified files (MiB) | Selective unique files (MiB) | Selective requested MiB | Always unique files (MiB) | Always requested MiB |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| **Unmapped (nominal expected)** | off | status | 0 (0) | 0 (0) | 0 | 5000 (5.8203) | 5.8203 |
| **Unmapped (nominal expected)** | off | diff | 0 (0) | 0 (0) | 0 | 5000 (5.8203) | 5.8203 |
| **Unmapped (nominal expected)** | valid | status | 0 (0) | 0 (0) | 0 | 5000 (5.8203) | 5.8203 |
| **Unmapped (nominal expected)** | valid | diff | 0 (0) | 0 (0) | 0 | 5000 (5.8203) | 5.8203 |
| 1 mapped, unchanged | off | status | 0 (0) | 1 (0.0156) | 0.0156 | 5000 (5.8203) | 5.8203 |
| 1 mapped, unchanged | off | diff | 0 (0) | 1 (0.0156) | 0.0156 | 5000 (5.8203) | 5.8203 |
| 1 mapped, unchanged | valid | status | 0 (0) | 1 (0.0156) | 0.0156 | 5000 (5.8203) | 5.8203 |
| 1 mapped, unchanged | valid | diff | 0 (0) | 1 (0.0156) | 0.0156 | 5000 (5.8203) | 5.8203 |
| 1 mapped, modified | off | status | 1 (0.0156) | 1 (0.0156) | 0.0469 | 5000 (5.8203) | 5.8516 |
| 1 mapped, modified | off | diff | 1 (0.0156) | 1 (0.0156) | 0.0625 | 5000 (5.8203) | 5.8672 |
| 1 mapped, modified | valid | status | 1 (0.0156) | 1 (0.0156) | 0.0469 | 5000 (5.8203) | 5.8516 |
| 1 mapped, modified | valid | diff | 1 (0.0156) | 1 (0.0156) | 0.0625 | 5000 (5.8203) | 5.8672 |
| 64 mapped, unchanged | off | status | 0 (0) | 64 (1) | 1 | 5000 (5.8203) | 5.8203 |
| 64 mapped, unchanged | off | diff | 0 (0) | 64 (1) | 1 | 5000 (5.8203) | 5.8203 |
| 64 mapped, unchanged | valid | status | 0 (0) | 64 (1) | 1 | 5000 (5.8203) | 5.8203 |
| 64 mapped, unchanged | valid | diff | 0 (0) | 64 (1) | 1 | 5000 (5.8203) | 5.8203 |
| 64 mapped, modified | off | status | 64 (1) | 64 (1) | 3 | 5000 (5.8203) | 7.8203 |
| 64 mapped, modified | off | diff | 64 (1) | 64 (1) | 4 | 5000 (5.8203) | 8.8203 |
| 64 mapped, modified | valid | status | 64 (1) | 64 (1) | 3 | 5000 (5.8203) | 7.8203 |
| 64 mapped, modified | valid | diff | 64 (1) | 64 (1) | 4 | 5000 (5.8203) | 8.8203 |

## one-large

| State | Fsmonitor | Command | Baseline | Selective | Always | Always − selective ms | Always / selective |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| **Unmapped (nominal expected)** | off | status | 7.08 ± 0.14 | 6.78 ± 0.16 | 190.79 ± 0.87 | +184.01 | 28.16× |
| **Unmapped (nominal expected)** | off | diff | 5.69 ± 0.48 | 6.23 ± 0.46 | 184.80 ± 1.85 | +178.57 | 29.67× |
| **Unmapped (nominal expected)** | valid | status | 11.70 ± 0.42 | 11.72 ± 0.66 | 192.21 ± 1.56 | +180.49 | 16.40× |
| **Unmapped (nominal expected)** | valid | diff | 10.67 ± 0.26 | 10.57 ± 0.68 | 193.10 ± 1.03 | +182.54 | 18.28× |
| 1 mapped, unchanged | off | status | 7.35 ± 0.25 | 188.47 ± 1.77 | 186.91 ± 2.43 | -1.55 | 0.99× |
| 1 mapped, unchanged | off | diff | 6.48 ± 0.47 | 187.66 ± 3.24 | 185.74 ± 2.64 | -1.92 | 0.99× |
| 1 mapped, unchanged | valid | status | 11.71 ± 0.33 | 194.48 ± 0.91 | 193.73 ± 2.77 | -0.75 | 1.00× |
| 1 mapped, unchanged | valid | diff | 10.97 ± 0.22 | 190.20 ± 0.89 | 190.35 ± 2.57 | +0.16 | 1.00× |
| 1 mapped, modified | off | status | 7.19 ± 0.27* | 551.32 ± 3.80 | 548.77 ± 2.46 | -2.55 | 1.00× |
| 1 mapped, modified | off | diff | 6.60 ± 0.64* | 569.63 ± 5.95 | 567.61 ± 5.02 | -2.01 | 1.00× |
| 1 mapped, modified | valid | status | 12.58 ± 0.64* | 558.30 ± 4.77 | 556.52 ± 1.06 | -1.79 | 1.00× |
| 1 mapped, modified | valid | diff | 11.43 ± 0.09* | 579.37 ± 2.24 | 576.64 ± 1.91 | -2.74 | 1.00× |

File sizes and separate diagnostic work for each timing row:

| State | Fsmonitor | Command | Modified files (MiB) | Selective unique files (MiB) | Selective requested MiB | Always unique files (MiB) | Always requested MiB |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| **Unmapped (nominal expected)** | off | status | 0 (0) | 0 (0) | 0 | 1 (100) | 100 |
| **Unmapped (nominal expected)** | off | diff | 0 (0) | 0 (0) | 0 | 1 (100) | 100 |
| **Unmapped (nominal expected)** | valid | status | 0 (0) | 0 (0) | 0 | 1 (100) | 100 |
| **Unmapped (nominal expected)** | valid | diff | 0 (0) | 0 (0) | 0 | 1 (100) | 100 |
| 1 mapped, unchanged | off | status | 0 (0) | 1 (100) | 100 | 1 (100) | 100 |
| 1 mapped, unchanged | off | diff | 0 (0) | 1 (100) | 100 | 1 (100) | 100 |
| 1 mapped, unchanged | valid | status | 0 (0) | 1 (100) | 100 | 1 (100) | 100 |
| 1 mapped, unchanged | valid | diff | 0 (0) | 1 (100) | 100 | 1 (100) | 100 |
| 1 mapped, modified | off | status | 1 (100) | 1 (100) | 300 | 1 (100) | 300 |
| 1 mapped, modified | off | diff | 1 (100) | 1 (100) | 400 | 1 (100) | 400 |
| 1 mapped, modified | valid | status | 1 (100) | 1 (100) | 300 | 1 (100) | 300 |
| 1 mapped, modified | valid | diff | 1 (100) | 1 (100) | 400 | 1 (100) | 400 |

## ten-large

| State | Fsmonitor | Command | Baseline | Selective | Always | Always − selective ms | Always / selective |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| **Unmapped (nominal expected)** | off | status | 7.33 ± 0.19 | 7.59 ± 0.47 | 1822.74 ± 11.28 | +1815.15 | 240.30× |
| **Unmapped (nominal expected)** | off | diff | 6.31 ± 0.40 | 7.14 ± 0.28 | 1826.34 ± 8.17 | +1819.20 | 255.82× |
| **Unmapped (nominal expected)** | valid | status | 12.18 ± 0.35 | 12.46 ± 0.90 | 1827.82 ± 6.87 | +1815.35 | 146.67× |
| **Unmapped (nominal expected)** | valid | diff | 11.40 ± 0.50 | 10.88 ± 0.30 | 1831.08 ± 9.64 | +1820.19 | 168.24× |
| 1 mapped, unchanged | off | status | 6.95 ± 0.30 | 189.06 ± 2.09 | 1806.63 ± 14.49 | +1617.57 | 9.56× |
| 1 mapped, unchanged | off | diff | 6.82 ± 0.36 | 185.62 ± 2.47 | 1815.83 ± 5.97 | +1630.21 | 9.78× |
| 1 mapped, unchanged | valid | status | 12.45 ± 0.62 | 193.80 ± 0.97 | 1826.74 ± 9.66 | +1632.94 | 9.43× |
| 1 mapped, unchanged | valid | diff | 11.27 ± 0.29 | 198.05 ± 4.40 | 1854.94 ± 24.88 | +1656.90 | 9.37× |
| 1 mapped, modified | off | status | 6.99 ± 0.20* | 549.60 ± 3.83 | 2181.80 ± 15.74 | +1632.19 | 3.97× |
| 1 mapped, modified | off | diff | 6.40 ± 0.30* | 565.79 ± 3.81 | 2179.54 ± 6.97 | +1613.75 | 3.85× |
| 1 mapped, modified | valid | status | 11.50 ± 0.20* | 559.61 ± 10.33 | 2193.87 ± 25.67 | +1634.26 | 3.92× |
| 1 mapped, modified | valid | diff | 10.69 ± 0.31* | 570.25 ± 3.82 | 2201.68 ± 19.73 | +1631.43 | 3.86× |
| 10 mapped, unchanged | off | status | 7.27 ± 0.18 | 1830.29 ± 9.97 | 1816.54 ± 10.76 | -13.75 | 0.99× |
| 10 mapped, unchanged | off | diff | 5.87 ± 0.38 | 1827.92 ± 7.19 | 1828.55 ± 8.89 | +0.63 | 1.00× |
| 10 mapped, unchanged | valid | status | 11.99 ± 0.77 | 1822.97 ± 22.07 | 1796.12 ± 18.08 | -26.85 | 0.99× |
| 10 mapped, unchanged | valid | diff | 11.47 ± 0.24 | 1825.98 ± 5.77 | 1840.37 ± 11.92 | +14.40 | 1.01× |
| 10 mapped, modified | off | status | 7.80 ± 0.53* | 5479.45 ± 16.29 | 5465.35 ± 16.06 | -14.10 | 1.00× |
| 10 mapped, modified | off | diff | 6.96 ± 0.32* | 5685.99 ± 23.78 | 5659.44 ± 9.50 | -26.55 | 1.00× |
| 10 mapped, modified | valid | status | 13.27 ± 0.71* | 5471.45 ± 32.44 | 5471.50 ± 7.85 | +0.05 | 1.00× |
| 10 mapped, modified | valid | diff | 10.97 ± 0.29* | 5627.09 ± 14.59 | 5655.20 ± 20.40 | +28.12 | 1.00× |

File sizes and separate diagnostic work for each timing row:

| State | Fsmonitor | Command | Modified files (MiB) | Selective unique files (MiB) | Selective requested MiB | Always unique files (MiB) | Always requested MiB |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| **Unmapped (nominal expected)** | off | status | 0 (0) | 0 (0) | 0 | 10 (1,000) | 1,000 |
| **Unmapped (nominal expected)** | off | diff | 0 (0) | 0 (0) | 0 | 10 (1,000) | 1,000 |
| **Unmapped (nominal expected)** | valid | status | 0 (0) | 0 (0) | 0 | 10 (1,000) | 1,000 |
| **Unmapped (nominal expected)** | valid | diff | 0 (0) | 0 (0) | 0 | 10 (1,000) | 1,000 |
| 1 mapped, unchanged | off | status | 0 (0) | 1 (100) | 100 | 10 (1,000) | 1,000 |
| 1 mapped, unchanged | off | diff | 0 (0) | 1 (100) | 100 | 10 (1,000) | 1,000 |
| 1 mapped, unchanged | valid | status | 0 (0) | 1 (100) | 100 | 10 (1,000) | 1,000 |
| 1 mapped, unchanged | valid | diff | 0 (0) | 1 (100) | 100 | 10 (1,000) | 1,000 |
| 1 mapped, modified | off | status | 1 (100) | 1 (100) | 300 | 10 (1,000) | 1,200 |
| 1 mapped, modified | off | diff | 1 (100) | 1 (100) | 400 | 10 (1,000) | 1,300 |
| 1 mapped, modified | valid | status | 1 (100) | 1 (100) | 300 | 10 (1,000) | 1,200 |
| 1 mapped, modified | valid | diff | 1 (100) | 1 (100) | 400 | 10 (1,000) | 1,300 |
| 10 mapped, unchanged | off | status | 0 (0) | 10 (1,000) | 1,000 | 10 (1,000) | 1,000 |
| 10 mapped, unchanged | off | diff | 0 (0) | 10 (1,000) | 1,000 | 10 (1,000) | 1,000 |
| 10 mapped, unchanged | valid | status | 0 (0) | 10 (1,000) | 1,000 | 10 (1,000) | 1,000 |
| 10 mapped, unchanged | valid | diff | 0 (0) | 10 (1,000) | 1,000 | 10 (1,000) | 1,000 |
| 10 mapped, modified | off | status | 10 (1,000) | 10 (1,000) | 3,000 | 10 (1,000) | 3,000 |
| 10 mapped, modified | off | diff | 10 (1,000) | 10 (1,000) | 4,000 | 10 (1,000) | 4,000 |
| 10 mapped, modified | valid | status | 10 (1,000) | 10 (1,000) | 3,000 | 10 (1,000) | 3,000 |
| 10 mapped, modified | valid | diff | 10 (1,000) | 10 (1,000) | 4,000 | 10 (1,000) | 4,000 |

## mixed

| State | Fsmonitor | Command | Baseline | Selective | Always | Always − selective ms | Always / selective |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| **Unmapped (nominal expected)** | off | status | 13.38 ± 0.68 | 18.22 ± 0.60 | 521.80 ± 12.46 | +503.58 | 28.64× |
| **Unmapped (nominal expected)** | off | diff | 12.66 ± 0.38 | 16.49 ± 0.70 | 516.47 ± 17.58 | +499.98 | 31.33× |
| **Unmapped (nominal expected)** | valid | status | 13.30 ± 0.30 | 32.02 ± 1.25 | 524.23 ± 12.33 | +492.21 | 16.37× |
| **Unmapped (nominal expected)** | valid | diff | 11.59 ± 0.65 | 30.67 ± 1.07 | 517.63 ± 13.23 | +486.96 | 16.88× |
| 1 mapped, unchanged | off | status | 13.77 ± 0.69 | 198.75 ± 1.16 | 520.43 ± 4.43 | +321.68 | 2.62× |
| 1 mapped, unchanged | off | diff | 12.70 ± 0.19 | 200.23 ± 1.13 | 530.30 ± 5.49 | +330.06 | 2.65× |
| 1 mapped, unchanged | valid | status | 13.05 ± 0.42 | 216.89 ± 3.60 | 527.04 ± 8.50 | +310.16 | 2.43× |
| 1 mapped, unchanged | valid | diff | 11.14 ± 0.32 | 213.74 ± 3.35 | 529.74 ± 12.38 | +316.00 | 2.48× |
| 1 mapped, modified | off | status | 13.59 ± 0.67* | 559.18 ± 2.69 | 886.87 ± 7.89 | +327.70 | 1.59× |
| 1 mapped, modified | off | diff | 12.51 ± 0.33* | 578.40 ± 5.93 | 900.45 ± 19.53 | +322.06 | 1.56× |
| 1 mapped, modified | valid | status | 13.71 ± 0.51* | 587.21 ± 6.60 | 851.93 ± 10.95 | +264.71 | 1.45× |
| 1 mapped, modified | valid | diff | 11.99 ± 0.78* | 596.48 ± 5.49 | 904.27 ± 3.09 | +307.80 | 1.52× |
| 2 mapped, unchanged | off | status | 15.31 ± 0.42 | 383.08 ± 2.74 | 513.98 ± 1.73 | +130.90 | 1.34× |
| 2 mapped, unchanged | off | diff | 13.66 ± 0.22 | 383.64 ± 3.86 | 519.28 ± 4.15 | +135.64 | 1.35× |
| 2 mapped, unchanged | valid | status | 14.39 ± 0.36 | 398.82 ± 3.97 | 525.93 ± 3.85 | +127.11 | 1.32× |
| 2 mapped, unchanged | valid | diff | 12.30 ± 0.17 | 396.48 ± 3.21 | 524.38 ± 6.95 | +127.90 | 1.32× |
| 2 mapped, modified | off | status | 15.10 ± 0.58* | 1110.45 ± 10.72 | 1241.38 ± 20.91 | +130.93 | 1.12× |
| 2 mapped, modified | off | diff | 12.47 ± 0.47* | 1125.31 ± 14.18 | 1243.48 ± 22.96 | +118.17 | 1.11× |
| 2 mapped, modified | valid | status | 13.89 ± 0.74* | 1125.84 ± 8.02 | 1209.81 ± 12.46 | +83.97 | 1.07× |
| 2 mapped, modified | valid | diff | 11.30 ± 0.58* | 1138.41 ± 20.01 | 1228.11 ± 10.73 | +89.71 | 1.08× |

File sizes and separate diagnostic work for each timing row:

| State | Fsmonitor | Command | Modified files (MiB) | Selective unique files (MiB) | Selective requested MiB | Always unique files (MiB) | Always requested MiB |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| **Unmapped (nominal expected)** | off | status | 0 (0) | 0 (0) | 0 | 5002 (205.8203) | 205.8203 |
| **Unmapped (nominal expected)** | off | diff | 0 (0) | 0 (0) | 0 | 5002 (205.8203) | 205.8203 |
| **Unmapped (nominal expected)** | valid | status | 0 (0) | 0 (0) | 0 | 5002 (205.8203) | 205.8203 |
| **Unmapped (nominal expected)** | valid | diff | 0 (0) | 0 (0) | 0 | 5002 (205.8203) | 205.8203 |
| 1 mapped, unchanged | off | status | 0 (0) | 1 (100) | 100 | 5002 (205.8203) | 205.8203 |
| 1 mapped, unchanged | off | diff | 0 (0) | 1 (100) | 100 | 5002 (205.8203) | 205.8203 |
| 1 mapped, unchanged | valid | status | 0 (0) | 1 (100) | 100 | 5002 (205.8203) | 205.8203 |
| 1 mapped, unchanged | valid | diff | 0 (0) | 1 (100) | 100 | 5002 (205.8203) | 205.8203 |
| 1 mapped, modified | off | status | 1 (100) | 1 (100) | 300 | 5002 (205.8203) | 405.8203 |
| 1 mapped, modified | off | diff | 1 (100) | 1 (100) | 400 | 5002 (205.8203) | 505.8203 |
| 1 mapped, modified | valid | status | 1 (100) | 1 (100) | 300 | 5002 (205.8203) | 405.8203 |
| 1 mapped, modified | valid | diff | 1 (100) | 1 (100) | 400 | 5002 (205.8203) | 505.8203 |
| 2 mapped, unchanged | off | status | 0 (0) | 2 (200) | 200 | 5002 (205.8203) | 205.8203 |
| 2 mapped, unchanged | off | diff | 0 (0) | 2 (200) | 200 | 5002 (205.8203) | 205.8203 |
| 2 mapped, unchanged | valid | status | 0 (0) | 2 (200) | 200 | 5002 (205.8203) | 205.8203 |
| 2 mapped, unchanged | valid | diff | 0 (0) | 2 (200) | 200 | 5002 (205.8203) | 205.8203 |
| 2 mapped, modified | off | status | 2 (200) | 2 (200) | 600 | 5002 (205.8203) | 605.8203 |
| 2 mapped, modified | off | diff | 2 (200) | 2 (200) | 800 | 5002 (205.8203) | 805.8203 |
| 2 mapped, modified | valid | status | 2 (200) | 2 (200) | 600 | 5002 (205.8203) | 605.8203 |
| 2 mapped, modified | valid | diff | 2 (200) | 2 (200) | 800 | 5002 (205.8203) | 805.8203 |

## Separate diagnostic processes

These counters were collected in a separate untimed process for every row. `read`/`pread` count returned worktree content bytes; `mmap` counts successful requested worktree mapping lengths, **not physical I/O or proven bytes touched**. Fixture-path filtering excludes the index, object database and libraries. The shim passed a known 16,384-byte mmap/one-query control. The full counters are in [diagnostics.tsv](diagnostics.tsv).

| Fixture | State | Fsmonitor | Variant | getattrlist calls | read + pread bytes | mmap requested bytes |
| --- | --- | --- | --- | ---: | ---: | ---: |
| small | unmapped | valid | baseline | 0 | 0 | 0 |
| small | unmapped | valid | selective | 10,000 | 0 | 0 |
| small | unmapped | valid | always | 0 | 6,103,040 | 0 |
| one-large | unmapped | off | baseline | 0 | 0 | 0 |
| one-large | unmapped | off | selective | 1 | 0 | 0 |
| one-large | unmapped | off | always | 0 | 0 | 104,857,600 |
| one-large | one-mapped-unchanged | off | baseline | 0 | 0 | 0 |
| one-large | one-mapped-unchanged | off | selective | 1 | 0 | 104,857,600 |
| one-large | one-mapped-unchanged | off | always | 0 | 0 | 104,857,600 |
| ten-large | unmapped | off | baseline | 0 | 0 | 0 |
| ten-large | unmapped | off | selective | 10 | 0 | 0 |
| ten-large | unmapped | off | always | 0 | 0 | 1,048,576,000 |
| ten-large | one-mapped-unchanged | off | baseline | 0 | 0 | 0 |
| ten-large | one-mapped-unchanged | off | selective | 10 | 0 | 104,857,600 |
| ten-large | one-mapped-unchanged | off | always | 0 | 0 | 1,048,576,000 |
| ten-large | many-mapped-unchanged | off | baseline | 0 | 0 | 0 |
| ten-large | many-mapped-unchanged | off | selective | 10 | 0 | 1,048,576,000 |
| ten-large | many-mapped-unchanged | off | always | 0 | 0 | 1,048,576,000 |
| ten-large | many-mapped-modified | off | baseline | 0 | 0 | 0 |
| ten-large | many-mapped-modified | off | selective | 30 | 0 | 3,145,728,000 |
| ten-large | many-mapped-modified | off | always | 0 | 0 | 3,145,728,000 |

The selective code can query an entry more than once, especially with fsmonitor-valid fast paths. The always comparator makes zero generation queries but invokes existing content comparison on all eligible entries. Mapped modified commands may compare contents repeatedly within a command; the diagnostic totals describe that implementation rather than a single-read ideal.

## Scope and limits

The index was captured independently for fsmonitor disabled and persisted-valid hook modes and kept byte-identical for all variants and every sample in a measurement group. Every sample is a new Git process, so no prior in-process `CE_UPTODATE` flag survives. `GIT_OPTIONAL_LOCKS=0` prevents optional status refresh writes; hashes assert the snapshots stayed frozen. Metadata checks warm the stat cache immediately before each sample and run outside the clock.

Writable shared mappings are native and their FDs close before readiness. Writes are acknowledged and the mapper waits idle while Git runs. Device, inode, size, nanosecond mtime and ctime are asserted unchanged before and after every sample. The final dirty unmap can update ctime, so the harness recaptures a fresh non-racy index between mapping groups; no stale index is carried across that lifecycle transition. Each row records its index epoch and hash. The one-large fixture has one mapped file; “many” is omitted there.

These are single-machine warm-cache results on ordinary local files, with compressible contents and no filters in timed fixtures. They do not model cold-cache storage, network filesystems, simultaneous writers or an atomic snapshot. Process startup, hook invocation and output capture are included. No cache purging, privileged tracing, elevated benchmark execution, remote compute, global configuration changes or security changes were used.

The standalone [combined-metadata API proof](../native-proof/combined-metadata.c) and [API microbenchmark](metadata-api.jsonl) are separate from these three Git variants. One public `getattrlist` can return the regular-file stat fields used by this probe plus write generation. Thus these measurements do not establish that an extra syscall is unavoidable. No combined-call Git variant is implemented: symlink/directory/error/fallback and transient-validity integration still need review. Fsmonitor-valid paths formerly made **no stat call**; combining metadata only removes duplication on paths already requiring stat, so it cannot remove all added fsmonitor cost.


## Standalone metadata API microbenchmark

Separate native process, no Git integration. Each sample is the mean of 10,000 warm metadata lookups of the same 16 KiB file; cells show median ± MAD across nine counterbalanced batches after one warmup batch per operation. Units are microseconds per lookup. The one combined query returns regular-file metadata plus write generation; lstat alone does not supply write generation.

| State | lstat only | lstat + generation query | Combined query | Combined / split |
| --- | ---: | ---: | ---: | ---: |
| unmapped | 1.720 ± 0.007 | 3.654 ± 0.029 | 1.939 ± 0.008 | 0.53× |
| shared-fd-closed | 1.724 ± 0.011 | 3.651 ± 0.040 | 1.972 ± 0.029 | 0.54× |
| shared-modified | 1.785 ± 0.039 | 3.740 ± 0.072 | 1.997 ± 0.048 | 0.53× |

Returned fields and nanosecond timestamps matched lstat in untimed validation for all three states. Unmapped write generation was nonzero; both shared-mapped states returned zero. This API-only result does not predict integrated Git speedups, particularly where fsmonitor previously skipped stat entirely.
