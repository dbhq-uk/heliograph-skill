# secrets/

Encrypted values, carried across the gap by `../secret.sh`.

Each `<name>.enc` is AES-256-CBC + PBKDF2 (600k iterations, random salt),
base64, produced by `secret.sh put <name>`. The passphrase lives in a file
outside this repository (`~/.heliograph-passphrase`, mode 0600) and is defined by
a human on **both** machines with `secret.sh key`. It is never committed and
never passed on a command line.

These files are tracked deliberately: git is the only channel between the two
sides, so the ciphertext has to travel in the repository. That is also the
warning. **Ciphertext committed here is in history permanently**, and a
passphrase that leaks later exposes every secret ever sent under it.

So:

- prefer short-lived or narrowly scoped credentials over long-lived ones
- land the real secret in whatever secret store the far side has, and treat what
  is here as transport rather than storage
- rotate the passphrase periodically, and rotate the underlying credential if it
  is ever in doubt. `secret.sh rm` clears the working tree, not history

This is the opposite direction to a captured log. Nothing here reads a secret off
the far side; it carries one you already hold to a machine that needs it.
