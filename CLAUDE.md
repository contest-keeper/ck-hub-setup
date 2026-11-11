# ck-hub-setup

Docker Compose setup for running Keeper Hub.

Part of Contest Keeper (github.com/contest-keeper). Read these before changing anything:

- Code conventions: https://github.com/contest-keeper/.github/tree/main/conventions
- Branches, commits, PRs, releases: https://github.com/contest-keeper/.github/blob/main/CONTRIBUTING.md
- The plan and shared context: `plan/` in the ck-website repository (`plan/context.md` first)

## Checks

Run before committing: docker compose config; docker compose up

## Rules

- Work on a branch (`feature/`, `fix/`, `chore/`, `docs/`, `epic/`), never on `main`.
- Commit and PR titles: `type: lowercase imperative subject` (e.g. `feat: add ESP config reader`).
- No `Co-Authored-By` trailers, "Generated with" lines or other tool attribution in commits or PRs.
- Never store, log or send passwords, cookies, session ids or tokens. The user types credentials.
- Ask before deleting, force pushing or anything that leaves this machine.
- Skills: `/ck:next-step` for the next plan step, `/ck:commit-pr` to commit and open a PR.