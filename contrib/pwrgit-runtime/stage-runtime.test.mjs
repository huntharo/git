import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { chmodSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, renameSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { readRuntimeManifest, stageRuntime, verifyRuntime as verifyRuntimeRaw } from "./stage-runtime.mjs";
const verifyRuntime = (root, pin) => verifyRuntimeRaw(root, pin, { probe: false });

const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
const source = "d5db8771ce659822bd9fbb0911b600de1339fea3";
const version = "2.56.0-dev-pwrgit.1";

function fixture(t) {
  const temp = mkdtempSync(join(tmpdir(), "pwrgit-stage-test-"));
  t.after(() => rmSync(temp, { recursive: true, force: true }));
  const root = join(temp, "runtime");
  mkdirSync(root);
  const bytes = JSON.stringify({ version, source_revision: source, primary_sha1: "SHA1_DC" });
  writeFileSync(join(root, "pwrgit-build.json"), bytes, { mode: 0o644 });
  chmodSync(join(root, "pwrgit-build.json"), 0o644);
  const inventory = JSON.stringify({ "pwrgit-build.json": { sha256: hash(bytes), mode: 0o644 } });
  writeFileSync(join(root, "runtime-files.json"), inventory);
  const pin = { manifest: { version, source_revision: source }, key: "linux-x64", asset: { inventory_sha256: hash(inventory) } };
  return { temp, root, pin };
}

test("verifies relocated sealed files and rejects content/mode/file-set changes", (t) => {
  const { root, pin } = fixture(t);
  assert.equal(verifyRuntime(root, pin).version, version);
  chmodSync(join(root, "pwrgit-build.json"), 0o744);
  assert.throws(() => verifyRuntime(root, pin), /mode or link changed/);
  chmodSync(join(root, "pwrgit-build.json"), 0o644);
  writeFileSync(join(root, "extra"), "unapproved");
  assert.throws(() => verifyRuntime(root, pin), /file set changed/);
  rmSync(join(root, "extra"));
  writeFileSync(join(root, "pwrgit-build.json"), "changed");
  assert.throws(() => verifyRuntime(root, pin), /bytes, mode or link changed/);
});

test("rejects escaped symlinks and changed inventory", (t) => {
  const { root, pin, temp } = fixture(t);
  writeFileSync(join(temp, "outside"), "outside");
  symlinkSync("../outside", join(root, "escape"));
  assert.throws(() => verifyRuntime(root, pin), /symlink escapes/);
  rmSync(join(root, "escape"));
  writeFileSync(join(root, "runtime-files.json"), "{}");
  assert.throws(() => verifyRuntime(root, pin), /inventory checksum/);
});

test("manifest rejects mutable URLs, missing pins, and unnotarized macOS payloads", (t) => {
  const { temp } = fixture(t);
  const path = join(temp, "manifest.json");
  const asset = { sha256: "a".repeat(64), inventory_sha256: "b".repeat(64),
    url: `https://github.com/huntharo/git/releases/download/v${version}/runtime.tar.gz`,
    team_id: "T44CNHC4UH", notarized: true };
  const m = { schema: 1, version, source_revision: source,
    consumer_sha256: hash(readFileSync(new URL("./stage-runtime.mjs", import.meta.url))),
    assets: { "darwin-universal": asset } };
  writeFileSync(path, JSON.stringify(m));
  assert.equal(readRuntimeManifest(path, "darwin", "arm64").key, "darwin-universal");
  asset.notarized = false;
  writeFileSync(path, JSON.stringify(m));
  assert.throws(() => readRuntimeManifest(path, "darwin", "x64"), /notarized/);
  asset.notarized = true;
  asset.url = "https://github.com/huntharo/git/releases/latest/download/runtime.tar.gz";
  writeFileSync(path, JSON.stringify(m));
  assert.throws(() => readRuntimeManifest(path, "darwin", "arm64"), /immutable/);
  delete asset.sha256;
  writeFileSync(path, JSON.stringify(m));
  assert.throws(() => readRuntimeManifest(path, "darwin", "arm64"), /incomplete/);
});

test("stages a cached archive under umask 077 with its sealed modes intact", async (t) => {
  const { temp, root } = fixture(t);
  const metadata = join(root, "pwrgit-build.json");
  writeFileSync(metadata, JSON.stringify({ ...JSON.parse(readFileSync(metadata)), lfs_version: "3.7.1" }));
  mkdirSync(join(root, "bin"));
  chmodSync(join(root, "bin"), 0o755);
  const git = join(root, "bin", "git");
  writeFileSync(git, `#!/bin/sh
case "$*" in
  '--version') echo 'git version ${version}' ;;
  'version --build-options') printf '%s\\n' 'SHA-1: SHA1_DC' 'built from commit: ${source}' ;;
  '--exec-path') printf '%s/libexec/git-core\\n' "\${0%/bin/git}" ;;
  'lfs version') echo 'git-lfs/3.7.1 test' ;;
  *) exit 1 ;;
esac
`);
  chmodSync(git, 0o755);
  const inventory = JSON.stringify({
    "bin/git": { sha256: hash(readFileSync(git)), mode: 0o755 },
    "pwrgit-build.json": { sha256: hash(readFileSync(metadata)), mode: 0o644 },
  });
  writeFileSync(join(root, "runtime-files.json"), inventory);
  const cache = join(temp, "explicit-cache");
  mkdirSync(cache);
  const archive = join(temp, "fixture.tar.gz");
  // runtime.py's package() archives the children without a root directory entry.
  execFileSync("tar", ["-czf", archive, "-C", root, ...readdirSync(root)]);
  const digest = hash(readFileSync(archive));
  renameSync(archive, join(cache, `${digest}.tar.gz`));

  const manifestPath = join(temp, "manifest.json");
  writeFileSync(manifestPath, JSON.stringify({
    schema: 1, version, source_revision: source,
    consumer_sha256: hash(readFileSync(new URL("./stage-runtime.mjs", import.meta.url))),
    assets: { "linux-x64": { sha256: digest, inventory_sha256: hash(inventory),
      url: `https://github.com/huntharo/git/releases/download/v${version}/runtime.tar.gz` } },
  }));
  t.mock.method(globalThis, "fetch", () => assert.fail("Expected reuse of explicit cache"));
  const output = join(temp, "staged");
  const oldUmask = process.umask(0o077);
  try {
    await stageRuntime({ manifestPath, platform: "linux", arch: "x64", output, cache });
  } finally {
    process.umask(oldUmask);
  }
  assert.equal(statSync(output).mode & 0o777, 0o755);
  assert.equal(statSync(join(output, "bin")).mode & 0o777, 0o755);
  assert.equal(statSync(join(output, "pwrgit-build.json")).mode & 0o777, 0o644);
  assert.equal(statSync(join(output, "bin/git")).mode & 0o777, 0o755);

  await t.test("keeps an existing stage when replacement verification fails", async () => {
    const original = JSON.parse(readFileSync(manifestPath));
    const originalPin = readRuntimeManifest(manifestPath, "linux", "x64");
    const invalid = structuredClone(original);
    invalid.assets["linux-x64"].inventory_sha256 = "a".repeat(64);
    const inode = statSync(output).ino;
    writeFileSync(manifestPath, JSON.stringify(invalid));
    try {
      await assert.rejects(stageRuntime({ manifestPath, platform: "linux", arch: "x64", output, cache }),
        /inventory checksum/);
      assert.equal(statSync(output).ino, inode);
      assert.equal(verifyRuntimeRaw(output, originalPin).version, version);
    } finally {
      writeFileSync(manifestPath, JSON.stringify(original));
    }
  });

  await t.test("atomically replaces a nonempty stage with a verified directory",
    { skip: !["darwin", "linux"].includes(process.platform) }, async () => {
      const inode = statSync(output).ino;
      chmodSync(output, 0o700);

      // Simulate a filesystem without exchange support at the publish boundary.
      const shim = join(temp, "no-exchange");
      mkdirSync(shim);
      writeFileSync(join(shim, "python3"), `#!/bin/sh
test -x "$5/bin/git" || exit 1
echo "directory exchange unavailable" >&2
exit 1
`, { mode: 0o755 });
      const originalPath = process.env.PATH;
      process.env.PATH = shim + ":" + originalPath;
      try {
        await assert.rejects(stageRuntime({ manifestPath, platform: "linux", arch: "x64", output, cache }),
          /directory exchange unavailable/);
      } finally {
        process.env.PATH = originalPath;
      }
      assert.equal(statSync(output).ino, inode);

      const pin = await stageRuntime({ manifestPath, platform: "linux", arch: "x64", output, cache });
      assert.notEqual(statSync(output).ino, inode);
      assert.equal(statSync(output).mode & 0o777, 0o755);
      assert.equal(verifyRuntimeRaw(output, pin).version, version);
    });
});
