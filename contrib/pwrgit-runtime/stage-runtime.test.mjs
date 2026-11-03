import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { readRuntimeManifest, verifyRuntime } from "./stage-runtime.mjs";

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
  const m = { schema: 1, version, source_revision: source, assets: { "darwin-universal": asset } };
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
