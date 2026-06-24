// SPDX-License-Identifier: MIT OR Apache-2.0
//
// pi-landlock-exec — the per-session Landlock launcher for pi-sessiond.
//
// Sits between `systemd-run --user` and `pi` (design §6). It reads one or more
// landlockconfig policy documents (`--json <path>`, repeatable), composes them
// into a single deny-by-default Landlock domain, applies it to the current
// process with `landlock_restrict_self()`, then `exec`s the command after `--`.
//
// The domain is inherited across the exec and every fork+exec the sandboxed
// program performs, and can only ever be narrowed further — so `pi`, `bash`, and
// any tool or self-loaded extension stay confined, and none can loosen it.
//
// This binary is the native pre-exec half of the sandbox: restrict_self() must
// run in the final process *before* exec, which the (Bun) supervisor cannot do
// on behalf of the child. sandbox.ts only emits the policy JSON and the
// systemd-run argv (pure, unit-tested). Ruleset construction is best-effort: on
// an older kernel, unsupported access rights (ABI-4 netPort, ABI-6 scoped)
// silently degrade to a weaker-but-functional FS-only domain rather than failing
// (landlock's `CompatLevel::BestEffort`, the `Ruleset` default).

use std::ffi::OsString;
use std::fs::File;
use std::os::unix::process::CommandExt;
use std::process::Command;

use landlock::RulesetStatus;
use landlockconfig::{Config, OptionalConfig};

/// Exit code for any launcher-side failure (policy/exec). Distinct from a normal
/// program exit; mirrors the shell "command not executable" convention.
const EXIT_FAILURE: i32 = 127;

fn die(msg: impl AsRef<str>) -> ! {
    eprintln!("pi-landlock-exec: {}", msg.as_ref());
    std::process::exit(EXIT_FAILURE);
}

/// The running kernel's highest supported Landlock ABI, or 0 when Landlock is
/// unavailable. `landlock_create_ruleset(NULL, 0, VERSION)` returns the version
/// number (or `-errno`); the crate's own detector is private, so query directly.
fn kernel_landlock_abi() -> i64 {
    const LANDLOCK_CREATE_RULESET_VERSION: libc::c_ulong = 1;
    let ret = unsafe {
        libc::syscall(
            libc::SYS_landlock_create_ruleset,
            std::ptr::null::<libc::c_void>(),
            0usize,
            LANDLOCK_CREATE_RULESET_VERSION,
        )
    };
    if ret < 0 {
        0
    } else {
        ret
    }
}

fn main() {
    // Parse `--json <path>` (repeatable) up to `--`; everything after `--` is the
    // command + argv to exec under the domain. A hand-rolled parser keeps the
    // dependency tree (and the trusted-boundary surface) minimal.
    let mut json_paths: Vec<OsString> = Vec::new();
    let mut command: Vec<OsString> = Vec::new();
    let mut args = std::env::args_os().skip(1);
    while let Some(arg) = args.next() {
        if arg == "--" {
            command.extend(args.by_ref());
            break;
        } else if arg == "--json" || arg == "-j" {
            match args.next() {
                Some(p) => json_paths.push(p),
                None => die("--json requires a path argument"),
            }
        } else {
            die(format!(
                "unexpected argument {:?}; usage: pi-landlock-exec --json <policy> [--json <policy>...] -- <cmd> [args...]",
                arg.to_string_lossy()
            ));
        }
    }

    if json_paths.is_empty() {
        die("at least one --json <policy> is required");
    }
    if command.is_empty() {
        die("no command given after `--`");
    }

    // Compose every policy document into one config. Landlock semantics intersect
    // composed rulesets, so a shared base profile plus a per-session overlay can
    // only ever tighten (design §6).
    let mut full_config: Option<Config> = None;
    for path in &json_paths {
        let file = File::open(path)
            .unwrap_or_else(|e| die(format!("open policy {:?}: {e}", path.to_string_lossy())));
        let config = Config::parse_json(file)
            .unwrap_or_else(|e| die(format!("parse policy {:?}: {e}", path.to_string_lossy())));
        full_config.compose(&config);
    }

    let resolved = full_config
        .expect("json_paths is non-empty, so at least one config composed")
        .resolve()
        .unwrap_or_else(|e| die(format!("resolve policy variables: {e}")));

    let (ruleset, rule_errors) = resolved
        .build_ruleset()
        .unwrap_or_else(|e| die(format!("build ruleset: {e}")));

    // A granted path that does not exist is a policy bug worth surfacing, but not
    // fatal: the rest of the domain still applies (and deny-by-default holds).
    for err in &rule_errors {
        eprintln!("pi-landlock-exec: skipped rule: {err:?}");
    }

    let status = ruleset
        .restrict_self()
        .unwrap_or_else(|e| die(format!("restrict_self: {e}")));

    let abi = kernel_landlock_abi();
    match status.ruleset {
        RulesetStatus::FullyEnforced => {
            eprintln!("pi-landlock-exec: domain fully enforced (kernel Landlock ABI {abi})");
        }
        RulesetStatus::PartiallyEnforced => {
            eprintln!(
                "pi-landlock-exec: domain partially enforced (kernel Landlock ABI {abi}); newer rules degraded best-effort"
            );
        }
        RulesetStatus::NotEnforced => {
            die(format!(
                "Landlock not enforced by the running kernel (ABI {abi}); refusing to exec unconfined"
            ));
        }
    }

    // exec replaces this process; the domain is inherited. Only returns on error.
    let err = Command::new(&command[0]).args(&command[1..]).exec();
    die(format!("exec {:?}: {err}", command[0].to_string_lossy()));
}
