# Downloader Safety Policy

The optional on-device Google Play downloader is the one part of this port that
touches a user's account. These are the rules it lives by, why each one exists,
and how each one is enforced by a check rather than by good intentions.

> 1. **Keep the tool strictly open source.**
> 2. **Never hardcode generic bypasses or cracked licences.**
> 3. **Do not store or transmit user credentials through any third-party
>    server.**

The rules govern two components, each carrying its own `PROVENANCE.json` and
each checked by the same script:

| Component | Tree |
|---|---|
| On-device Google Play downloader | `portmaster/minecraftbedrock/minecraftbedrock/downloader/` plus its build tooling in `tools/ondevice-downloader/` |
| mcbedrock-get Windows/Linux helper | `tools/mcbedrock-get/` |

Everything up to "The mcbedrock-get helper" describes the on-device downloader;
that section covers where the helper differs.

Run the enforcement pass at any time:

```bash
python3 scripts/check_downloader_policy.py
```

It is also part of `tests/run_all.sh` and of the **Release safety** GitHub
Actions workflow, so a change that breaks a rule fails before it ships.

---

## Rule 1 — Keep the tool strictly open source

**What this means here.** Every executable that ships inside the port is built
from source anyone can read, with the build recipe in this repository, and its
licence travels beside it. Nothing is an opaque blob.

| Shipped file | Source | Licence | Build script |
|---|---|---|---|
| `downloader/bin/gplaydl` | [minecraft-linux/Google-Play-API](https://github.com/minecraft-linux/Google-Play-API) @ `6ead9131` | Apache-2.0 | `tools/ondevice-downloader/build-gplaydl-arm64.sh` |
| `downloader/bin/gplayver` | same upstream commit | Apache-2.0 | same script |
| `downloader/bin/mcpe-signin` | `tools/ondevice-downloader/google-signin-quick/main.cpp` | GPL-3.0-or-later | `tools/ondevice-downloader/build-google-signin-arm64.sh` |
| `downloader/lib/libqt-xcb-glx-compat.so` | `tools/ondevice-downloader/qt-xcb-glx-compat.c` | GPL-3.0-or-later | `tools/ondevice-downloader/build-qt-xcb-glx-compat-arm64.sh` |

The authoritative, machine-readable version of that table is
`downloader/PROVENANCE.json`, which also records each file's SHA-256 and size.

**How it is enforced.** The checker walks the whole downloader tree, treats any
file that is not valid UTF-8 text as a binary, and fails if that binary is not
declared in `PROVENANCE.json`. For each declared binary it re-hashes the file
and requires the digest and size to match, requires a licence name and an
existing licence text, requires an existing build script, and requires either a
pinned 40-character upstream commit or an in-repo source file that exists. A
new blob dropped into `bin/` cannot pass silently, and a rebuilt binary forces
the manifest to be updated with it.

**Adding or updating a binary.** Rebuild it with its script, then update its
`sha256` and `size` in `PROVENANCE.json` (and the `commit` if upstream moved).
The checker will tell you precisely which field is stale.

**Known gap, stated honestly.** The three build scripts are published and
runnable, but none of them is byte-for-byte reproducible yet: the Google-Play-API
cross-build takes `protoc` and headers from the build host, and the sign-in
helper's container uses an un-pinned `debian:bookworm` base. `PROVENANCE.json`
marks each of these `"reproducible": false` with the reason. Pinning the
container digest and vendoring the toolchain, the way
`bin/mcpelauncher-client.buildinfo` already does for the launcher, is the fix.

## Rule 2 — Never hardcode generic bypasses or cracked licences

**What this means here.** The downloader is a delivery convenience for people
who already own Minecraft, not a way to get it. Google Play performs the
entitlement check, against the account holder's own signed-in account, on
Google's own servers. The port never attempts to weaken, emulate, or step
around that.

Concretely, the tool ships with:

- no account, token, password, or device/GSF identifier of any kind;
- no shared or "community" Play session;
- no licence-check patch, DRM shim, or signature-check removal;
- device profiles (`downloader/device-arm64.conf`, `device-armhf.conf`) that
  declare an ABI and nothing else — no identity, no fingerprint.

The port also refuses rather than reaches for a workaround: Bedrock 1.26+ ships
with PairIP licensing that the upstream launcher cannot open, and
`apkmeta.py` reports that plainly instead of trying to defeat it. Downloaded
APKs are validated (`downloader/validate_download.py`) for package, version
code, **signer**, split completeness, and requested ABI — the signature check is
something the port insists on, not something it bypasses.

**How it is enforced.** The checker scans every text file in the downloader and
build-tool trees for:

- real Google token shapes (`aas_et/…`, `oauth2_4/…`, `ya29.…`), in text *and*
  inside the shipped binaries;
- `user_token` / `user_email` assigned to a string literal;
- a hardcoded `android_id` / `gsf_id` / `device_id`;
- any email address that is not on an example domain;
- vocabulary that describes defeating a protection measure rather than using an
  entitlement — cracking, piracy, licence bypass, patched/modded APKs, unlocked
  premium, shared accounts, mock entitlements.

It separately parses both device profiles and fails on any line that is not the
`native_platforms` declaration.

**The `policy-allow:` escape hatch.** A line that must legitimately use
forbidden vocabulary — a refusal message, policy prose — can carry
`policy-allow: <reason>` on that same line to be skipped by the vocabulary
scan. It does **not** waive the credential or token checks. Use it sparingly
and always with the reason spelled out.

## Rule 3 — No user credentials on or through a third party

**What this means here.** The account holder's password and phone approval are
entered into Google's own embedded sign-in page, rendered locally by Qt
WebEngine. The port never sees the password. What it receives is Google's
one-shot `oauth_token`, which the upstream `gplayver` helper exchanges — again,
directly with Google — for a long-lived Play session. There is no server in this
project, no telemetry, no relay, and no account of ours anywhere in the path.

**On the wire.** Every host the downloader can reach is listed in
`PROVENANCE.json` under `network.allowed`, with the purpose of each and whether
it may see credentials:

| Host | Party | Credentials | Why |
|---|---|---|---|
| `accounts.google.com` | Google | yes | Google's own embedded sign-in page |
| `android.clients.google.com` | Google | yes | Play auth, checkin, and delivery, called directly by `gplaydl`/`gplayver` |
| `github.com`, `objects.githubusercontent.com` | upstream artifact | no | pinned, checksum-verified launcher AppImage |
| `deb.debian.org` | upstream artifact | no | pinned, checksum-verified Qt keyboard plugin |

The checker extracts every URL from the downloader tree — including from the
committed ARM64 binaries — and fails on any host that is not on that list. It
also fails if an allowlist entry claims `credentials: true` without being a
Google endpoint. The two optional runtime downloads are size- and SHA-256-pinned
in `downloader/runtime.conf`, and the checker requires those pins to match
`PROVENANCE.json` exactly.

**On disk.** `downloader/credential-artifacts.txt` is the single source of
truth for every path that can hold account data. `run.sh` reads that file to
decide what to delete, so the sign-out action and the checker can never drift
apart:

- `transient` — written while a sign-in is in flight. Removed on **every**
  `run.sh` exit, so a cancelled or interrupted sign-in cannot leave Google's
  one-shot token on the card. `gui-session.sh` likewise drops the exchange
  input unless the handoff actually completed.
- `session` — the saved Play session. Removed by **Sign out of Google Play**.
- `dir` — the private per-session `HOME` and XDG trees. Removed by sign-out.

Everything lives under the private `minecraftbedrock-data/downloader/`
directory, created `0700`, with files written `0600` under `umask 077`. The
checker verifies that `umask` is still set in both scripts, that `run.sh` still
removes all three artifact kinds, and that no credential filename is ever
joined to a variable other than `$STATE`.

**In support bundles.** `create_support_bundle.sh` collects
`logs/downloader.log` for troubleshooting, and users attach those bundles to
public issues. Its redaction filter therefore strips token- and password-shaped
assignments, `CRED=`/`CREDB64=` lines, Google token prefixes, email addresses,
and IP addresses. The checker fails if any of those rules is removed.

**Known gap, stated honestly.** The sign-in window runs Qt WebEngine with
`QTWEBENGINE_DISABLE_SANDBOX=1`, because Chromium's sandbox does not come up
under PortMaster's Weston/XWayland session on this hardware. That weakens
process isolation for the browser that renders Google's page; it does not put
credentials on anyone else's server. Re-enabling the sandbox is the open item.

---

## What this policy does not claim

The downloader is a prototype, gated to 64-bit H700 devices on Knulli, and
entirely optional — manual APK installation remains fully supported and is the
default path. Nothing here is legal advice. The wider distribution rules for
this repository — no game files, no mirroring, no APK sharing — are in
[LEGAL.md](LEGAL.md), and third-party components are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## The mcbedrock-get helper

`tools/mcbedrock-get/` is the helper users run on Windows or Linux to fetch the
same APKs to a desktop. It carries its own `PROVENANCE.json` and is checked by
the same script, which reports both components:

```
downloader policy checks passed: on-device Google Play downloader; mcbedrock-get Windows/Linux helper
```

The three rules land differently here, because the helper ships **no committed
binary** — the published `mcbedrock-get.exe` and AppImage are build output.

**Rule 1.** The helper is GPL-3.0 with its source in the release archive, and
its licence notices are generated from the actual build environment by
`gen_notices.py` rather than hand-maintained. Two things make that claim
checkable: every line of `requirements.txt` and `requirements-linux.txt` must be
an exact `name==version` pin, so the wheels inside a published executable can be
named after the fact; and `setup-downloader.sh` must build the Play client from
the **pinned upstream commit** recorded in `PROVENANCE.json`. That commit is the
same revision the port's own ARM64 `gplaydl` is built from — bump the two
together, and re-run the script before releasing, because the checker can only
confirm the pin is *recorded*, not that it still compiles. The pin was last
verified to build on 2026-08-21, on Ubuntu 24.04.3 LTS under WSL2, with only
upstream's five `CURLOPT_PUT` deprecation warnings. The checker also fails on a
`git pull`, a `--branch`, or an unpinned shallow clone, and on any binary
appearing in the tree without a manifest entry.
Local build output (`dist/`, `build/`, `build_pyi/`, `.venv/`) is not part of
the tool and is not scanned.

**Rule 2.** The same vocabulary, token-shape, hardcoded-credential and address
scans run over this tree. One deliberate difference: files under `tests/` are
exempt from the address and hardcoded-credential checks, because a fixture
asserting `user_email = "owner@example.com"` is the test doing its job and
fixtures are never shipped. A *real* Google token in a fixture is still caught,
because the token-shape checks apply everywhere.

**Rule 3.** The account holder signs in on Google's own page in an embedded
browser; `gpsoauth` exchanges the resulting one-shot cookie with Google
directly. The long-lived token is written to `account.json` in the user's own
profile directory, created owner-only from the first byte — `0600` inside a
`0700` directory — and it is handed to `gplaydl` **on stdin**, never on a
command line where another process could read it. `PROVENANCE.json` lists every
credential artifact and which module clears it, and the checker fails if a
module stops clearing one, if the permission or stdin handling is weakened, or
if either half of sign-out (`backend.sign_out()`, `signin.forget()`) goes away.
The network allowlist covers the version-list fetch from
`raw.githubusercontent.com` — public metadata, requested with no account
context — alongside Google's own endpoints.

**NOT AN OFFICIAL MINECRAFT PRODUCT. NOT APPROVED BY OR ASSOCIATED WITH MOJANG
OR MICROSOFT.**
