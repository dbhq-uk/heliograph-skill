# Moving a value the other way

Everything else in this skill carries evidence **out**. Occasionally something
has to go **in**: a registry password, a token, a licence key that the far side
needs and cannot fetch for itself. The two sides share no identity, the secret
store on your side is not reachable from theirs, and the transport repo is the
only thing both can see. It is also committed and pushed, so a value pasted into
a step is in that history permanently.

`toolkit/secret.sh` carries it as **ciphertext**. The passphrase travels through
a human who defines it on both machines, and never through git, so what git
carries is useless on its own.

This is not a licence to read secrets off the far side. That is still refused,
for the same reason as ever: a log is permanent, and the value was never the
question. This carries one you already hold to a machine that needs it.

```bash
./secret.sh key               # define the passphrase (FIRST, on both machines)
./secret.sh key show          # print the fingerprint, to compare the two
./secret.sh put <name>        # read a value from stdin, store it encrypted
./secret.sh get <name>        # decrypt to stdout, for $( ) capture in a step
./secret.sh check <name>      # prove it decrypts here, without printing it
./secret.sh list              # names, sizes, dates
./secret.sh rm <name>         # drop it from the working tree (not from history)
```

## The passphrase

`secret.sh key` prompts twice without echoing, writes the file `0600`, and prints
a **fingerprint**: 600k PBKDF2 rounds under a fixed salt, hashed and truncated to
12 hex characters.

```
$ ./secret.sh key
Passphrase (not shown):
Again to confirm      :

written         : /home/you/.heliograph-passphrase (mode 600)
fingerprint     : 64023f4b6c89

Run the same command on the other machine and check the fingerprints match.
```

**Run it on both machines and compare the fingerprints.** They match only if the
passphrases do. A typo is otherwise invisible until a `get` fails on the far side
with nothing to go on but "bad decrypt", by which time the ciphertext has been
committed and is permanent. That round trip is the one this command exists to
save.

The fixed salt is what makes two machines comparable, and it is also why the
fingerprint is a checksum for humans rather than a password: a weak passphrase is
guessable from it, so `key` warns below 20 characters. The warning fires however
the value arrives, including when it is piped in for provisioning
(`printf '%s' "$p" | ./secret.sh key`).

Replacing an existing passphrase needs a typed `REPLACE`, and is refused outright
when not on a terminal. Everything already in `secrets/` was encrypted under the
old one and becomes unreadable, while the ciphertext stays in history where
nobody can recover it.

`key` and `put` are the only things here that prompt, they are run by a person on
a terminal, and they are never reached through a step. A step only ever calls
`get`, which reads nothing from stdin and cannot hang the capture.

## Sending a value

On the authoring side:

```bash
./secret.sh put registry-pass          # paste the value, then Ctrl-D
git add secrets/ && git commit -m 'secret: registry-pass' && git push
```

In a step on the far side, captured, never echoed:

```bash
PASS="$("$HERE/../secret.sh" get registry-pass)"; export PASS
some-command --password-stdin <<<"$PASS"
```

Do not `echo` it, do not pass it as an argument to anything that a probe prints,
and do not let it reach a `probe` label. `cap_redact` masks the obvious shapes on
the way into the log, but it is a safety net rather than a guarantee.

## Why it is built the way it is

The cipher is the least interesting part. The failure modes are where this earns
its place:

- **Plaintext is read from stdin, never argv**, so it never appears in `ps` to
  other users on the box.
- **`put` round-trips before it writes**, so a bad encrypt surfaces on the
  authoring side rather than as an unexplained step failure on the far side.
- **`get` buffers rather than streams.** `openssl` writes partial plaintext to
  stdout *before* it notices bad padding, so a streamed failed decrypt dribbles
  binary garbage into whatever consumed it: a log, a secret store, a registry
  login. Found by testing a wrong passphrase, not by reasoning about it.
- **It refuses a group- or world-readable passphrase file.** That would make
  every secret the repo has ever carried readable to anyone with an account on
  the box, while looking perfectly safe.

## Knobs

| var | default | effect |
|---|---|---|
| `PASSPHRASE_FILE` | `~/.heliograph-passphrase` | where the passphrase lives. Must be mode 0600 or 0400 |
| `SECRET_STORE` | `secrets/` beside `secret.sh` | where the ciphertext is written |
| `PBKDF2_ITER` | `600000` | iteration count. Must match on both machines |

## What it is not

Transport, not storage. AES-256-CBC with PBKDF2 at 600k iterations and a random
salt is adequate for moving a credential between two machines you control, but
there is no rotation, no audit and no expiry, and the ciphertext is in history
**forever**. A passphrase that leaks later exposes everything ever sent under it.

So prefer short-lived, narrowly scoped credentials, land the real secret in
whatever store the far side has, rotate the passphrase periodically, and rotate
the underlying credential rather than trusting `secret.sh rm`, which clears the
working tree and not history.

If there is any other channel at all, use that instead.
