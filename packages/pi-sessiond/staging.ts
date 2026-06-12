// Stages a config template (settings.json, bash-confirm.json) from the
// Nix store into the daemon's writable agent dir.
//
// NOT a plain copyFileSync: that preserves the source's mode, and store
// templates are 0444 — the first daemon start then leaves a read-only
// dest that every later restart fails to overwrite (EACCES → crash
// loop). Remove any residue (including 0444 files older builds left
// behind), then write fresh with an owner-writable mode.
import { readFileSync, rmSync, writeFileSync } from "node:fs";

export function stageFile(src: string, dest: string): void {
  rmSync(dest, { force: true });
  writeFileSync(dest, readFileSync(src), { mode: 0o600 });
}
