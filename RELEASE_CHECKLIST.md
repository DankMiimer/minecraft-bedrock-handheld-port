# Release Checklist

Before publishing a new release:

- Rebuild the install zip from a clean staging directory.
- Confirm the zip contains no APKs, `libminecraftpe.so`, extracted vanilla
  resource packs, worlds, `versions/`, or `profiles/`.
- Run `python scripts/check_release_safety.py --zip .\minecraftbedrock-1.3.zip`.
- Include `source_release/` or link to exact corresponding source branches.
- Update `README.md`, `ANNOUNCEMENT.md`, `CHANGELOG.md`, and `SHA256SUMS.txt`.
- Compute and verify SHA-256 for the zip.
- Upload the zip as a GitHub Release asset rather than committing it to the
  default branch.
- Keep the Mojang/Microsoft unofficial-product disclaimer in the release notes.
- Confirm the release notes include the checksum and the "no game files"
  statement.

Useful local check:

```powershell
$entries = tar -tf .\minecraftbedrock-1.3.zip
$patterns = '\.apk$|libminecraftpe\.so$|level\.dat$|\.mcworld$|resource_packs/vanilla/|sounds/|textures/blocks/|textures/entity/'
$entries | Select-String -Pattern $patterns
Get-FileHash -Algorithm SHA256 .\minecraftbedrock-1.3.zip
```
