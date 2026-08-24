# Method - debugging a system you cannot log into

The tooling exists to support a way of working. The tooling is the easy part.

These are the rules that were paid for, mostly by breaking them first.

---

## 1. Measure now, and do not trust the last investigation

Notes, findings files and remembered conclusions describe a system that existed when they were
written. Environments move: someone patched a host, a token expired, a firewall rule landed, a
tool floated a major version.

Start every investigation by measuring the current state - that is what `./run.sh env` is for.
A prior finding is a hypothesis to re-test, never a premise to build on.

Four dead ends in one afternoon have been spent on this exact mistake.

## 2. Keep a control

A measurement with nothing to compare against is an anecdote. Run the same probe against
something known-good **in the same log**: the other node, another host in the same subnet, the
environment where it works.

"It fails" is not a finding. "It fails here and succeeds there, same command, same minute" is.

## 3. Run it in all directions

Reachability, permissions and name resolution are all directional. A→B working tells you
nothing about B→A. Probe both ways before concluding anything about the network - the fault is
routinely in the direction that wasn't tested.

Same for protocols: an all-green TCP matrix does not mean "reachable". ICMP and UDP are
separate questions and have to be asked separately. A Windows cluster will refuse to form with
ICMP filtered while every TCP port it needs is open.

## 4. Never truncate

No `head`, no `tail -20`, no `2>/dev/null` on the thing being diagnosed, no "I'll just grep for
the error". The line you cut is the line you needed, and you won't know that until after you've
cut it. Disk is cheap; a second round-trip through the operator is not.

Corollary: read the whole log, including the parts that worked.

## 5. A gap in the timestamps is a finding

This is why every captured line carries a UTC clock. After the fact, a hang and slow progress
are indistinguishable in an untimed log. With timestamps, a four-minute gap tells you exactly
which operation stalled and for how long.

## 6. Change one thing

Between two runs, change exactly one variable. Two changes and a different result tells you
nothing - you've spent a full round-trip to learn that something in a set of two mattered.

## 7. Symptoms lie about their cause. Match the shape

"Access denied", "RPC server unavailable", "cannot be contacted" are the *same message* for a
credential problem, a name-resolution problem and a firewall problem. Don't read a symptom as a
diagnosis.

Get a healthy baseline of the same operation and **diff it**. The difference is the finding;
the error text is just where you started looking.

In particular, don't conflate credential contexts. A command that works locally and fails
across machines is usually about which credential the second hop is using, not about the
network being broken.

## 8. Beware the guaranteed pass

Before trusting a check, ask what it would look like if the thing were broken. A sudo-password
test run as an account with `NOPASSWD:ALL` passes no matter what - it isn't testing what it
claims to. If a probe cannot fail, it is not a probe.

## 9. Say what you measured, separately from what you concluded

In `TASK.md`, keep those apart. Measurements stay true; conclusions get revised. Mixing them is
how a guess becomes a premise three runs later and takes the whole investigation with it.

## 10. Read-only until you have earned it

Every step is read-only until you can say precisely what the change will do and why. Diagnostic
steps are safe to repeat, safe to run out of order, and safe to run against the wrong host by
accident. Action steps are none of those things, which is why they carry the `CONFIRM=yes`
gate.

---

## 11. A green exit means the probes that ran passed. Not that the work happened

A step that reports `exit 0` has told you one thing: nothing it executed returned
non-zero. It has not told you the intended change landed. A commit step once
reported success having never pushed - the push sat behind a condition that
tested a string against `"1"` and was silently false, so it simply never ran.

Verify the outcome, not the exit code. If a step is supposed to push, have it
print what the remote says afterwards. If it is supposed to apply, read the
resource back. The exit code is the weakest evidence in the log.

## 12. One request, one runner. Bind them to different branches

Two runners on one transport repo will both answer the same request, and there
is no lock that stops them. Each agent records the last id it handled in
`.agent-state`, which is gitignored because it is a fact about one machine, so
neither can see what the other has done. A build agent makes it worse: a
pipeline that cleans its workspace starts every job with no state file at all,
so it answers whatever id it finds, every time.

The failure looks like success. Two logs for one question, from two machines,
seconds apart, both green - and the whole value of a heliograph log is that it
says what *one* machine saw. You will not notice until two logs disagree and you
cannot tell which one is about the box you care about.

Bind each runner to its own branches, so they read different copies of
`agent/request` and have nothing to race on:

```
main, pipeline/*  ->  the build agent   (trigger.branches.include)
vm/*              ->  the VM agent      (./start.sh --branch vm/<slug>)
```

Do not bind `task/*` to a runner. It is the branch name this documentation uses
for an investigation, so it is the first thing anyone reaches for when starting
work on the *other* runner - which is exactly how both end up on one request.

The trigger config stops the run being created; add a guard in the job that
refuses a branch outside its set, because queueing a run by hand from a web UI
bypasses trigger evaluation entirely. A loud failure beats a silent double
answer.

---

Three more rules apply once the branch carries a *change* and not only a
question - repair rather than skip, scope an edit by structure rather than by
name, and read the target's current config before designing against it. They are
in [remote-repo.md](remote-repo.md), with the failures that taught them.

## The loop, in practice

1. Write the question in `TASK.md`. One question.
2. Write the step that answers it - with a control in the same run.
3. Set `DEFAULT_STEP`, push, ask for a run.
4. Read the whole log. Record what was *measured*.
5. Only then form the next hypothesis.

Slower per round-trip than guessing. Far quicker to the end of the investigation.
