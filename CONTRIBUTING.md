# Contributing

Thanks for taking the time. This is a small project; expect responses
to be friendly but asynchronous.

The repo is intentionally biased toward **operational correctness over
elegance** — every "magic value" must be traceable to a vendor source
in [`docs/VERIFICATION_REPORT.md`](docs/VERIFICATION_REPORT.md) or to a
script that derives it. New PRs should hold that bar.

## Filing an issue

When you hit a problem, the most useful issues include:

- **Hardware variant**: Orin NX 16GB? carrier board? what's in the M.2 slots?
- **L4T version**: `cat /etc/nv_tegra_release` output if you've already
  flashed; otherwise `versions.env` `L4T_VERSION` value.
- **Phase you're at**: `doctor` / `extract` / `build` / `bake` / `flash`
  / `verify` / runtime.
- **Step manifest excerpt**: relevant rows from `logs/STEP_MANIFEST.tsv`
  if any phase produced one.
- **The actual command + the actual output** (copy-paste, not
  paraphrase). `make logs` produces a `support-bundle-*.tar.gz`
  containing all the logs Phase 7 captures — attach that if it's not
  too big.
- **Whether you've run `make doctor`** — that's the first thing the
  responder will ask.

There's a starter template at `.github/ISSUE_TEMPLATE/bug_report.md`.

## Sending a pull request

Before opening one:

1. **Run `make doctor`** on a machine that has the prerequisites. If it
   reports new failures introduced by your change, fix or document.
2. **`bash -n`** every script you touched. The CI substitute today is
   manual; this is the bar.
3. **Update [`docs/VERIFICATION_REPORT.md`](docs/VERIFICATION_REPORT.md)**
   if your change touches a vendor fact (board target, USB ID, kernel
   CONFIG name, library version, vendor URL). Cite the source URL the
   way the existing entries do.
4. **Update [`docs/FINE_TUNING.md`](docs/FINE_TUNING.md)** if you add a
   new `/etc/jetson-av/*.conf` knob.
5. **Don't commit log artifacts** (`BUILD_LOG.md`, `FLASH_LOG.txt`,
   `IGNITION_*.log`, `support-bundle-*.tar.gz`). They're in
   `.gitignore` — keep it that way.

PR description template:

```markdown
### What
1-2 sentences.

### Why
What problem does this solve / what gap does this close?

### Vendor-fact changes
- [ ] Touches a vendor fact → updated VERIFICATION_REPORT.md
- [ ] Source URLs cited

### Vermagic discipline
- [ ] Touches kernel CONFIG / LOCALVERSION → I rebuilt and confirmed
  the audit gate (`make audit`) is still green.

### Tested on
- [ ] `make doctor` clean
- [ ] `bash -n` clean on changed scripts
- [ ] (if hardware-touching) flashed and ran `make verify` on actual
  Jetson Orin NX 16GB
```

## Code style

- **Bash**: `set -u` minimum, `set -e` where logical, all scripts must
  pass `bash -n`. No `eval` on user input. No `insmod --force` ever.
- **Indentation**: 4 spaces. Comments explain WHY, not WHAT.
- **Step framework**: any new pre/post-gated work uses
  `step::run "Step name" pre_fn exec_fn post_fn` — see
  [`docs/VERIFICATION.md`](docs/VERIFICATION.md) and
  [`scripts/lib/verify.sh`](scripts/lib/verify.sh).
- **No emoji in code or docs** unless explicitly requested.
- **Documentation goes in `docs/`**. Each new doc gets a row in the
  README's doc map.
- **Versions / paths / IDs** that show up in more than one place go in
  [`versions.env`](versions.env) and `lib/config.sh`, not duplicated.

## Hard rules

These exist because every one of them was learned the hard way. See
[`docs/VERMAGIC_STRATEGY.md`](docs/VERMAGIC_STRATEGY.md) for the long
version.

- **Never `insmod --force`.** PREEMPT_RT vermagic mismatch is not safe
  to bypass; the kernel will eventually crash in non-obvious ways.
- **Never `apt install nvidia-l4t-kernel-modules`** on a flashed
  device. The first-boot script holds these packages and pins them to
  Pin-Priority -1; don't override.
- **Never force-push to `main`.** Open a branch, file a PR.
- **Don't commit secrets.** Use `/etc/jetson-av/*.conf` files
  (gitignored where appropriate) for runtime secrets; CI tokens go in
  the runner's environment.

## Architecture overview

If you're new to the codebase, read in this order:

1. [`README.md`](README.md) — what this is.
2. [`docs/QUICKSTART.md`](docs/QUICKSTART.md) — what running it
   produces.
3. [`docs/AUTOMATION.md`](docs/AUTOMATION.md) — how Makefile +
   scripts + `versions.env` compose. Read this BEFORE modifying any
   script — the layered pattern (`lib/` → phase scripts →
   orchestrators) is intentional.
4. [`docs/VERMAGIC_STRATEGY.md`](docs/VERMAGIC_STRATEGY.md) — the
   single biggest source of pain on this stack.
5. [`docs/COMMUNITY_POST.md`](docs/COMMUNITY_POST.md) — long-form
   tour of every component end-to-end.

## Questions

GitHub issues for technical questions. Axelera community thread for
Metis-related discussion. The maintainer does not take consulting
work on this stack; if you're a company that needs this in
production, fork it — that's why it's Apache 2.0.
