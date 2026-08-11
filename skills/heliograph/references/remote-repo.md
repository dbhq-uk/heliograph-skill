# Changing a repo you cannot see

Sometimes the repo that has to *change* is on the far side of the gap too. A
separate estate often lives on a git server you cannot reach from where you are
authoring: you cannot clone it, grep it, or read its config. Only the operator's
control node can. This is the standing case for production and pre-production
estates kept deliberately separate from the one you develop in.

That does not change the loop. It just means the branch carries the change as
well as the question.

## Measure before you write a line of it

The temptation is to copy the working definition from the sibling estate and
rename one environment to another. Do not. Resource-group keys, subnet keys,
secret names, module refs and the slice layout are all local conventions, and a
definition built on assumed ones fails at plan time at best, or applies something
subtly wrong at worst.

The first step of this kind of task is always a **discovery** step, and it should
answer *everything* needed to author the change. One round trip is expensive.

A discovery step should:

- **Find the checkout, do not assume its path.** Search a set of roots, then
  identify each candidate by `git remote -v`. A directory named `infra` may be
  the repo you want under a different local name, and the remote is the only
  thing that proves it.
- **Print the wiring, not just the tree.** The config file, the dependency-key
  map, the root configuration, the branch and head commit. Those are what the
  change has to agree with.
- **Prove the toolchain and the module source.** Versions, cloud auth, and
  whether the private registry actually resolves from that node. A plan that
  cannot fetch modules fails for a reason that has nothing to do with your
  Terraform.
- **Name secrets, never read them.** Listing secret *names* settles "does this
  exist here". The value is never in question and must never reach a log.

## Read the sibling estate's current config before designing

Two decisions have been re-litigated from first principles that another estate
had already made and written down, including a provider-version trap with its
reasoning in a comment. One of them led to cutting a version tag in a shared
module registry to work around a problem that had already been decided against.

`git show origin/main:<path>` costs nothing. Do it before designing, not after
committing.

## Deliver the change as a payload, not as instructions

Put the new file under `payload/` on the task branch and write a step that copies
it into place and runs the plan. The operator still only types
`git pull && ./run.sh`.

**Never send them a patch to apply by hand.** An unlogged manual edit is exactly
the divergence these logs exist to rule out.

## Sequence it so nothing changes state before the evidence justifies it

| step | does | gate |
|---|---|---|
| `discover` | reads the target repo and estate | read-only |
| `plan` | copies the payload in, then plans | read-only against the estate; prints a diff of what it copied |
| `apply` | the real change | `CONFIRM=yes` |

A `plan` step still writes files into the *other* repo, so it must say so at the
top, show the diff it caused, and be re-runnable. Leave the target repo's working
tree obviously dirty rather than committing on the operator's behalf: what gets
committed there is a human decision, and the log is the evidence for making it.

## Two guard rails that exist because the same mistakes recur

`lib/tfguard.sh` carries both. The reasoning is in the file, and it generalises
past Terraform:

- **A "refresh the dependency" flag is rarely only that.** `terraform init
  -upgrade` re-resolves *providers* to latest, ignoring the lock file, and the
  resulting errors point at files nobody edited. A changed module ref is
  re-fetched by a plain init anyway.
- **A lock file committed in the target repo is not yours to move.** Restoring
  one something else has modified is undoing damage, not tidying, and it has to
  happen *before* the tool runs.

## Guards, generally

**A guard that can only skip will preserve a broken state forever.** Guards get
written to be idempotent: "if the key is already there, skip". That is right
until the thing already there is wrong. An entry inserted without a required
field passed the "is it present?" test on every later run and would have stayed
broken indefinitely.

Make a guard able to repair, not just abstain, and have it report which it did.
"SKIP, already correct" and "repaired the existing entry" are different facts.

**Scope an edit to a shared file by structure, not by name.** Key names repeat
across sections. An edit matching `^  <key>:` anywhere in a config file commented
out live entries in three different top-level blocks because the same name
existed under each. The output said so, and that was read as noise rather than as
the symptom it was.

Track the block you are in. And print the resulting diff, not a summary line: a
count of what changed cannot show you that it changed the wrong thing.
