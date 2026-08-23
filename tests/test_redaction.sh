#!/bin/bash
# The redaction filter must remove addresses and credentials without destroying
# the fields a device report exists to carry.
#
# Bedrock versions are shaped exactly like IPv4 addresses -- 1.16.221.01,
# 1.14.60.5-943146005-arm64 -- and the address filter used to rewrite them to
# REDACTED_IP, deleting the single most useful field in every support bundle.
# Caught by running the self-test on the reference RG34XX-SP.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE="$ROOT/portmaster/minecraftbedrock/minecraftbedrock/create_support_bundle.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Use the shipped filter itself, not a copy of it.
sed -n '/^copy_redacted() {/,/^}/p' "$BUNDLE" >"$TMP/filter.sh"
grep -q 'REDACTED_IP' "$TMP/filter.sh" || { echo "could not extract copy_redacted" >&2; exit 1; }
# shellcheck disable=SC1090
. "$TMP/filter.sh"

check() { # label input expected-substring should_appear(1/0)
  local label="$1" input="$2" needle="$3" want="$4"
  printf '%s\n' "$input" >"$TMP/in.txt"
  copy_redacted "$TMP/in.txt" "$TMP/out.txt"
  if grep -qF "$needle" "$TMP/out.txt"; then found=1; else found=0; fi
  if [ "$found" != "$want" ]; then
    echo "FAIL: $label" >&2
    echo "  in : $input" >&2
    echo "  out: $(cat "$TMP/out.txt")" >&2
    echo "  expected '$needle' present=$want" >&2
    exit 1
  fi
}

# --- what must survive ---------------------------------------------------------
check "bare Bedrock version"      "bedrock=1.16.221.01 code=971622101" "1.16.221.01" 1
check "version directory name"    "versions/1.14.60.5-943146005-arm64" "1.14.60.5-943146005-arm64" 1
check "newest tested version"     "1.21.51.01-972105101-arm64"         "1.21.51.01-972105101-arm64" 1
check "older armhf anchor"        "1.16.40.02 armhf"                   "1.16.40.02" 1
check "port version"              "port_version=2.0.0-rc.10"           "2.0.0-rc.10" 1
check "a sha256 is untouched"     "sha=45382be72491ec2cbe5dd4d1262989ad" "45382be72491ec2cbe5dd4d1262989ad" 1

# --- what must not survive -----------------------------------------------------
check "private LAN address"       "peer 192.168.1.25 joined"  "192.168.1.25"  0
check "private LAN address gone"  "peer 192.168.1.25 joined"  "REDACTED_IP"   1
check "other RFC1918 address"     "host 10.0.0.1"             "10.0.0.1"      0
check "public address"            "resolved 8.8.4.4"          "8.8.4.4"       0
check "email address"             "user foo.bar+x@gmail.com"  "REDACTED_EMAIL" 1
check "email address gone"        "user foo.bar+x@gmail.com"  "gmail.com"     0
check "credential assignment"     'user_token=abc123xyz'      "abc123xyz"     0
check "base64 credential"         'CREDB64=aGVsbG8gd29ybGQ='  "aGVsbG8gd29ybGQ=" 0
check "google token"              "aas_et/AKppINb1234"        "REDACTED_GOOGLE_TOKEN" 1
check "url credentials"           "https://someone@example"   "someone@"      0

# --- the placeholder must never leak ------------------------------------------
printf '1.16.221.01 and 192.168.1.25\n' >"$TMP/in.txt"
copy_redacted "$TMP/in.txt" "$TMP/out.txt"
grep -q '@D@' "$TMP/out.txt" && { echo "FAIL: placeholder leaked into output" >&2; exit 1; }
grep -q '1.16.221.01' "$TMP/out.txt" || { echo "FAIL: version lost alongside an address" >&2; exit 1; }
grep -q 'REDACTED_IP' "$TMP/out.txt" || { echo "FAIL: address kept alongside a version" >&2; exit 1; }

# --- the self-test filter must agree with the bundle's -------------------------
SELFTEST="$ROOT/portmaster/minecraftbedrock/minecraftbedrock/selftest.sh"
for expr in '@D@' 'REDACTED_EMAIL' 'REDACTED_IP'; do
  grep -qF "$expr" "$SELFTEST" ||
    { echo "FAIL: selftest.sh redaction lost $expr" >&2; exit 1; }
done

echo "redaction tests passed"
