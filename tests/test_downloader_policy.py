#!/usr/bin/env python3
"""Prove scripts/check_downloader_policy.py actually catches rule violations.

A policy checker that only ever prints "passed" is worse than none, so every
detector is exercised against a synthetic repository that starts clean and is
then broken one way at a time. The last test runs the real checkout.
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import pathlib
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
DOWNLOADER = "portmaster/minecraftbedrock/minecraftbedrock/downloader"
GAMEDIR = "portmaster/minecraftbedrock/minecraftbedrock"
HELPER = "tools/mcbedrock-get"


def load_checker():
    path = ROOT / "scripts" / "check_downloader_policy.py"
    spec = importlib.util.spec_from_file_location("check_downloader_policy", path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    # Registered before execution because @dataclass resolves annotations
    # through sys.modules[cls.__module__].
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


policy = load_checker()

HELPER_ELF = b"\x7fELF" + bytes(range(256)) * 4
HELPER_SHA = hashlib.sha256(HELPER_ELF).hexdigest()

RUN_SH = """#!/bin/bash
set -u
umask 077
STATE="${MCPE_DOWNLOADER_STATE:?}"
CREDENTIAL_MANIFEST="$SCRIPT_DIR/credential-artifacts.txt"
credential_paths() { :; }
remove_transient_credentials() {
  while IFS= read -r name; do rm -f "$STATE/$name"; done < <(credential_paths transient)
}
sign_out() {
  while IFS= read -r name; do rm -f "$STATE/$name"; done < <(credential_paths session)
  while IFS= read -r name; do rm -rf "$STATE/$name"; done < <(credential_paths dir)
}
session_ready() { [ -s "$STATE/playdl.conf" ] && [ -s "$STATE/token_cache.conf" ]; }
"""

GUI_SESSION_SH = """#!/bin/bash
set -u
umask 077
CAPTURE="$STATE/google-signin-result.json"
"""

SUPPORT_BUNDLE_SH = """#!/bin/bash
copy_redacted() {
  sed -E \\
    -e 's#(user_token|token|password)([[:space:]]*[=:][[:space:]]*)"?[^"[:space:]]+"?#\\1\\2REDACTED#Ig' \\
    -e 's#(CRED|CREDB64)=[^[:space:]]+#\\1=REDACTED#g' \\
    -e 's#(aas_et|ya29)[./][A-Za-z0-9._~+/=-]+#REDACTED_GOOGLE_TOKEN#g' \\
    -e 's#[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}#REDACTED_EMAIL#g' "$1" >"$2"
}
copy_redacted "$GAMEDIR/logs/downloader.log" "$TMP/downloader.log"
"""

CREDENTIAL_MANIFEST = """# kind path
transient google-signin-result.json
session playdl.conf
session token_cache.conf
dir home
"""

RUNTIME_CONF = """# pinned runtime
APPIMAGE_URL=https://github.com/example-org/launcher/releases/download/nightly/launcher.AppImage
APPIMAGE_SHA256=1111111111111111111111111111111111111111111111111111111111111111
APPIMAGE_SIZE=1024
"""


def provenance_document() -> dict:
    return {
        "schema": 1,
        "component": "test downloader",
        "policy": ["open source", "no bypass", "no third party"],
        "credential_manifest": f"{DOWNLOADER}/credential-artifacts.txt",
        "binaries": [
            {
                "path": f"{DOWNLOADER}/bin/helper",
                "sha256": HELPER_SHA,
                "size": len(HELPER_ELF),
                "arch": "aarch64",
                "role": "test helper",
                "upstream": "https://github.com/example-org/helper",
                "commit": "a" * 40,
                "license": "Apache-2.0",
                "license_file": f"{DOWNLOADER}/bin/LICENSE.helper",
                "build_script": "tools/ondevice-downloader/build-helper.sh",
                "reproducible": False,
            }
        ],
        "pinned_downloads": [
            {
                "config_key": "APPIMAGE",
                "url": "https://github.com/example-org/launcher/releases/download/nightly/launcher.AppImage",
                "sha256": "1" * 64,
                "size": 1024,
                "license": "GPL-3.0-or-later",
                "role": "test runtime",
            }
        ],
        "network": {
            "rule": "only Google sees account data",
            "allowed": [
                {
                    "host": "accounts.google.com",
                    "party": "google",
                    "credentials": True,
                    "purpose": "sign-in page",
                },
                {
                    "host": "github.com",
                    "party": "upstream-artifact",
                    "credentials": False,
                    "purpose": "pinned runtime",
                },
            ],
        },
    }


class PolicyFixture:
    """A minimal repository that satisfies every rule until a test breaks it."""

    def __init__(self, root: pathlib.Path) -> None:
        self.root = root
        self.write("LICENSE", "GNU GENERAL PUBLIC LICENSE Version 3\n")
        self.write(f"{GAMEDIR}/create_support_bundle.sh", SUPPORT_BUNDLE_SH)
        self.write(f"{DOWNLOADER}/run.sh", RUN_SH)
        self.write(f"{DOWNLOADER}/gui-session.sh", GUI_SESSION_SH)
        self.write(f"{DOWNLOADER}/credential-artifacts.txt", CREDENTIAL_MANIFEST)
        self.write(f"{DOWNLOADER}/runtime.conf", RUNTIME_CONF)
        self.write(f"{DOWNLOADER}/device-arm64.conf", "config.native_platforms = [\n    arm64-v8a\n]\n")
        self.write(f"{DOWNLOADER}/device-armhf.conf", "config.native_platforms = [\n    armeabi-v7a\n]\n")
        self.write(f"{DOWNLOADER}/bin/LICENSE.helper", "Apache License Version 2.0\n")
        self.write_bytes(f"{DOWNLOADER}/bin/helper", HELPER_ELF)
        self.write("tools/ondevice-downloader/build-helper.sh", "#!/bin/bash\necho build\n")
        self.write_provenance(provenance_document())

    def write(self, relative: str, text: str) -> None:
        self.write_bytes(relative, text.encode("utf-8"))

    def write_bytes(self, relative: str, data: bytes) -> None:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def append(self, relative: str, text: str) -> None:
        with (self.root / relative).open("a", encoding="utf-8") as handle:
            handle.write(text)

    def write_provenance(self, document: dict) -> None:
        self.write(f"{DOWNLOADER}/PROVENANCE.json", json.dumps(document, indent=4) + "\n")

    def provenance(self) -> dict:
        return json.loads((self.root / f"{DOWNLOADER}/PROVENANCE.json").read_text("utf-8"))

    def check(self) -> list[str]:
        return policy.check(self.root)


HELPER_SETUP_SH = """#!/bin/bash
UPSTREAM_URL="https://github.com/example-org/google-play-api.git"
UPSTREAM_COMMIT="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
git -C "$SRC" fetch --depth 1 origin "$UPSTREAM_COMMIT"
git -C "$SRC" checkout -q --detach "$UPSTREAM_COMMIT"
"""

HELPER_SIGNIN_PY = '''"""Sign-in against https://accounts.google.com/EmbeddedSetup."""
import os


def save(token):
    os.chmod(directory, 0o700)
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT, 0o600)


def forget():
    (data_dir() / "account.json").unlink(missing_ok=True)
'''

HELPER_WSL_PY = '''"""Drives the Play client inside WSL."""


def sign_in(email, master_token):
    script = "cd $PREFIX; umask 077; chmod 600 playdl.conf.new"
    return _run(script, stdin=config)


def sign_out():
    return _run("rm -f playdl.conf token_cache.conf")
'''

HELPER_LINUX_PY = '''"""Drives the Play client on Linux."""
import os


def sign_in(email, master_token):
    os.chmod(temporary, 0o600)


def sign_out():
    _tool("playdl.conf").unlink(missing_ok=True)
    _tool("token_cache.conf").unlink(missing_ok=True)
'''

HELPER_MAIN_PY = '''"""The window and the command line."""


def logout():
    backend.sign_out()
    signin.forget()
'''

HELPER_REQUIREMENTS = """# pure wheels
gpsoauth==2.0.0
pywebview==6.2.1
"""


def helper_provenance() -> dict:
    return {
        "schema": 1,
        "component": "test helper",
        "policy": ["open source", "no workaround", "no third party"],
        "binaries": [],
        "pinned_requirements": [f"{HELPER}/requirements.txt"],
        "built_from_source": {
            "role": "the Play client",
            "upstream": "https://github.com/example-org/google-play-api.git",
            "commit": "b" * 40,
            "license": "Apache-2.0",
            "build_script": f"{HELPER}/setup-downloader.sh",
        },
        "credential_artifacts": [
            {"name": "account.json", "holds": "token", "cleared_by": ["signin.py"]},
            {
                "name": "playdl.conf",
                "holds": "token",
                "cleared_by": ["wsl_backend.py", "linux_backend.py"],
            },
            {
                "name": "token_cache.conf",
                "holds": "session",
                "cleared_by": ["wsl_backend.py", "linux_backend.py"],
            },
        ],
        "network": {
            "rule": "only Google sees account data",
            "allowed": [
                {
                    "host": "accounts.google.com",
                    "party": "google",
                    "credentials": True,
                    "purpose": "sign-in page",
                },
                {
                    "host": "github.com",
                    "party": "upstream-artifact",
                    "credentials": False,
                    "purpose": "pinned source",
                },
            ],
        },
    }


class HelperFixture(PolicyFixture):
    """The mcbedrock-get tree, clean until a test breaks it."""

    def __init__(self, root: pathlib.Path) -> None:
        super().__init__(root)
        self.write(f"{HELPER}/setup-downloader.sh", HELPER_SETUP_SH)
        self.write(f"{HELPER}/signin.py", HELPER_SIGNIN_PY)
        self.write(f"{HELPER}/wsl_backend.py", HELPER_WSL_PY)
        self.write(f"{HELPER}/linux_backend.py", HELPER_LINUX_PY)
        self.write(f"{HELPER}/mcbedrock_get.py", HELPER_MAIN_PY)
        self.write(f"{HELPER}/requirements.txt", HELPER_REQUIREMENTS)
        self.write_helper_provenance(helper_provenance())

    def write_helper_provenance(self, document: dict) -> None:
        self.write(f"{HELPER}/PROVENANCE.json", json.dumps(document, indent=4) + "\n")

    def helper_provenance(self) -> dict:
        return json.loads((self.root / f"{HELPER}/PROVENANCE.json").read_text("utf-8"))


class DownloaderPolicyTests(unittest.TestCase):
    def fixture(self, stack: tempfile.TemporaryDirectory) -> PolicyFixture:
        return PolicyFixture(pathlib.Path(stack.name))

    def broken(self, mutate) -> list[str]:
        with tempfile.TemporaryDirectory() as directory:
            repo = PolicyFixture(pathlib.Path(directory))
            self.assertEqual(repo.check(), [], "fixture was not clean before mutation")
            mutate(repo)
            return repo.check()

    def assertReports(self, errors: list[str], needle: str) -> None:
        self.assertTrue(
            any(needle in error for error in errors),
            f"expected a violation mentioning {needle!r}, got {errors}",
        )

    # Rule 1 -- strictly open source.

    def test_clean_fixture_passes(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(PolicyFixture(pathlib.Path(directory)).check(), [])

    def test_undeclared_binary_is_rejected(self):
        errors = self.broken(
            lambda repo: repo.write_bytes(f"{DOWNLOADER}/bin/extra", b"\x7fELF\x00\x01\x02")
        )
        self.assertReports(errors, "without a PROVENANCE.json entry")

    def test_tampered_binary_is_rejected(self):
        errors = self.broken(
            lambda repo: repo.write_bytes(f"{DOWNLOADER}/bin/helper", HELPER_ELF + b"\x00")
        )
        self.assertReports(errors, "does not match PROVENANCE.json")

    def test_binary_without_build_script_is_rejected(self):
        def mutate(repo):
            (repo.root / "tools/ondevice-downloader/build-helper.sh").unlink()

        self.assertReports(self.broken(mutate), "build script")

    def test_binary_without_license_text_is_rejected(self):
        def mutate(repo):
            (repo.root / f"{DOWNLOADER}/bin/LICENSE.helper").unlink()

        self.assertReports(self.broken(mutate), "licence text")

    def test_upstream_binary_needs_a_pinned_commit(self):
        def mutate(repo):
            document = repo.provenance()
            document["binaries"][0]["commit"] = "nightly"
            repo.write_provenance(document)

        self.assertReports(self.broken(mutate), "pinned 40-character commit")

    def test_in_repo_binary_needs_published_source(self):
        def mutate(repo):
            document = repo.provenance()
            document["binaries"][0]["upstream"] = "this repository"
            document["binaries"][0].pop("commit")
            repo.write_provenance(document)

        self.assertReports(self.broken(mutate), "no published source file")

    # Rule 2 -- no hardcoded bypass or cracked licence.

    def test_bypass_vocabulary_is_rejected(self):
        errors = self.broken(
            lambda repo: repo.append(
                f"{DOWNLOADER}/run.sh", "# fall back to bypassing the license check\n"
            )
        )
        self.assertReports(errors, "protection-measure bypass")

    def test_modified_apk_reference_is_rejected(self):
        errors = self.broken(
            lambda repo: repo.append(f"{DOWNLOADER}/run.sh", "# use the patched apk instead\n")
        )
        self.assertReports(errors, "modified APK")

    def test_policy_allow_marker_permits_deliberate_wording(self):
        errors = self.broken(
            lambda repo: repo.append(
                f"{DOWNLOADER}/run.sh",
                "# No DRM bypass is attempted. policy-allow: states the refusal\n",
            )
        )
        self.assertEqual(errors, [])

    def test_hardcoded_play_credential_is_rejected(self):
        errors = self.broken(
            lambda repo: repo.append(
                f"{DOWNLOADER}/run.sh", 'printf \'user_token = "aTokenValue"\'\n'
            )
        )
        self.assertReports(errors, "hardcoded Play credential")

    def test_embedded_google_token_is_rejected(self):
        errors = self.broken(
            lambda repo: repo.append(
                f"{DOWNLOADER}/run.sh", "TOKEN=aas_et/AKppINZabcdefgh1234567890\n"
            )
        )
        self.assertReports(errors, "Google master token")

    def test_account_address_is_rejected_but_examples_are_allowed(self):
        errors = self.broken(
            lambda repo: repo.append(f"{DOWNLOADER}/run.sh", "# owner: someone@gmail.com\n")
        )
        self.assertReports(errors, "account address baked into the tool")
        self.assertEqual(
            self.broken(
                lambda repo: repo.append(f"{DOWNLOADER}/run.sh", "# owner: you@example.com\n")
            ),
            [],
        )

    def test_device_profile_may_not_carry_an_identifier(self):
        errors = self.broken(
            lambda repo: repo.append(
                f"{DOWNLOADER}/device-arm64.conf", "config.androidId = 3f2a11bb44cc55dd\n"
            )
        )
        self.assertReports(errors, "must declare only")

    def test_shared_device_identifier_is_rejected(self):
        errors = self.broken(
            lambda repo: repo.append(f"{DOWNLOADER}/run.sh", "android_id=3f2a11bb44cc55dd\n")
        )
        self.assertReports(errors, "hardcoded device/GSF identifier")

    # Rule 3 -- credentials never reach a third party.

    def test_credential_file_outside_the_state_directory_is_rejected(self):
        errors = self.broken(
            lambda repo: repo.append(f"{DOWNLOADER}/run.sh", 'cp x "$GAMEDIR/playdl.conf"\n')
        )
        self.assertReports(errors, "instead of the private state directory")

    def test_sign_out_must_cover_every_artifact_kind(self):
        def mutate(repo):
            text = (repo.root / f"{DOWNLOADER}/run.sh").read_text("utf-8")
            repo.write(
                f"{DOWNLOADER}/run.sh", text.replace("credential_paths dir", "true")
            )

        self.assertReports(self.broken(mutate), "never removes 'dir'")

    def test_missing_umask_is_rejected(self):
        def mutate(repo):
            text = (repo.root / f"{DOWNLOADER}/gui-session.sh").read_text("utf-8")
            repo.write(f"{DOWNLOADER}/gui-session.sh", text.replace("umask 077", ""))

        self.assertReports(self.broken(mutate), "expected hardening")

    def test_unlisted_host_is_rejected(self):
        errors = self.broken(
            lambda repo: repo.append(
                f"{DOWNLOADER}/run.sh", 'curl -fL "https://tokens.example-relay.net/save"\n'
            )
        )
        self.assertReports(errors, "contacts unlisted host tokens.example-relay.net")

    def test_non_google_host_may_not_receive_credentials(self):
        def mutate(repo):
            document = repo.provenance()
            document["network"]["allowed"][1]["credentials"] = True
            repo.write_provenance(document)

        self.assertReports(self.broken(mutate), "not a Google endpoint")

    def test_runtime_pin_drift_is_rejected(self):
        def mutate(repo):
            text = (repo.root / f"{DOWNLOADER}/runtime.conf").read_text("utf-8")
            repo.write(f"{DOWNLOADER}/runtime.conf", text.replace("1" * 64, "2" * 64))

        self.assertReports(self.broken(mutate), "PROVENANCE.json says")

    def test_weakened_support_bundle_redaction_is_rejected(self):
        def mutate(repo):
            text = (repo.root / f"{GAMEDIR}/create_support_bundle.sh").read_text("utf-8")
            repo.write(
                f"{GAMEDIR}/create_support_bundle.sh", text.replace("REDACTED_EMAIL", "KEEP")
            )

        self.assertReports(self.broken(mutate), "redaction no longer covers REDACTED_EMAIL")

    # The real thing.

    def test_this_checkout_satisfies_the_policy(self):
        self.assertEqual(policy.check(ROOT), [])


class HelperPolicyTests(unittest.TestCase):
    """The same three rules, applied to the Windows/Linux helper tree."""

    def broken(self, mutate) -> list[str]:
        with tempfile.TemporaryDirectory() as directory:
            repo = HelperFixture(pathlib.Path(directory))
            self.assertEqual(repo.check(), [], "fixture was not clean before mutation")
            mutate(repo)
            return repo.check()

    assertReports = DownloaderPolicyTests.assertReports

    def test_clean_helper_fixture_passes(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(HelperFixture(pathlib.Path(directory)).check(), [])

    # Rule 1 -- strictly open source.

    def test_floating_requirement_is_rejected(self):
        errors = self.broken(
            lambda repo: repo.append(f"{HELPER}/requirements.txt", "requests>=2.0\n")
        )
        self.assertReports(errors, "requirement is not pinned")

    def test_missing_requirement_file_is_rejected(self):
        def mutate(repo):
            (repo.root / f"{HELPER}/requirements.txt").unlink()

        self.assertReports(self.broken(mutate), "declared requirement file is missing")

    def test_unpinned_upstream_clone_is_rejected(self):
        def mutate(repo):
            repo.write(
                f"{HELPER}/setup-downloader.sh",
                "#!/bin/bash\n"
                'git clone --depth 1 https://github.com/example-org/google-play-api.git "$SRC"\n',
            )

        errors = self.broken(mutate)
        self.assertReports(errors, "follows a moving reference")

    def test_git_pull_is_rejected(self):
        errors = self.broken(
            lambda repo: repo.append(f"{HELPER}/setup-downloader.sh", 'git pull --ff-only\n')
        )
        self.assertReports(errors, "follows a moving reference (git pull)")

    def test_commit_drift_between_manifest_and_script_is_rejected(self):
        def mutate(repo):
            document = repo.helper_provenance()
            document["built_from_source"]["commit"] = "c" * 40
            repo.write_helper_provenance(document)

        self.assertReports(self.broken(mutate), "does not pin the commit")

    def test_committed_binary_in_the_helper_tree_is_rejected(self):
        errors = self.broken(
            lambda repo: repo.write_bytes(f"{HELPER}/mcbedrock-get.exe", b"MZ\x00\x90\x00\x03")
        )
        self.assertReports(errors, "without a PROVENANCE.json entry")

    def test_local_build_output_is_not_part_of_the_tool(self):
        def mutate(repo):
            repo.write_bytes(f"{HELPER}/dist/mcbedrock-get.exe", b"MZ\x00\x90\x00\x03")
            repo.write(f"{HELPER}/build/log.txt.keep", "https://telemetry.example-relay.net/x\n")

        self.assertEqual(self.broken(mutate), [])

    # Rule 2 -- no hardcoded bypass or cracked licence.

    def test_invented_addresses_in_fixtures_are_allowed(self):
        errors = self.broken(
            lambda repo: repo.write(
                f"{HELPER}/tests/test_backend.py",
                'EXPECTED = \'user_email = "person@gmail.com"\'\n',
            )
        )
        self.assertEqual(errors, [])

    def test_a_real_token_in_a_fixture_is_still_rejected(self):
        errors = self.broken(
            lambda repo: repo.write(
                f"{HELPER}/tests/test_backend.py",
                'TOKEN = "aas_et/AKppINZabcdefgh1234567890"\n',
            )
        )
        self.assertReports(errors, "Google master token")

    def test_bypass_vocabulary_is_rejected_in_the_helper(self):
        errors = self.broken(
            lambda repo: repo.append(
                f"{HELPER}/mcbedrock_get.py", "# fall back to skipping the ownership check\n"
            )
        )
        self.assertReports(errors, "protection-measure bypass")

    # Rule 3 -- credentials never reach a third party.

    def test_weakened_token_permissions_are_rejected(self):
        def mutate(repo):
            text = (repo.root / f"{HELPER}/signin.py").read_text("utf-8")
            repo.write(f"{HELPER}/signin.py", text.replace("0o600", "0o644"))

        self.assertReports(self.broken(mutate), "expected hardening '0o600' is gone")

    def test_token_reaching_a_command_line_is_rejected(self):
        def mutate(repo):
            text = (repo.root / f"{HELPER}/wsl_backend.py").read_text("utf-8")
            repo.write(f"{HELPER}/wsl_backend.py", text.replace("stdin=config", "argv + [config]"))

        self.assertReports(self.broken(mutate), "expected hardening 'stdin=config' is gone")

    def test_an_artifact_no_longer_cleared_is_rejected(self):
        def mutate(repo):
            text = (repo.root / f"{HELPER}/linux_backend.py").read_text("utf-8")
            repo.write(
                f"{HELPER}/linux_backend.py",
                text.replace('_tool("token_cache.conf").unlink(missing_ok=True)\n', ""),
            )

        self.assertReports(self.broken(mutate), "no longer clears token_cache.conf")

    def test_sign_out_paths_must_both_exist(self):
        def mutate(repo):
            text = (repo.root / f"{HELPER}/mcbedrock_get.py").read_text("utf-8")
            repo.write(f"{HELPER}/mcbedrock_get.py", text.replace("signin.forget()", "pass"))

        self.assertReports(self.broken(mutate), "expected hardening 'signin.forget()' is gone")

    def test_unlisted_host_is_rejected_in_the_helper(self):
        errors = self.broken(
            lambda repo: repo.append(
                f"{HELPER}/mcbedrock_get.py", 'RELAY = "https://tokens.example-relay.net/save"\n'
            )
        )
        self.assertReports(errors, "contacts unlisted host tokens.example-relay.net")

    def test_non_google_host_may_not_receive_credentials(self):
        def mutate(repo):
            document = repo.helper_provenance()
            document["network"]["allowed"][1]["credentials"] = True
            repo.write_helper_provenance(document)

        self.assertReports(self.broken(mutate), "not a Google endpoint")


if __name__ == "__main__":
    unittest.main(verbosity=2)
