// spaces-landlock-policy — lower an integration's static policy spec + the
// paths systemd resolves at unit start into a landlockconfig document.
//
// A NixOS *system* module emits one generic `--user` unit per integration, so
// the grantable paths ($STATE_DIRECTORY, $CREDENTIALS_DIRECTORY, any shared
// exchange dir) are not known at build time — they materialise only when the
// unit starts in a specific user's manager. landlockconfig variables are
// in-document Cartesian templating, not env injection, so the policy cannot be
// a static store file either. This CLI bridges the gap: it runs in
// `ExecStartPre`, reads the build-time spec, folds in the now-resolved paths,
// and writes `$RUNTIME_DIRECTORY/landlock.json` for `pi-landlock-exec` to apply.
//
// The emitter itself is `buildLandlockPolicy` (sandbox.ts) — the single source
// for the landlockconfig schema, shared with the per-session sandbox. This file
// only maps the integration's manifest-derived spec onto a SandboxPolicy.

import { buildLandlockPolicy, type SandboxPolicy } from "./sandbox";

// The static, build-time half of an integration's policy (lib.nix emits one
// JSON file per integration). Paths are deliberately absent here — they are
// resolved from the unit's environment at start. `connectPorts` is the
// port-granular TCP egress allowlist (empty ⇒ no netPort rule; the coarse
// AF_INET on/off gate is `RestrictAddressFamilies` on the unit, set from the
// manifest's `network` bool).
export interface IntegrationPolicySpec {
  connectPorts?: number[];
  abi?: number;
  scope?: ("signal" | "abstract_unix_socket")[];
  // Forward-compat static grants; default none.
  roDirs?: string[];
  roFiles?: string[];
  rwDirs?: string[];
  // Manifest `extraPaths`: dirs granted beyond the implicit StateDir/cred surface
  // (ro → read set, rw → write set). Sources may carry %t/%h; default none.
  extraPaths?: IntegrationExtraPath[];
}

// One manifest-declared extra grant: an absolute path plus its access mode.
// `source` may embed systemd %t/%h specifiers, resolved at unit start by the
// CLI (see expandSpecifiers) — never at build time.
export interface IntegrationExtraPath {
  source: string;
  mode: "ro" | "rw";
}

// The paths systemd hands the unit at start.
export interface ResolvedPaths {
  stateDirs: string[]; // $STATE_DIRECTORY (rw): the server's own scratch/state
  credDirs: string[]; // $CREDENTIALS_DIRECTORY (ro): decrypted secrets mount
  sharedDirs?: string[]; // per-pair file-exchange dirs (rw); set in step 6
  runtimeDir?: string; // $XDG_RUNTIME_DIR, expands %t in extraPaths sources
  homeDir?: string; // $HOME, expands %h in extraPaths sources
}

// Resolve systemd %t/%h specifiers embedded in an `extraPaths` source. lib.nix
// bakes the policy spec into a store file, so systemd expands specifiers in the
// ExecStartPre `--out` ARG (a unit directive value) but NOT inside the spec
// file's CONTENTS — this CLI resolves them itself from the unit environment
// ($XDG_RUNTIME_DIR / $HOME). An unset target fails closed (throws) rather than
// granting a half-resolved path.
function expandSpecifiers(
  source: string,
  runtimeDir: string | undefined,
  homeDir: string | undefined,
): string {
  // systemd's `%%` literal-percent escape is not supported here; sources are
  // lib.nix-authored and never contain a literal percent.
  return source.replace(/%[th]/g, (m) => {
    const [value, varName] =
      m === "%t" ? [runtimeDir, "XDG_RUNTIME_DIR"] : [homeDir, "HOME"];
    if (!value)
      throw new Error(
        `spaces-landlock-policy: cannot expand ${m} in "${source}": ${varName} is unset`,
      );
    return value;
  });
}

// Compose the static spec + the unit-start-resolved paths into a SandboxPolicy.
// Pure. The integration's writable surface is exactly its StateDirectory (plus
// any shared exchange dir); its only readable secret surface is the credentials
// mount; egress is the declared TCP ports. Everything else is denied by
// buildLandlockPolicy's deny-by-default (which folds in the /nix/store rx +
// /etc DNS/TLS + /dev node defaults every runtime needs).
export function lowerIntegrationPolicy(
  spec: IntegrationPolicySpec,
  resolved: ResolvedPaths,
): SandboxPolicy {
  const expand = (source: string): string =>
    expandSpecifiers(source, resolved.runtimeDir, resolved.homeDir);
  const extra = spec.extraPaths ?? [];
  for (const e of extra) {
    if (e.mode !== "ro" && e.mode !== "rw")
      throw new Error(
        `spaces-landlock-policy: extraPaths entry "${e.source}" has invalid mode ${JSON.stringify(e.mode)} (expected "ro" or "rw")`,
      );
  }
  const extraRw = extra
    .filter((e) => e.mode === "rw")
    .map((e) => expand(e.source));
  const extraRo = extra
    .filter((e) => e.mode === "ro")
    .map((e) => expand(e.source));
  return {
    rwDirs: [
      ...resolved.stateDirs,
      ...(resolved.sharedDirs ?? []),
      ...(spec.rwDirs ?? []),
      ...extraRw,
    ],
    roDirs: [...resolved.credDirs, ...(spec.roDirs ?? []), ...extraRo],
    roFiles: spec.roFiles ?? [],
    connectPorts: spec.connectPorts ?? [],
    abi: spec.abi,
    scope: spec.scope,
  };
}

// Read the resolved paths from the unit's environment. systemd sets
// $STATE_DIRECTORY / $CREDENTIALS_DIRECTORY as ':'-separated lists when more
// than one is configured; split defensively.
export function resolveFromEnv(
  env: Record<string, string | undefined>,
): ResolvedPaths {
  const list = (v?: string): string[] =>
    v ? v.split(":").filter(Boolean) : [];
  return {
    stateDirs: list(env.STATE_DIRECTORY),
    credDirs: list(env.CREDENTIALS_DIRECTORY),
    sharedDirs: list(env.SPACES_INTEGRATION_SHARED_DIR),
    runtimeDir: env.XDG_RUNTIME_DIR,
    homeDir: env.HOME,
  };
}

function die(msg: string): never {
  console.error(`spaces-landlock-policy: ${msg}`);
  process.exit(1);
}

function parseArgs(argv: string[]): { specPath: string; outPath: string } {
  let specPath: string | undefined;
  let outPath: string | undefined;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--spec") specPath = argv[++i];
    else if (a === "--out") outPath = argv[++i];
    else
      die(
        `unexpected argument ${a}; usage: spaces-landlock-policy --spec <spec.json> [--out <policy.json>]`,
      );
  }
  if (!specPath) die("--spec <spec.json> is required");
  // Default the output to the unit's RuntimeDirectory, where pi-landlock-exec
  // reads it (ExecStart=--json %t/<dir>/landlock.json).
  if (!outPath) {
    const rt = process.env.RUNTIME_DIRECTORY?.split(":").filter(Boolean)[0];
    if (!rt)
      die("--out <policy.json> is required when $RUNTIME_DIRECTORY is unset");
    outPath = `${rt}/landlock.json`;
  }
  return { specPath, outPath };
}

async function main(): Promise<void> {
  const { specPath, outPath } = parseArgs(process.argv.slice(2));
  const spec = (await Bun.file(specPath).json()) as IntegrationPolicySpec;
  const policy = lowerIntegrationPolicy(spec, resolveFromEnv(process.env));
  const doc = buildLandlockPolicy(policy);
  await Bun.write(outPath, `${JSON.stringify(doc, null, 2)}\n`);
}

if (import.meta.main) {
  void main();
}
