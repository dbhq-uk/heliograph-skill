# PR 3: the container Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a lightweight image and a one-line wrapper so the loop can run somewhere nobody has to keep a terminal open, including a subscription the estate's own staff deploy into.

**Architecture:** `toolkit/docker/Dockerfile` builds `debian:bookworm-slim` plus `git`, `ca-certificates`, `bash` and `sudo`, with an unprivileged user that has passwordless sudo. `toolkit/docker/entrypoint.sh` clones the transport repo and hands over to the repo's own `start.sh`, which already owns the preflight, the credential resolution and the handover to `agent.sh`. `toolkit/docker/heliograph.sh` wraps the `docker run` into one line and works with podman unchanged.

**Tech Stack:** Docker or podman, bash, git. Tests are plain bash under `tests/`, using the existing `assert.sh` harness.

## How this plan is written

PR 1 and PR 2 between them produced three Critical defects, and **every one originated in plan-supplied code or a plan requirement whose consequences I had not traced**, not in the implementations. So this plan specifies contracts, properties and reasoning, and supplies literal content only where it is definitional.

**Verify every sketch before trusting it, and say so in your report when one is wrong.** A wrong sketch is a plan defect, not your error. Implementers on the previous branch correctly overruled a reviewer's sketch twice by measuring it; that is the behaviour this plan wants.

Before writing any assertion, confirm the thing it inspects is observable in the stream being captured. **Eleven assertions across the previous two PRs turned out unable to fail**, one of them written by someone actively hunting for exactly that defect. Mutation is the only thing that has reliably caught them: break the implementation, watch the specific assertion go red, restore.

**Commit before mutating, then restore with `git checkout -- <file>`.** All three restore methods have lost work on this project when applied to uncommitted changes.

## Global Constraints

- Bash 4+, git and GNU coreutils only on the host side. No packages, no interpreter beyond bash, no credentials of the skill's own.
- `set -uo pipefail`, never `set -e`.
- One implementation of the capture pattern, in `caplib.sh`. Do not fork it. Nothing in this PR should need to touch it.
- `shellcheck -S warning` must pass for every `*.sh` in the repo, and `bash -n` must parse every one. CI sweeps the root, `skills/` and `tests/`.
- House style: British English, plain hyphens, **no em dashes** in `*.md`, `*.sh` or `*.json`. CI fails the build on one.
- No trailing full stops on headings.
- `bootstrap.sh` copies `toolkit/` by `find`, so `toolkit/docker/` ships to new transport repos with no wiring, and files must be committed with the right mode.
- `./tests/run-tests.sh` currently passes 188 assertions and must continue to.
- **The container runs as an unprivileged user with passwordless sudo, never as root by default.** In a container that is not a security boundary and must not be documented as one.

## A constraint specific to this PR: tests that need a daemon

Container tests cannot run without a container runtime, and the development machine may not have one. A suite that silently skips is worse than no suite, because the log then reads as though the checks ran. This is the same defect shape as a silently skipped checksum, which PR 2 refused to allow.

So: container tests **skip loudly**, printing what was skipped and why, and **CI must run them without skipping**. A CI job that would let the container tests skip is a defect in this PR. Task 4 owns proving CI actually runs them.

---

### Task 1: The image

**Files:**
- Create: `skills/heliograph/toolkit/docker/Dockerfile`
- Create: `tests/test-container.sh`

**Interfaces:**
- Produces: an image that can be built from the repo root of a transport repo. Task 2 adds the entrypoint, Task 3 the wrapper.

**What the image must guarantee**, and each of these is a property to assert rather than a package to install:

- `bash` is version 4 or newer
- `sed -u` is honoured, and `base64 -w0` produces unwrapped output. These are the two spellings `start.sh`'s own preflight refuses to run without, and the whole reason the spec rejects Alpine
- `sha256sum`, `date -u`, `git` and `setsid` are present. `start.sh` warns rather than fails on the last two, so check what it actually expects rather than assuming
- the default user is **not** root, and `sudo -n true` succeeds for that user
- the transport repo's working directory is writable by that user

- [ ] **Step 1: Measure before deciding anything**

Build a throwaway image with just the base and record: the base image size, the size after each package added, and which of the tools above the base already carries. The spec's "around 90MB" is a guess of mine to be replaced with a measurement.

Report what `debian:bookworm-slim` already has. If `git` pulls in a large dependency tree, say so with numbers; a smaller alternative may exist and this is the moment to find out.

- [ ] **Step 2: Write the failing tests**

`tests/test-container.sh` builds the image once and asserts the properties above by running commands inside it.

Two things to get right, and both have bitten this project before:

- **Skip loudly when no daemon is available.** Print what was skipped and why, and exit 0 so the rest of the suite runs. Never let a skip look like a pass in the summary.
- **Assert on what the container reports, not on what you passed it.** An assertion that echoes its own fixture back is the recurring defect here.

Build the image once for the whole file rather than per assertion; a per-assertion build makes the suite unusable.

- [ ] **Step 3: Run the tests and confirm they fail**

Read the failure output. A test failing because the image does not exist yet is the expected RED; a test failing because the harness is wrong proves nothing.

- [ ] **Step 4: Write the Dockerfile**

Pin the base image by tag, and say in a comment why it is not pinned by digest, or pin by digest and say why that is right. Either is defensible; an unexamined choice is not.

The user needs a name, a uid, a home, and a sudoers entry granting passwordless sudo. Put the reasoning for the unprivileged default in a comment, including the honest note that in a container this is not a security boundary.

- [ ] **Step 5: Run the tests and confirm they pass, and record the final size**

- [ ] **Step 6: Repo checks and commit**

`bash -n`, `shellcheck -S warning`, the em-dash grep, and the full suite.

---

### Task 2: The entrypoint

**Files:**
- Create: `skills/heliograph/toolkit/docker/entrypoint.sh`
- Modify: `skills/heliograph/toolkit/docker/Dockerfile`
- Modify: `tests/test-container.sh`

**Interfaces:**
- Consumes: the image from Task 1, and `start.sh` from PR 1, which already owns the preflight, credential resolution, branch checkout and handover to `agent.sh`
- Produces: a container whose entrypoint takes a repo URL and ends in the repo's own `start.sh`

**The contract.** Given a transport repo URL and a credential, the entrypoint clones the repo, changes into it, and hands over. Everything after the clone is `start.sh`'s job and must not be duplicated here: the spec is explicit that two copies of the preflight, one baked into the image and one in the repo, would leave no answer about which is authoritative.

**What it must handle**, with a message naming the fix in each case:

- no repo URL given at all
- a URL it cannot reach, or a credential that does not work
- a branch that does not exist
- an already-cloned repo, if the container is restarted against a persistent volume. Decide whether to pull or to re-clone, and justify it
- arguments passed through to `start.sh` and onward to `agent.sh`

**The credential.** PR 1 established the resolution: the remote's scheme decides which credential is relevant, and `cap_git` attaches the token. The entrypoint has to get the credential to the clone, which happens **before** the repo exists and therefore before `caplib.sh` is available. Work out how, and be careful: the URL is the obvious route and it is the one that leaks. PR 1 added masking to `cap_redact` and to `start.sh`'s remote line for exactly this shape.

**Never print the credential.** Assert that.

- [ ] **Step 1: Write the failing tests**

Cover the contract and each failure case. For the credential, assert that a token passed in does not appear anywhere in the container's output, and confirm by hand that your fixture token really would appear if the masking were removed.

- [ ] **Step 2: Run and confirm they fail, for the right reason**

- [ ] **Step 3: Implement**

- [ ] **Step 4: Run and confirm they pass**

- [ ] **Step 5: Prove the whole path by hand**

Against a real bare repo reachable from the container: start the container, watch it clone, watch `start.sh`'s preflight run, and confirm it hands over to `agent.sh`. Paste the output. No unit test covers the handover.

- [ ] **Step 6: Repo checks and commit**

---

### Task 3: The wrapper

**Files:**
- Create: `skills/heliograph/toolkit/docker/heliograph.sh`
- Modify: `tests/test-container.sh`

`heliograph.sh` turns the `docker run` into one line the operator can be given. It must work with `podman` unchanged, which in practice means detecting which runtime is present and not relying on a Docker-only flag.

Decide and justify: whether it builds the image if absent or refuses; whether it runs detached or in the foreground; what it does about the log directory; and whether it mounts anything at all. The spec's principle is that the container clones rather than mounts, so a mount should be an opt-in with a stated reason.

- [ ] **Step 1: Write the failing tests**
- [ ] **Step 2: Run and confirm they fail**
- [ ] **Step 3: Implement**
- [ ] **Step 4: Run and confirm they pass**
- [ ] **Step 5: Repo checks and commit**

---

### Task 4: Publishing, and making drift impossible rather than unlikely

**Files:**
- Create: `.github/workflows/publish-image.yml`
- Modify: `.github/workflows/validate.yml`

The spec calls the published image drifting from the repo's Dockerfile a CI requirement rather than a good intention. **The strongest version of that is to make drift impossible by construction**: nothing is ever built by hand and pushed, so the published image can only ever be what the repo's Dockerfile produces.

Two things to build:

1. **A publish workflow** that builds from the repo and pushes, triggered on whatever event you judge right. Argue the trigger: on every push to `main`, on a tag, or on a release each have different failure modes for a tool people deploy into client estates.
2. **A PR-time build** that proves the Dockerfile still builds, without pushing.

And the constraint from the top of this plan: **CI must run the container tests without skipping.** Prove it does. A green CI run in which the container tests skipped is the failure mode this task exists to prevent, and it is invisible unless something asserts on it.

- [ ] **Step 1: Decide the publish trigger and record the reasoning**
- [ ] **Step 2: Write both workflows**
- [ ] **Step 3: Prove CI runs the container tests unskipped**

You cannot run GitHub Actions here. Say plainly what you verified locally and what only a real CI run can confirm, rather than implying more.

- [ ] **Step 4: Repo checks and commit**

---

### Task 5: Documentation

**Files:**
- Create: `skills/heliograph/references/container.md`
- Modify: `skills/heliograph/SKILL.md`, `skills/heliograph/README.md`, root `README.md`, `AGENTS.md`

`references/container.md` is the full account: what the image contains and why, the unprivileged-user decision **with its honest limits**, how the entrypoint gets the repo and the credential, the two distribution paths and why both exist, the wrapper, and what none of it covers.

**Read the code before writing about it.** Decisions get made during implementation, and on the previous branch a reference document went stale inside a single commit. Where this plan and the code disagree, the code wins and you should say so.

Check the "What ships" tables and payload lists, which live in four places and were each wrong at least once during PR 1.

- [ ] **Step 1: Read the existing references first, for voice**
- [ ] **Step 2: Read the shipped code, separately, for facts**

These are two different passes over the same material. On the previous branch an agent read `runner.md` for voice, reported nothing stale, and missed a factual drift that a second pass would have caught.

- [ ] **Step 3: Write the reference and update the five files**
- [ ] **Step 4: Run CI's own documentation checks**
- [ ] **Step 5: Commit**

---

### Task 6: Verify the whole PR the way the repo insists on

**Files:** none, unless a defect is found. Report defects rather than fixing them.

- [ ] **Step 1: Run every check CI runs**

Read `.github/workflows/validate.yml` and run what it actually runs, rather than a list from this plan.

- [ ] **Step 2: Prove a bootstrapped copy receives `toolkit/docker/`**

With the right modes as recorded in git, not merely on disk.

- [ ] **Step 3: The end-to-end run that matters**

From a fresh transport repo with a real remote: build the image, run the wrapper, watch the container clone, preflight, hand over to `agent.sh`, take a request, run a step, and push the log back. Confirm the log's every body line carries a UTC timestamp. That full round trip is the thing this PR exists to make possible and nothing short of it proves the PR works.

- [ ] **Step 4: Try to break it**

The previous two PRs' three Criticals were all found by adversarial construction, never by reading. Spend real effort. At minimum: a token that must not appear in any output or in `docker inspect`; a repo URL pointing somewhere hostile; a branch name containing shell metacharacters; the container restarted against an existing clone; a full disk or read-only volume; and what the image does with no network at all. Go beyond this list.

- [ ] **Step 5: Write the PR description**

Do not push and do not open the pull request. Be honest about what none of this covers, and state the assertion count by running the suite rather than counting.

---

## Self-review

**Spec coverage.** The spec's PR 3 section names: the base image and why not Alpine (Task 1), the measured size replacing my guess (Task 1), both distribution paths with drift made structurally impossible (Task 4), the entrypoint cloning (Task 2), the unprivileged user with its honest limits (Tasks 1 and 5), and the wrapper working with podman (Task 3). All covered.

**Placeholder scan.** No TBDs. Where this plan does not supply an implementation that is deliberate and stated, and each such place names the property to satisfy and how to verify it.

**Type consistency.** Three shipped files: `Dockerfile`, `entrypoint.sh`, `heliograph.sh`, all under `toolkit/docker/`. `tests/test-container.sh` is created in Task 1 and extended in Tasks 2 and 3.

**What I am least sure of, stated so it gets attention.** How the entrypoint gets a credential to a `git clone` that runs before `caplib.sh` exists is the part of this design I have thought about least, and it is the part most likely to leak a token. Task 2 names it as a thing to work out rather than pretending I have specified it. The publish trigger in Task 4 is similarly left open, because the right answer depends on how the image is meant to be consumed and I would rather that reasoning be written down than inherited from me.
