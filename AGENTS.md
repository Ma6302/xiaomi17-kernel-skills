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
