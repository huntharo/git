---
name: pwrgit-release
description: Prepare, tag, and verify a custom Git runtime prerelease from huntharo/git for PwrAgent and PwrGit. Use for the downstream source freeze, protected macOS signing, or published runtime verification. Upstream Git releases and app releases have separate workflows.
---

# PwrGit runtime release

Use the fork's `pwrgit` packaging branch. Read the [runtime contract](../../../contrib/pwrgit-runtime/README.adoc), [build lock](../../../contrib/pwrgit-runtime/build-lock.json), and [release workflow](../../../.github/workflows/pwrgit-runtime.yml) for the current source, platform matrix, and gates.

## Prepare the source and recipes

- Verify the worktree, publishing remote (`huntharo/git`), current `pwrgit` tip, and existing remote tags and releases. Preserve unrelated changes. Keep upstream submission branches and PRs separate and intact. Use a packaging PR targeting `pwrgit` when the recipes or lock need changing.
- The release has two independently pinned commits. `source.revision` in the build lock is the exact Git source SHA. `source.ref` must peel to that SHA, and `source.pull_requests` must describe what is actually included. Verify ancestry or patch equivalence against the intended feature revisions. For a new source freeze, publish an annotated `pwrgit-source/<version>` tag at the source commit before candidate CI runs. A recipe-only release can reuse the existing source ref.
- The release tag `v<version>` points at the **packaging commit** on `pwrgit`. For the development line, the lock uses `<major.minor.patch>-dev-pwrgit.<N>`; choose an unused version that accurately describes the source. Check both remote tag namespaces and GitHub releases, including drafts and previous failed attempts. An existing tag calls for inspection of its target and run.
- Use relevant existing evidence. For recipe changes, run the Python tests and shared consumer tests below. Before tagging, review the release workflow's platform checks on the packaging PR and verify the merged tree matches the tested tree. When a local candidate is requested, use the build, relocation and smoke commands in the runtime contract. Local ad-hoc builds and unsigned CI candidates are distinct from the released payload.

```sh
python3 -m unittest discover -s contrib/pwrgit-runtime -p test_runtime.py
node --test contrib/pwrgit-runtime/stage-runtime.test.mjs
```

## Tag and follow the release

A request to make the release authorizes the new tag push and workflow publication. A request to prepare or inspect a release ends at the reviewable candidate unless publication is also authorized.

- Create an annotated `v<version>` tag at the verified packaging commit. Push its explicit `refs/tags/...` ref to the fork. Keep existing source and release tags and published assets immutable.
- A matching release tag push starts the build, signing and publication workflow. A branch build or ordinary manual dispatch supplies candidate evidence. Dispatch with `sign=true` is supported on a matching release tag and remains subject to the same gates.
- Locate the run by the exact tag and packaging SHA. Record the run URL. Use a durable run watch if available, or bounded status checks. When the protected `apple-signing` deployment waits for required human review, share the run and candidate evidence with the operator for approval.
- On failure, inspect the first actionable job error. A transient service failure such as Ubuntu snapshot `502/503` warrants one failed-job retry after the run is terminal, using the same tag and pinned inputs. Stop if it repeats or needs operator action. A source or recipe fix needs a new commit and unused version. Keep the protected signing and digest gates in place.
- The publisher creates a draft, verifies the exact asset set and GitHub digests, then publishes by release ID. If an incomplete draft blocks readiness, inspect that draft and the failed run. Ordinary retry does not remove it. Any cleanup or recovery must be separately authorized and scoped to the confirmed draft.

## Verify publication and hand off

- Require a successful release run and a published, non-draft prerelease for the exact tag. Download `runtime-manifest.json` and `SHA256SUMS` to a scratch directory. Cross-check the release asset set and GitHub asset digests against the checksum file. Verify the bytes of the downloaded catalog and platform archives. Read [the asset assembler](../../../contrib/pwrgit-runtime/prepare-release.py) for the current asset contract.
- Check the catalog's version, source SHA and PR set, build run, shared consumer SHA-256, and versioned archive URLs and hashes. The current matrix is macOS universal plus Linux x64 and arm64. Check each extracted `pwrgit-build.json` against both pinned commits, match the sealed inventory digest, and verify the file set. Use the release's corresponding [payload verifier](../../../contrib/pwrgit-runtime/verify.py) on the matching platform. On macOS, use `--require-signed` and check the included Apple Accepted receipt against the build's notarization ID. Report CI signing or execution evidence separately from independent checks actually run. A deployment target alone does not establish minimum-OS execution.
- When consumer updates are requested, hand off the verified release URL, catalog, checksums, source SHA and `consumer_sha256` to the owners of PwrAgent and PwrGit. Their bundled pins live in `apps/desktop/custom-git-runtime.json`. Keep `stage-runtime.mjs` aligned with the catalog's consumer pin. Linux currently ships `ssl/cacert.pem`, `LICENSE.ca-bundle` and `NOTICE.ca-bundle` at those archive-relative paths. The app packaging flow must preserve the same signed universal bytes in both architecture legs and verify the installed inventory. Each enclosing app has its own signing and notarization.
- Report the version, source and packaging SHAs, run and release links, signing and checksum results, and any remaining app handoffs or verification. Treat local installs and runtime selections as separate actions.
