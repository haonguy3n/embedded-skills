# Process: commits, verification, measurement, writing

How changes are made and reported. These matter as much as the code rules: they are what lets a small team (or a
person plus agents) move fast without breaking a device in the field.

## Commits

- **Commit each verified step promptly**, in small logical commits with one concern each. A refactor, a behaviour
  change and a doc update are three commits.
- **The message says what changed, why, and how it was verified, and where**: "host only" or "on the target". Name
  the evidence: test counts, the gate result, measured numbers with their conditions. Say plainly what was *not*
  verified. Example:

  ```
  camera-streamer.service: pin the VIC and NVENC through devfreq, which works on fused units

  The debugfs pin does nothing on a fused unit: those debug nodes are disabled there. devfreq's min_freq is plain
  sysfs and pins the same engines.

  Measured on the Orin NX (real sensor, 30 fps) with debugfs unmounted: capture to encoded 16.5 -> 3.8 ms mean.
  Not run on a really fused unit; the installed unit file is verified by the next image.
  ```

- Stage explicit paths (never `git add -A`: it picks up symlinks, secrets and scratch files). Don't commit while a
  build reads the working tree.

## Verify in a clean worktree

A commit must build and pass its checks without your uncommitted files:

```sh
git worktree add ../<repo>-verify HEAD
cd ../<repo>-verify && cmake --workflow --preset host-debug
```

**Parallel work goes in separate worktrees**, one per task or agent (`git worktree add ../<repo>-<topic> -b <topic>`).
Two writers never share one tree. Remove a worktree once its branch is merged.

## Branches and history

- Branch per change from an up-to-date `main`; the maintainer merges.
- Rewrite history only on your own unmerged branch, and push it with `--force-with-lease`. Never force-push a shared
  branch.
- Releases: bump the version in every place it is written (build system, packages, lockfiles) in one commit, merge it,
  then put an annotated tag on the merge commit with notes that state what was verified.

## Measure, don't argue

- A performance change is accepted with before/after numbers from the target, under the same conditions (same input,
  same load, several windows averaged), including p95/max, not just the mean, and the cost (CPU, power, temperature).
- Leave the instrumentation in: a switch that turns timing summaries into log lines makes the next comparison cheap.
- A test that flakes because the system got faster is fixed in the test, with the reason in a comment.

## Writing docs, comments and messages

- Plain English, short sentences, active voice. Define a term the first time it appears ("NVENC is the Jetson's
  hardware video encoder"). Write for a newcomer who is learning the system.
- Explain **why**, not what the code already says. Record what was learned the hard way on the target, with the date.
- Keep one agent/onboarding file (`CLAUDE.md` / `AGENTS.md`) current: the commands typed exactly, the rules most often
  missed, the check table, and the hazards (anything that can brick a device, lose data or lock users out).
- Report honestly: separate "verified on the target", "verified on the host" and "not verified"; never present an
  estimate as a measurement.

## Safety on real hardware

- List the dangerous operations in the agent file (restarting a critical service over the only link, rebooting
  repeatedly, installing images by hand) and ask before doing them.
- Every experiment that changes device state (clocks, mounts, config overrides, test binaries) restores it at the end
  with a trap, and the report confirms the restore.
- Prefer runtime changes that a reboot undoes (a drop-in under `/run`, a value in sysfs) over changes on persistent
  storage while testing.
