# Release Checklist

Releases are cut by tagging — CI (`.github/workflows/release.yml`) builds the
zip from `staging/` and attaches it to the GitHub release.

Before tagging:

- Make sure `staging/` matches the tested local trees (they must stay
  byte-identical).
- Update `README.md` and `staging/README.md` (version links), `CHANGELOG.md`
  and `staging/CHANGELOG.md`, and `ANNOUNCEMENT.md` if the pitch changed.
- Confirm staging contains no APKs, `libminecraftpe.so`, extracted vanilla
  resource packs, worlds, `versions/`, or `profiles/` — CI runs
  `scripts/check_release_safety.py` on every push and will fail the build,
  but check locally first:

  ```sh
  python scripts/build_release_zips.py --staging staging --version test --out-dir out
  ```

Release:

- Commit, push, then tag: `git tag vX.Y && git push origin vX.Y`.
- CI attaches `minecraftbedrock-X.Y.zip` + `SHA256SUMS.txt` to the release.
- Copy the checksum **from the CI-built `SHA256SUMS.txt`** into the repo's
  `SHA256SUMS.txt` and commit. Never compute it from a locally built zip —
  git's CRLF conversion makes local builds differ from CI's.
- Keep the Mojang/Microsoft unofficial-product disclaimer in the release
  notes, and confirm they include the checksum and the "no game files"
  statement.
