# Experimental macOS validation comparison — do not merge

This dev-only harness compares three local optimized Git executables on identical,
ordinary, disposable fixtures. It belongs exclusively to the experimental draft
PR, based on PR #14. It is not a recommended production patch, is not for upstream,
and does not add a supported Git configuration or benchmark target.

- **baseline:** upstream `fb255012acbcbe81189cb8014da0280b09c66ecc`.
- **selective:** PR #14 `8e6340c0b705182db2840f99343f327373034411`.
- **always:** comparator `4be2dcea27b9af28b4a8d9ceb14b412ad0e7fad5`.
  Only the macOS reliability hook returns `1` without `getattrlist`.
  PR #14's fsmonitor guards, explicit assume-unchanged/skip-worktree opt-outs,
  content/filter route, and other-platform fallback remain in place.

[Timing/workload summary](results/SUMMARY.md),
[measured tables and limitations](results/RESULTS.md), [raw samples](results/results.json),
[build records](results/builds.json), and [diagnostic counters](results/diagnostics.tsv)
are versioned with this experiment. Earlier parent-worktree timings are not mixed
into these results. Binary source SHAs refer to the comparator commit before this
harness/results commit; later changes are tests and dev-only artifacts.

## Reproduce

Use a **dedicated isolated checkout of this experimental branch**, with no local
source edits, `config.mak`, or `config.mak.autogen`. `build.sh` switches only that
checkout between the exact three SHAs, cleans between sequential builds, records
flags/compiler/version/hashes, saves executables under ignored `local/`, and
restores its original branch. Stop other heavy local workloads first. No root,
cache purging, global Git configuration, security changes, or remote compute is
needed. Python 3.9+ and Apple's compiler/SDK are required. These dev-only
probes deliberately use the standalone macOS SDK and modern Python timing APIs;
they are not linked into Git or held out as portable upstream utilities.

```sh
contrib/macos-stat-benchmark/build.sh
cc -O2 -std=c99 -Wall -Wextra -Werror \
  contrib/macos-stat-benchmark/mapper.c \
  -o contrib/macos-stat-benchmark/local/mapper
cc -O2 -std=c99 -Wall -Wextra -Werror -dynamiclib \
  contrib/macos-stat-benchmark/count-io.c \
  -o contrib/macos-stat-benchmark/local/count-io.dylib

# Quick scaled-fixture smoke check; these are not the full-size results.
python3 contrib/macos-stat-benchmark/bench.py \
  --git baseline="$PWD/contrib/macos-stat-benchmark/local/baseline/git" \
  --git selective="$PWD/contrib/macos-stat-benchmark/local/selective/git" \
  --git always="$PWD/contrib/macos-stat-benchmark/local/always/git" \
  --builds contrib/macos-stat-benchmark/local/builds.json \
  --profile smoke --warmups 1 --repetitions 3 \
  --diagnostic-shim contrib/macos-stat-benchmark/local/count-io.dylib \
  --output contrib/macos-stat-benchmark/local/smoke.json

# Full: explicitly opt in; two warmups and nine measured samples per variant/command/state/mode.
python3 contrib/macos-stat-benchmark/bench.py \
  --git baseline="$PWD/contrib/macos-stat-benchmark/local/baseline/git" \
  --git selective="$PWD/contrib/macos-stat-benchmark/local/selective/git" \
  --git always="$PWD/contrib/macos-stat-benchmark/local/always/git" \
  --builds contrib/macos-stat-benchmark/local/builds.json \
  --diagnostic-shim contrib/macos-stat-benchmark/local/count-io.dylib \
  --profile full --output contrib/macos-stat-benchmark/local/results.json
python3 contrib/macos-stat-benchmark/report.py \
  contrib/macos-stat-benchmark/local/results.json \
  --output contrib/macos-stat-benchmark/local/RESULTS.md
```

Labels can be arbitrary with `--reference LABEL` naming the fixture builder and
reference whose missed mapped writes are recorded rather than aborting. Supply
exactly three `--git LABEL=/absolute/path` arguments. Every other binary must
produce the expected exact output. The checked-in report renderer uses the labels
above. The original run built each binary manually with the same commands now
encoded in `build.sh`; the build logs are preserved. The baseline `GIT-CFLAGS`
file was unavailable at metadata capture (recorded as null), but its exact make
command, compiler, executable build options/hash and full build log are retained.
The selective and comparator records also preserve expanded `GIT-CFLAGS`.

**Unmapped is the nominal expected case** in the tables. Mapped cases deliberately
exercise the conservative content-comparison path. Each timing row also has a
workload row showing modified file count/size, unique file counts/sizes selected
for validation, and measured content-request totals separately for Selective and
Always. [workloads.tsv](results/workloads.tsv) preserves exact byte sums and the
separate read/pread/mmap counters. The original raw measurements remain unchanged;
these workload tables are derived by joining their fixture/mapping metadata and
their existing separate diagnostic counters. Future harness rows additionally
record explicit mapped paths, modified counts/file sizes, and case role.

Unique sizes come from the controlled mapped set for Selective and all fixture
files for Always. They do not include repeated comparisons. Total requests add
returned read/pread bytes and successful requested mmap lengths, including repeats;
**mmap lengths do not establish bytes touched/hashed or physical I/O**. Ten-large
“many unchanged” and “many modified” use the same ten 100 MiB paths. Unchanged has
zero modified files and 1,000 MiB of requests per variant. Modified changes byte
zero of all ten, and status requests 3,000 MiB per variant through repeated content
comparisons. The unique file size is still 1,000 MiB, and both variants take the
same content path, explaining the close times. Diff requests 4,000 MiB in that
modified case; the additional mapping extent need not be fully touched.

The default profile is small (`smoke`); full-size data requires `--profile full`.
Fixture knobs: `--fixtures small one-large ten-large mixed` selects a subset;
`--profile smoke` scales to 80 small files and 1 MiB per large file. Full defaults
are 5,000 small files (64 × 16 KiB, 4,936 × 1 KiB), 1 × 100 MiB,
10 × 100 MiB, and 5,000 small + 2 × 100 MiB. **100 MiB = 104,857,600 bytes**, not
100,000,000 bytes. Fixtures run serially, with about 1 GiB peak worktree content,
compressed Git objects and local build products. Every content byte is explicitly
written and fsynced; repeated ASCII `A` is deterministic and highly compressible.
The harness uses no sparse/clone/reflink/hardlink creation. Temporary fixtures are
deleted after each fixture, including ordinary Python exception cleanup.

## Measurement and correctness

`perf_counter_ns` surrounds a fresh `subprocess.run` with captured output. Timing
includes Git startup, hook invocation and output capture; output validation,
metadata/index hashing, fixture setup and diagnostics are outside the clock.
Commands are `status --porcelain --untracked-files=no` and `diff --name-only` so
large patches are never formatted. All workloads are warm cache, with no cold-cache
claim. Metadata assertions before each sample deliberately warm the stat cache.

The seed is recorded. Randomized groups of three rotated orders give each variant
each ordinal position equally across nine measured rounds. Raw measured and
warmup samples, min/max, quartiles, MAD, exact stdout and correctness are preserved.
All variants use the same fixture and the exact same per-mode index bytes.
Fsmonitor disabled and a deterministic v2 hook with persisted-valid bits are
separate modes; `ls-files -f` verifies every valid bit during setup.

Frozen `GIT_INDEX_FILE` snapshots plus `GIT_OPTIONAL_LOCKS=0` prevent status refresh
from changing later samples. Every command is a new process so old in-process
`CE_UPTODATE` flags cannot leak across samples. The baseline builds the fixture
and snapshots before mapping. The harness hashes snapshots and checks all files'
device/inode/size/nanosecond mtime/ctime before and after every sample. Index times
are asserted later than both file timestamps by whole seconds, avoiding racy stat
comparisons. After the last unmap of a dirty mapping, ctime can advance; the
harness waits for a non-racy interval and recaptures the baseline between mapping
groups. Each row records that index epoch/hash. It never refreshes the frozen
index inside a measurement group.

`mapper.c` uses native writable `MAP_SHARED`, closes FDs before readiness, and
requires public generation zero for each mapped file. Initial unmapped generation
is also checked nonzero. A write to byte zero is acknowledged before the mapper
blocks waiting for its next command; it stays quiescent during Git. The harness
reads the written byte and verifies unchanged metadata. One and many mapped
unchanged and modified cases are covered; “many” means 64 selected small files,
all 10 large files, or both large files in mixed. The single-large fixture has no
redundant many case. Changed bytes are restored through the mapping before unmap.
The baseline may silently miss these writes: every such sample is marked incorrect
and is not presented as an equally-correct faster answer. Concurrent writers and
atomic snapshots are outside this experiment's guarantees.

`count-io.c` is an optional unprivileged dyld interposer. A separate process for
EACH row/variant counts fixture `getattrlist` calls, returned `read`/`pread` bytes,
and successfully requested `mmap` lengths. It excludes the index, object database
and libraries. Mapping lengths are **not physical I/O or proven bytes touched**.
The log itself proves loading; known one-query/16,384-byte-mapping and
128-byte read/64-byte pread controls are
preserved. Without `--diagnostic-shim`, timings still run and no measured syscall
or content-byte count should be claimed. No trace overhead enters timed samples.

## Focused tests and combined API evidence

```sh
make -j8 NO_GETTEXT=YesPlease CFLAGS='-O2 -g' all t/helper/test-tool
(cd t && prove -v t0010-racy-git.sh t0011-mmap-stat.sh \
  t2104-update-index-skip-worktree.sh \
  t2106-update-index-assume-unchanged.sh t7519-status-fsmonitor.sh)
```

The five suites pass (68 reported entries: 67 passed, one MINGW-only prerequisite
skip) **with explicit experimental expectations**. The t0011 prerequisite and reliable-unmapped expectation now
expect unreliable (`1`) so the 16 correctness cases still execute. Four t7519
combinations previously expected a lying fsmonitor hook to hide ordinary tracked
writes. This comparator detects them, so their Mac expectation now requires
tracked modifications to appear while preserving hook and untracked-cache checks.
The original unadapted t7519 run had those four failures and is preserved in
[focused-original.log](results/focused-original.log); the adapted result is
[focused-adapted.log](results/focused-adapted.log). This is not a claim that the
unmodified fsmonitor suite passed, nor a full-suite green claim. Sandbox warnings
from sysctl/chainlint and the MINGW-only prerequisite skip are retained.

The parent supplied a public combined-`getattrlist` proof; it was copied read-only
under [native-proof/](native-proof/) and rerun here. It requests regular-file stat
fields plus write generation in **one call**, compares them with `lstat`, and
records shared/private mappings and stores with closed FDs. Both original and
fresh eight-snapshot outputs are retained. `st_gen` is a different generation field;
this experiment adds no spare-field/TLS caching or production integration.

The standalone API microbenchmark is separate from Git timings:

```sh
cc -O2 -std=c99 -Wall -Wextra -Werror \
  contrib/macos-stat-benchmark/metadata-bench.c \
  -o contrib/macos-stat-benchmark/local/metadata-bench
contrib/macos-stat-benchmark/local/metadata-bench \
  "$PWD/contrib/macos-stat-benchmark/local/api-fixture" \
  >contrib/macos-stat-benchmark/local/metadata-api.jsonl
```

It compares `lstat`, `lstat + current-generation getattrlist`, and one combined
`getattrlist` on one repeatedly queried 16 KiB file in 10,000-call batches: one warmup plus nine counterbalanced rounds,
for unmapped, shared closed-FD, and shared modified states. Metadata equivalence
is checked outside timing. Results do not imply an integrated fourth Git variant.
Symlink/directory/error/fallback and transient-validity semantics need audit.
Fsmonitor-valid paths previously made **no stat call**: combining metadata can
remove duplication on paths already requiring stat, but cannot erase all added
fsmonitor-validation cost. These three variants measure the current selective
implementation; a separate query is not fundamentally proven unavoidable.

The stronger diagnostic control can be rerun separately (never during timings):

```sh
cc -O2 -std=c99 -Wall -Wextra -Werror \
  contrib/macos-stat-benchmark/count-control.c \
  -o contrib/macos-stat-benchmark/local/count-control
python3 - <<'PYCONTROL'
from pathlib import Path
import json, os, subprocess
root = Path('contrib/macos-stat-benchmark').resolve()
fixture = root / 'local/control/files/plain'
fixture.parent.mkdir(parents=True, exist_ok=True)
fixture.write_bytes(b'A' * 16384)
log = root / 'local/count-control.jsonl'
log.unlink(missing_ok=True)
env = dict(os.environ, DYLD_INSERT_LIBRARIES=str(root / 'local/count-io.dylib'),
           BENCH_COUNT_PREFIX=str(fixture.parent) + '/', BENCH_COUNT_OUTPUT=str(log))
subprocess.run([str(root / 'local/count-control'), str(fixture)], env=env, check=True)
row = json.loads(log.read_text())
assert row['getattrlist_calls'] == 1
assert row['read_bytes'] == 128 and row['pread_bytes'] == 64
assert row['mmap_requested_bytes'] == 16384
PYCONTROL
```

`verify-results.py results-directory` independently audits the full run's sample
counts, counterbalanced positions, exact output/correctness, index epochs,
diagnostic coverage, focused test logs, combined proof and microbenchmark batches.
It writes artifact SHA-256 hashes to `audit.json`. The checked-in artifact directory
is already audited; after collecting a new run, copy the corresponding logs and
proof outputs alongside `results.json` before invoking that full artifact audit.
