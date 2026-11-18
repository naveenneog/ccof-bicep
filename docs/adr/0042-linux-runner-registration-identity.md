# ADR 0042: Identity that runs config.sh when the Linux runner registers

Status: accepted, 2026-11-18 (contract change approved by the owner at 11:44 IST).
Related: [CICD-SETUP.md](../runbooks/CICD-SETUP.md) sections 1, 2 and 6;
`scripts/cicd/Install-CcofRunner.sh` (`do_register`, `do_remove`, `lock_runner_dir`).

## Context

Two tests disagreed about how `Install-CcofRunner.sh register` runs the runner's `config.sh`:

- `tests/Test-CicdSetup.ps1` line 81 required that the installer does not contain
  `RUNNER_ALLOW_RUNASROOT` at all, which meant `config.sh` had to run as the runner user (`runuser`).
- `tests/Test-RunnerHostSafety.ps1` (static checks in the "sh static" block) required
  `RUNNER_ALLOW_RUNASROOT=1 ./config.sh --unattended ... --replace --disableupdate` in `do_register`
  and forbade `runuser ... config.sh`.

The host-safety work made the runner directory root-owned. `lock_runner_dir` sets the directory to
`root:<runner>` 750, `.env`, `.runner` and `.credentials` to `root:<runner>` 640, the rest of the layout to
root with no group or other write, and gives the runner user only `_work`, `_work/_tmp` and `_diag`. The
reason: the owner of a directory can unlink and replace any entry in it, for example the `.env` file that
points to the job-started hook, or the runner binaries. The lock runs after `svc.sh install` and before
`svc.sh start`.

Upstream facts (actions/runner v2.338.2):

- `config.sh` stops when run as root unless `RUNNER_ALLOW_RUNASROOT` is set
  (`if [ $user_id -eq 0 -a -z "$RUNNER_ALLOW_RUNASROOT" ]`):
  https://github.com/actions/runner/blob/v2.338.2/src/Misc/layoutroot/config.sh
- The systemd unit template uses `KillMode=process`, so `svc.sh stop` stops only the main process and
  processes started by a job can keep running:
  https://github.com/actions/runner/blob/v2.338.2/src/Misc/layoutbin/actions.runner.service.template

Both were read from the upstream source during earlier work on this branch. They were not fetched again
for this ADR because the work was done offline; see UNKNOWNS CICD-RUNNER-ROOT-01.

## Options

**(a) Register as the runner user.** Make the directory writable by the runner user, run
`runuser -u <runner> -- ./config.sh ...`, then lock it before `svc.sh start`, and refuse when any
runner-user process exists. Rejected because it cannot be shown to be safe:

- A process check is a point-in-time check. With `KillMode=process`, processes started by earlier jobs
  can survive `svc.sh stop`; cron, `at` and systemd user lingering can start new ones during the window.
  The installer creates the user with `/bin/bash` as its shell.
- While the directory is writable, the runner user can add files that the lock does not remove: for
  example a library in `bin/` that `Runner.Listener` loads, a changed file under `externals/`, a hard link
  to a root file, or a setuid file. `lock_runner_dir` changes owners and modes; it does not compare the
  directory with the release archive. Proving that nothing survives would need a manifest check of the
  whole layout, which does not exist.

**(b) Register as root for the one `config.sh` command.** Run
`(cd "$RUNNER_DIR" && RUNNER_ALLOW_RUNASROOT=1 ./config.sh ...)` in a subshell, so the variable is set
only in that command's environment, then `svc.sh install`, `lock_runner_dir`, `svc.sh start`.
The runner user never has write access to the layout. Root already holds the registration token and
has installed the binaries, which are pinned by SHA-256. `--disableupdate` stops the runner from
replacing root's binaries. `do_remove` uses the same form for `config.sh remove`.

## Decision

Option (b). It is the mechanism upstream provides for running `config.sh` as root, and it leaves no
window in which the runner user can write to the runner directory. The service still runs as the runner
user (`svc.sh install <runner>`).

## Contract change

Only this assertion changes, in `tests/Test-CicdSetup.ps1` (line 81 before the change):

- Old name: `Install-CcofRunner.sh: no sudo, no NOPASSWD, not run as root, no cloud-init or extension`
- Old condition: `$sh -notmatch 'sudo -u|sudoers' -and $sh -notmatch 'NOPASSWD' -and
  $sh -notmatch 'RUNNER_ALLOW_RUNASROOT' -and $sh -match 'runuser' -and $sh -notmatch '(?m)^[^#]*(cloud-init|waagent)'`
- New name: `Install-CcofRunner.sh: no sudo, no NOPASSWD, RUNNER_ALLOW_RUNASROOT only as the prefix of a
  single config.sh command, no cloud-init or extension`
- New condition: the sudo, NOPASSWD, `runuser` and cloud-init/waagent parts are unchanged. The part
  `$sh -notmatch 'RUNNER_ALLOW_RUNASROOT'` is replaced by: at least one line contains
  `RUNNER_ALLOW_RUNASROOT`, and every such line contains it exactly once and matches
  `^\s*\(cd "\$RUNNER_DIR" && RUNNER_ALLOW_RUNASROOT=1 \./config\.sh [^;&|()]*(\)|\\)`. An `export`, a
  separate assignment, a second command after `config.sh` on the same line or the variable on any other
  command fails. A command added on a continuation line does not receive the variable (a prefix
  assignment applies to one command); it is caught by new test 2 below.

Why: the old condition forbade the design chosen above. The new condition still forbids running anything
other than `config.sh` with the variable, and forbids setting it for the installer's own shell.

No other assertion is weakened or removed.

## New tests

In `tests/Test-RunnerHostSafety.ps1`, run against the real `do_register` and `do_remove` bodies in Git Bash
with `set -euo pipefail`, fake `config.sh` and `svc.sh` that log whether they see the variable, and stubs
for the host-changing helpers:

1. Only `config.sh --unattended ... --replace --disableupdate` sees `RUNNER_ALLOW_RUNASROOT=1`; `svc.sh`,
   the lock and the calling shell do not.
2. The order is `config.sh`, `svc.sh install`, `lock_runner_dir`, `svc.sh start`.
3. A failing `lock_runner_dir` stops registration (exit 3) before `svc.sh start`.
4. `do_remove`: only `config.sh remove` sees the variable; `svc.sh stop` and `uninstall` do not.

Each was mutation-tested on a copy of the installer; results are in [STATUS.md](../STATUS.md).

## Consequences

- `config.sh` runs as root. A defect in `config.sh` runs with root rights during registration. This is
  accepted: root already runs the installer and the pinned binaries came from a verified archive.
- Re-registration and removal need root, as before.
- If a later runner version changes the `RUNNER_ALLOW_RUNASROOT` check, registration fails visibly
  (`config.sh failed`), and the new tests show which command saw the variable.
- The Windows runner is out of scope for this release; see CICD-SETUP.md section 2.
