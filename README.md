# This repository has moved

**heliograph now lives in one repository:
[dbhq-uk/heliograph](https://github.com/dbhq-uk/heliograph).**

Merged on 8 September 2026, with this repository's full history. The skill,
the bash station and the CLI are one product now; the boundary is the gap
rather than the language. The reasoning is recorded in
[`docs/specs/2026-09-08-station-and-skill-merge.md`](https://github.com/dbhq-uk/heliograph/blob/main/docs/specs/2026-09-08-station-and-skill-merge.md).

## Where things went

| was here | is now |
|---|---|
| `skills/heliograph/toolkit/` | [`station/bash/`](https://github.com/dbhq-uk/heliograph/tree/main/station/bash) |
| `skills/heliograph/scripts/bootstrap.sh` | `station/bootstrap.sh`, or just `heliograph bootstrap` |
| `skills/heliograph/` (SKILL.md, references) | [`skills/heliograph/`](https://github.com/dbhq-uk/heliograph/tree/main/skills/heliograph), rewritten to drive the CLI |
| `tests/` | `tests/`, unchanged |

## Installing today

```
/plugin marketplace add dbhq-uk/marketplace
/plugin install heliograph@dbhq         # Claude Code
npx skills add dbhq-uk/heliograph       # any agent, via skills.sh
```

An install that points at this repository will not receive updates. The
container image name is unchanged: `ghcr.io/dbhq-uk/heliograph-toolkit`.

Docs: <https://heliograph.dbhq.uk>
