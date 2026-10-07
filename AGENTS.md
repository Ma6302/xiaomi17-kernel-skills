# AGENTS.md — conventions for this repository

This repository is a **skill collection**, not an application. Each directory
under `skills/` is one agent skill that follows the agent-skills convention
(a `SKILL.md` with YAML frontmatter, plus optional `references/` and
`scripts/`).

## Layout

```
skills/<skill-name>/SKILL.md      # required entry point; the only file loaded up front
skills/<skill-name>/references/   # heavy detail, read on demand
skills/<skill-name>/scripts/      # reusable tools, invoked as `bash scripts/<tool>.sh`
scripts/validate-skills.sh        # frontmatter / structure checker for the whole repo
scripts/install-to-operit.sh      # copies skills into an agent's skills directory
```

## Hard rules when editing a skill

1. **Frontmatter carries exactly two required fields**, `name` and
   `description`. Together they must stay under 1024 characters. `name` must
   equal the directory name and match `^[a-z0-9]+(-[a-z0-9]+)*$`.
2. **The description states triggering conditions only.** It must never
   summarise the procedure inside the skill. An agent that reads the procedure
   from the description will skip the body — including any safety step in it.
3. **The skill name must not contain `claude` or `anthropic`.** Those are
   reserved by the upstream skill specification.
4. **Invoke bundled scripts through their interpreter** — `bash scripts/x.sh`,
   never a bare `scripts/x.sh`. Some packagers strip the executable bit.
5. **Never write device-identifying data into this repository.** No serial
   numbers, IMEIs, account names, tokens or personal paths. `device-profile.md`
   is a *runtime* artifact that lives on the phone, not here.
6. **Two audiences, one body.** A skill body is read by an agent, not by a
   human browsing a website. Prefer imperative commands, literal paths and
   literal `CONFIG_*` names over prose description.

## Shared runtime contract

Every skill in this collection agrees on one runtime directory on the device:

```
/sdcard/Download/Operit/kernel-dev/
  device-profile.md   # written by xiaomi17-device-recon; read by everything else
  build.env           # machine-readable version of the same facts
  src/                # kernel source tree
  out/                # build artifacts
  logs/               # build and flash logs
  backup/             # stock boot / dtbo / vbmeta images
```

If you add a skill, reuse these paths instead of inventing new ones, and do not
copy device facts into a skill body — read them from `device-profile.md`.

## Before you commit

Run the checker. It is the definition of "well-formed" for this repository:

```bash
bash scripts/validate-skills.sh
```

A skill that fails validation is silently ignored by the agent runtime, which
is a failure mode that looks like "the agent ignored my instructions" rather
than "the file is broken".

## Who may change what

This repository is edited by **two different agents**: a desktop agent (the
author) and an on-device agent running on the phone (the target environment).
They have different capabilities, so they have different write rights.

| | Desktop agent | On-device agent |
| --- | --- | --- |
| Edit `skills/**` | yes | **no** |
| Edit `scripts/**`, docs, workflows | yes | yes, via PR |
| Primary job | author the method, reason about it | run things on the real device, report raw evidence |

**The on-device agent must not edit `skills/`.** These skills are that agent's
own safety rails, and an agent that can rewrite its safety rails does not have
any. If a skill is wrong, the on-device agent reports the *observation* —
command, output, device state — and the desktop agent turns it into a skill
change. "I fixed the wording" is not a valid on-device contribution.

### Evidence rule

Any device-measured fact that enters a skill body, `README.md` or a commit
message must carry **all three** of:

1. the raw evidence (log file, command output, `device-profile.md` values),
2. the date,
3. the device state (build version, `uname -r`, root method).

A claim missing any of the three is written as **UNVERIFIED**, in those words.
Device facts are snapshots — an OTA invalidates them. They belong in the
runtime `device-profile.md`, never as a constant inside a skill body.

### Never

- `git push --force` / `--force-with-lease`, rebasing pushed history, or any
  other rewrite. `main` is append-only.
- `--no-verify`, or deleting branches.
- Committing device identifiers (serial, IMEI, account names, tokens, personal
  paths), kernel source trees, or build output (`out/`, `*.img`, `*.ko`).
- Writing an unverified claim in the voice of a measured one.

### Commit provenance

Prefix every commit subject with where the knowledge came from:

```
[desktop] <what was decided or written>
[phone]   <what was observed on the device>
[ci]      <what a build or test run produced>
```

A `[phone]` or `[ci]` commit is **evidence**; a `[desktop]` commit is
**interpretation**. When the two disagree, the evidence wins — including when
it contradicts a rule above. Report the contradiction rather than quietly
following the stale rule.

### Enforce it in settings, not only in prose

Prose does not bind an agent that ignores it. On GitHub, protect `main`:
require a pull request, disable force pushes, disable branch deletion. If the
phone authenticates with a personal access token, use a **fine-grained** token
limited to these repositories with `Contents` + `Actions` + `Pull requests`
write access — never a classic `repo`-scoped token, and never grant
`Administration`.

## Where the kernel project lives

**Not in this repository.** This one is MIT and deliberately ships no upstream
code. The kernel project — KernelSU/SUSFS patches, `zram-ir`, config
fragments, build scripts, boot images — is GPL-2.0 by derivation, so it belongs
in a **separate repository**. Keep the licence boundary and the repository
boundary in the same place.

That repository should be a **patch stack, not a fork**: no kernel source, only
`patches/` + `config/` + `scripts/` + CI that clones upstream `kernel_common`
at a pinned ref and applies the patches. That keeps it small enough to clone on
the phone, and makes every build reproducible from a pinned upstream ref.

The only kernel artefacts that stay *here* are workflows whose purpose is to be
**reproducible evidence for a claim made in a skill** — see
`.github/workflows/gki-build-check.yml`.
