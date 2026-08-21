#!/usr/bin/env python3
"""Enforce the three safety rules this project's Play downloaders live by.

    1. The tool stays strictly open source.
    2. No generic bypass or cracked licence is ever hardcoded.
    3. No user credential is stored on or transmitted through a third party.

The rules are only worth anything if a machine re-checks them, so this script
is the executable form of DOWNLOADER-POLICY.md. It covers two components, each
carrying its own PROVENANCE.json:

    * the on-device Google Play downloader shipped inside the port, and
    * the mcbedrock-get helper users run on Windows or Linux.

The three rule checks are shared; each component adds the checks that only make
sense for it. A component whose tree is absent from the checkout is skipped, so
a partial checkout does not fail on what it does not contain.

A source line that must legitimately mention otherwise-forbidden vocabulary
(policy prose, a refusal message) can opt out by carrying a "policy-allow:"
marker with the reason on that same line.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import sys
from dataclasses import dataclass, field
from typing import Callable

Posix = pathlib.PurePosixPath

DOWNLOADER = Posix("portmaster/minecraftbedrock/minecraftbedrock/downloader")
BUILD_TOOLS = Posix("tools/ondevice-downloader")
HELPER = Posix("tools/mcbedrock-get")
RUNTIME_CONF = DOWNLOADER / "runtime.conf"
CREDENTIAL_MANIFEST = DOWNLOADER / "credential-artifacts.txt"
SUPPORT_BUNDLE = Posix(
    "portmaster/minecraftbedrock/minecraftbedrock/create_support_bundle.sh"
)

BASE_SKIPPED_DIRECTORIES = {"__pycache__", ".git", ".venv", "node_modules"}
SKIPPED_SUFFIXES = {".pyc", ".pyo", ".log"}
ALLOW_MARKER = "policy-allow:"

URL_PATTERN = re.compile(r"https?://([A-Za-z0-9][A-Za-z0-9._-]*[A-Za-z0-9])")
BINARY_URL_PATTERN = re.compile(rb"https?://([A-Za-z0-9][A-Za-z0-9._-]*[A-Za-z0-9])")
COMMIT_PATTERN = re.compile(r"^[0-9a-f]{40}$")
PINNED_REQUIREMENT = re.compile(r"^[A-Za-z0-9._-]+(\[[A-Za-z0-9,._-]+\])?==[A-Za-z0-9.+*!-]+$")
EXAMPLE_DOMAINS = ("example.com", "example.org", "example.net", "invalid", "localhost")

# Google's real token shapes. These have no legitimate place in source: a
# checked-in one is either a leaked credential or a shared account.
TOKEN_SHAPES = [
    (re.compile(r"aas_et/[A-Za-z0-9._~+/=-]{8,}"), "Google master token"),
    (re.compile(r"oauth2_4/[A-Za-z0-9._~+/=-]{8,}"), "Google OAuth token"),
    (re.compile(r"\bya29\.[A-Za-z0-9._~+/=-]{8,}"), "Google access token"),
]

# Vocabulary that describes defeating a protection measure rather than using
# the account holder's own entitlement.
BYPASS_PATTERNS = [
    (re.compile(r"\bcrack(ed|s|ing)?\b", re.I), "cracked-software reference"),
    (re.compile(r"\bpirat(e|ed|ing|cy)\b", re.I), "piracy reference"),
    (
        re.compile(r"licen[cs]e[\s_-]*(bypass|crack|patch|skip|remov)", re.I),
        "licence bypass",
    ),
    (
        re.compile(
            # The trailing [a-z]{0,4} catches the inflections -- bypassing,
            # skipped, circumvents -- without a list of English endings.
            r"\b(bypass|circumvent|defeat|skip|disable)[a-z]{0,4}[\s_-]*"
            r"(the[\s_-]*)?(licen[cs]e|drm|entitlement|ownership|purchase|"
            r"signature[\s_-]*check)",
            re.I,
        ),
        "protection-measure bypass",
    ),
    (re.compile(r"\b(modded|patched|repack(ed)?)[\s_-]*apk\b", re.I), "modified APK"),
    (
        re.compile(r"\bunlock(ed)?[\s_-]*(premium|paid|full[\s_-]*version)\b", re.I),
        "entitlement unlock",
    ),
    (re.compile(r"\bfree[\s_-]*minecraft\b", re.I), "free-copy reference"),
    (
        re.compile(r"\bshared[\s_-]*(google[\s_-]*|play[\s_-]*)?account\b", re.I),
        "shared account",
    ),
    (re.compile(r"\bmock[\s_-]*(account|licen[cs]e|entitlement)\b", re.I), "mock entitlement"),
]

# Credentials must always come from the signed-in user at run time.
HARDCODED_PATTERNS = [
    (
        re.compile(r"""user_(token|email)\s*=\s*["'][^"'{}\n]+["']"""),
        "hardcoded Play credential",
    ),
    (
        re.compile(
            r"""\b(android_?id|gsf_?id|device_?id)\s*[=:]\s*["']?[0-9a-fA-F]{12,}""",
            re.I,
        ),
        "hardcoded device/GSF identifier",
    ),
]

EMAIL_PATTERN = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")

# Redaction rules create_support_bundle.sh must keep, because it copies the
# downloader log into an archive users attach to public issues.
REQUIRED_REDACTIONS = ("user_token", "REDACTED_GOOGLE_TOKEN", "REDACTED_EMAIL", "CREDB64")

REQUIRED_SHELL_HARDENING = {
    DOWNLOADER / "run.sh": ("umask 077", "credential-artifacts.txt"),
    DOWNLOADER / "gui-session.sh": ("umask 077",),
}

# The helper hands the account token to gplaydl on both platforms. These are
# the properties that keep it off a command line and off other users' eyes.
HELPER_CREDENTIAL_HARDENING = {
    HELPER / "signin.py": ("0o600", "0o700", "os.open("),
    HELPER / "wsl_backend.py": ("umask 077", "chmod 600", "stdin=config"),
    HELPER / "linux_backend.py": ("os.chmod(temporary, 0o600)",),
    HELPER / "mcbedrock_get.py": ("backend.sign_out()", "signin.forget()"),
}


# --------------------------------------------------------------------------
# tree walking
# --------------------------------------------------------------------------

def is_text(data: bytes) -> bool:
    try:
        data.decode("utf-8")
    except UnicodeDecodeError:
        return False
    return b"\x00" not in data


def walk(root: pathlib.Path, relative: Posix, skip: set[str] | frozenset[str] = frozenset()):
    """Yield (posix path, bytes) for every file under one tracked subtree."""
    base = root / pathlib.Path(relative)
    if not base.is_dir():
        return
    skipped = BASE_SKIPPED_DIRECTORIES | set(skip)
    for path in sorted(base.rglob("*")):
        if not path.is_file():
            continue
        parts = path.relative_to(root).parts
        if any(part in skipped for part in parts):
            continue
        if path.suffix in SKIPPED_SUFFIXES:
            continue
        yield Posix(*parts), path.read_bytes()


# --------------------------------------------------------------------------
# components
# --------------------------------------------------------------------------

@dataclass(frozen=True)
class Component:
    """One tool governed by the policy, and the checks that apply to it."""

    name: str
    tree: Posix
    extra_trees: tuple[Posix, ...] = ()
    prose: frozenset[Posix] = frozenset()
    fixture_dirs: frozenset[str] = frozenset()
    skip_dirs: frozenset[str] = frozenset()
    extra_checks: tuple[Callable[..., list[str]], ...] = field(default=())

    @property
    def provenance(self) -> Posix:
        return self.tree / "PROVENANCE.json"

    @property
    def trees(self) -> tuple[Posix, ...]:
        return (self.tree,) + self.extra_trees


# --------------------------------------------------------------------------
# rule 1 -- strictly open source
# --------------------------------------------------------------------------

def check_open_source(root: pathlib.Path, component: Component, provenance: dict) -> list[str]:
    """Every shipped executable has published source and a licence."""
    errors: list[str] = []
    declared: dict[str, dict] = {}

    if not provenance.get("policy"):
        errors.append(f"{component.provenance}: does not state the policy it is held to")

    for index, entry in enumerate(provenance.get("binaries", [])):
        path = entry.get("path")
        if not path:
            errors.append(f"{component.provenance}: binaries[{index}] has no path")
            continue
        declared[path] = entry
        target = root / pathlib.Path(path)
        if not target.is_file():
            errors.append(f"{component.provenance}: {path} is declared but missing from the tree")
            continue
        data = target.read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        if digest != entry.get("sha256"):
            errors.append(f"{path}: sha256 {digest} does not match PROVENANCE.json")
        if len(data) != entry.get("size"):
            errors.append(f"{path}: size {len(data)} does not match PROVENANCE.json")

        upstream = entry.get("upstream", "")
        if upstream == "this repository":
            source = entry.get("source", "")
            if not source or not (root / pathlib.Path(source)).is_file():
                errors.append(f"{path}: in-repo binary has no published source file")
        elif upstream.startswith("https://"):
            if not COMMIT_PATTERN.match(str(entry.get("commit", ""))):
                errors.append(f"{path}: upstream binary has no pinned 40-character commit")
        else:
            errors.append(f"{path}: upstream must be an https URL or 'this repository'")

        if not entry.get("license"):
            errors.append(f"{path}: no licence recorded")
        license_file = entry.get("license_file", "")
        if not license_file or not (root / pathlib.Path(license_file)).is_file():
            errors.append(f"{path}: licence text {license_file or '(unset)'} is missing")
        build_script = entry.get("build_script", "")
        if not build_script or not (root / pathlib.Path(build_script)).is_file():
            errors.append(f"{path}: build script {build_script or '(unset)'} is missing")

    for relative, data in walk(root, component.tree, component.skip_dirs):
        if is_text(data):
            continue
        if str(relative) not in declared:
            errors.append(
                f"{relative}: binary file is shipped without a PROVENANCE.json entry"
            )
    return errors


# --------------------------------------------------------------------------
# rule 2 -- no hardcoded bypass or cracked licence
# --------------------------------------------------------------------------

def check_no_bypass(root: pathlib.Path, component: Component, provenance: dict) -> list[str]:
    """Nothing in the tool hardcodes a bypass or a stolen credential."""
    errors: list[str] = []
    for subtree in component.trees:
        for relative, data in walk(root, subtree, component.skip_dirs):
            if not is_text(data):
                for pattern, label in TOKEN_SHAPES:
                    if pattern.search(data.decode("latin-1")):
                        errors.append(f"{relative}: shipped binary embeds a {label}")
                continue
            checks = list(TOKEN_SHAPES)
            if relative not in component.prose:
                checks += BYPASS_PATTERNS
            # A test fixture asserting `user_email = "owner@example.com"` is
            # the test doing its job, and fixtures are never shipped. A real
            # credential in one is still caught by the token-shape checks,
            # which apply everywhere.
            fixture = any(part in component.fixture_dirs for part in relative.parts)
            if not fixture:
                checks += HARDCODED_PATTERNS
            for number, line in enumerate(data.decode("utf-8").splitlines(), start=1):
                if ALLOW_MARKER in line:
                    continue
                for pattern, label in checks:
                    match = pattern.search(line)
                    if match:
                        errors.append(f"{relative}:{number}: {label}: {match.group(0)!r}")
                if fixture:
                    continue
                for match in EMAIL_PATTERN.finditer(line):
                    address = match.group(0)
                    if not any(address.lower().endswith(domain) for domain in EXAMPLE_DOMAINS):
                        errors.append(
                            f"{relative}:{number}: account address baked into the tool: {address!r}"
                        )
    return errors


# --------------------------------------------------------------------------
# rule 3 -- credentials never reach a third party
# --------------------------------------------------------------------------

def check_network(root: pathlib.Path, component: Component, provenance: dict) -> list[str]:
    """Only Google sees credentials, and nothing else is contacted at all."""
    errors: list[str] = []
    network = provenance.get("network", {})
    allowed: dict[str, dict] = {}
    for index, entry in enumerate(network.get("allowed", [])):
        host = entry.get("host")
        if not host:
            errors.append(f"{component.provenance}: network.allowed[{index}] has no host")
            continue
        for required in ("party", "credentials", "purpose"):
            if required not in entry:
                errors.append(f"{component.provenance}: allowlist entry {host} has no {required}")
        if entry.get("credentials") and entry.get("party") != "google":
            errors.append(
                f"{component.provenance}: {host} is allowed to receive credentials but is "
                "not a Google endpoint"
            )
        allowed[host] = entry

    for subtree in component.trees:
        for relative, data in walk(root, subtree, component.skip_dirs):
            if is_text(data):
                hosts = set(URL_PATTERN.findall(data.decode("utf-8")))
            else:
                hosts = {host.decode("ascii") for host in BINARY_URL_PATTERN.findall(data)}
            for host in sorted(hosts):
                if host not in allowed:
                    errors.append(f"{relative}: contacts unlisted host {host}")
    return errors


# --------------------------------------------------------------------------
# on-device downloader only
# --------------------------------------------------------------------------

def check_device_profiles(root: pathlib.Path, component: Component, provenance: dict) -> list[str]:
    """The shipped Play device profiles declare an ABI and no identity."""
    errors: list[str] = []
    for name in ("device-arm64.conf", "device-armhf.conf"):
        path = root / pathlib.Path(DOWNLOADER / name)
        if not path.is_file():
            errors.append(f"{DOWNLOADER / name}: missing Play device profile")
            continue
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            stripped = line.strip()
            if not stripped or stripped in {"]", "["}:
                continue
            if not re.match(r"^(config\.native_platforms\s*=\s*\[|[A-Za-z0-9_-]+,?)$", stripped):
                errors.append(
                    f"{DOWNLOADER / name}:{number}: device profile must declare only "
                    f"native_platforms, found {stripped!r}"
                )
    return errors


def parse_credential_manifest(text: str) -> tuple[dict[str, list[str]], list[str]]:
    entries: dict[str, list[str]] = {"transient": [], "session": [], "dir": []}
    errors: list[str] = []
    for number, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split()
        if len(fields) != 2:
            errors.append(f"{CREDENTIAL_MANIFEST}:{number}: expected '<kind> <path>'")
            continue
        kind, value = fields
        if kind not in entries:
            errors.append(f"{CREDENTIAL_MANIFEST}:{number}: unknown kind {kind!r}")
            continue
        if value.startswith("/") or ".." in Posix(value).parts:
            errors.append(
                f"{CREDENTIAL_MANIFEST}:{number}: {value} escapes the private state directory"
            )
            continue
        entries[kind].append(value)
    return entries, errors


def check_credential_containment(
    root: pathlib.Path, component: Component, provenance: dict
) -> list[str]:
    """Account data only ever lands in the port's private state directory."""
    manifest_path = root / pathlib.Path(CREDENTIAL_MANIFEST)
    if not manifest_path.is_file():
        return [f"{CREDENTIAL_MANIFEST}: missing credential manifest"]

    entries, errors = parse_credential_manifest(manifest_path.read_text(encoding="utf-8"))
    names = entries["transient"] + entries["session"]

    for relative, data in walk(root, DOWNLOADER, component.skip_dirs):
        if relative.suffix != ".sh" or not is_text(data):
            continue
        text = data.decode("utf-8")
        for name in names:
            for match in re.finditer(
                r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?/" + re.escape(name) + r"(?![A-Za-z0-9._-])",
                text,
            ):
                if match.group(1) != "STATE":
                    errors.append(
                        f"{relative}: credential file {name} is written under "
                        f"${match.group(1)} instead of the private state directory"
                    )

    run_sh = (root / pathlib.Path(DOWNLOADER / "run.sh")).read_text(encoding="utf-8")
    for kind in ("transient", "session", "dir"):
        if f"credential_paths {kind}" not in run_sh:
            errors.append(f"{DOWNLOADER / 'run.sh'}: never removes '{kind}' credential artifacts")

    for path, needles in REQUIRED_SHELL_HARDENING.items():
        target = root / pathlib.Path(path)
        if not target.is_file():
            errors.append(f"{path}: missing downloader script")
            continue
        text = target.read_text(encoding="utf-8")
        for needle in needles:
            if needle not in text:
                errors.append(f"{path}: expected hardening {needle!r} is gone")

    bundle = root / pathlib.Path(SUPPORT_BUNDLE)
    if not bundle.is_file():
        errors.append(f"{SUPPORT_BUNDLE}: missing support-bundle script")
    else:
        text = bundle.read_text(encoding="utf-8")
        if "copy_redacted" not in text or "logs/downloader.log" not in text:
            errors.append(f"{SUPPORT_BUNDLE}: downloader log is not copied through redaction")
        for needle in REQUIRED_REDACTIONS:
            if needle not in text:
                errors.append(f"{SUPPORT_BUNDLE}: redaction no longer covers {needle}")
    return errors


def check_runtime_pins(root: pathlib.Path, component: Component, provenance: dict) -> list[str]:
    """The optional runtime downloads stay size- and SHA-256-pinned."""
    errors: list[str] = []
    runtime = root / pathlib.Path(RUNTIME_CONF)
    if not runtime.is_file():
        return [f"{RUNTIME_CONF}: missing pinned runtime configuration"]
    values = dict(
        line.split("=", 1)
        for line in runtime.read_text(encoding="utf-8").splitlines()
        if "=" in line and not line.lstrip().startswith("#")
    )
    for entry in provenance.get("pinned_downloads", []):
        key = entry.get("config_key", "")
        for suffix, name in (("_URL", "url"), ("_SHA256", "sha256"), ("_SIZE", "size")):
            expected = str(entry.get(name, ""))
            actual = values.get(f"{key}{suffix}")
            if actual is None:
                errors.append(f"{RUNTIME_CONF}: {key}{suffix} is not pinned")
            elif actual != expected:
                errors.append(
                    f"{RUNTIME_CONF}: {key}{suffix} is {actual}, PROVENANCE.json says {expected}"
                )
    return errors


# --------------------------------------------------------------------------
# mcbedrock-get helper only
# --------------------------------------------------------------------------

def check_pinned_requirements(
    root: pathlib.Path, component: Component, provenance: dict
) -> list[str]:
    """The helper bundles nothing it cannot name an exact version for.

    The published executable embeds these wheels, so a floating requirement
    would make its corresponding source unknowable after the fact.
    """
    errors: list[str] = []
    declared = provenance.get("pinned_requirements", [])
    if not declared:
        errors.append(f"{component.provenance}: names no pinned requirement files")
    for relative in declared:
        path = root / pathlib.Path(relative)
        if not path.is_file():
            errors.append(f"{relative}: declared requirement file is missing")
            continue
        for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            if not PINNED_REQUIREMENT.match(line):
                errors.append(f"{relative}:{number}: requirement is not pinned: {line!r}")
    return errors


def check_upstream_pin(root: pathlib.Path, component: Component, provenance: dict) -> list[str]:
    """The Play client the helper builds comes from a known revision.

    Cloning a default branch would mean nobody -- including the user -- could
    say afterwards which source produced the binary they ran.
    """
    errors: list[str] = []
    built = provenance.get("built_from_source")
    if not built:
        return [f"{component.provenance}: does not record what the helper builds from source"]

    commit = str(built.get("commit", ""))
    upstream = str(built.get("upstream", ""))
    if not COMMIT_PATTERN.match(commit):
        errors.append(f"{component.provenance}: built_from_source has no pinned 40-character commit")
    if not upstream.startswith("https://"):
        errors.append(f"{component.provenance}: built_from_source has no https upstream")
    if not built.get("license"):
        errors.append(f"{component.provenance}: built_from_source records no licence")

    relative = built.get("build_script", "")
    path = root / pathlib.Path(relative) if relative else None
    if not relative or path is None or not path.is_file():
        errors.append(f"{component.provenance}: build script {relative or '(unset)'} is missing")
        return errors

    script = path.read_text(encoding="utf-8")
    if commit and commit not in script:
        errors.append(f"{relative}: does not pin the commit PROVENANCE.json records")
    if upstream and upstream not in script:
        errors.append(f"{relative}: does not clone the upstream PROVENANCE.json records")
    for floating in ("git pull", "--branch", "git clone --depth 1 https://"):
        if floating in script:
            errors.append(f"{relative}: follows a moving reference ({floating})")
    return errors


def check_helper_credentials(
    root: pathlib.Path, component: Component, provenance: dict
) -> list[str]:
    """The account token stays owner-only, off command lines, and clearable."""
    errors: list[str] = []
    for path, needles in HELPER_CREDENTIAL_HARDENING.items():
        target = root / pathlib.Path(path)
        if not target.is_file():
            errors.append(f"{path}: missing helper module")
            continue
        text = target.read_text(encoding="utf-8")
        for needle in needles:
            if needle not in text:
                errors.append(f"{path}: expected hardening {needle!r} is gone")

    artifacts = provenance.get("credential_artifacts", [])
    if not artifacts:
        errors.append(f"{component.provenance}: names no credential artifacts")
    for entry in artifacts:
        name = entry.get("name", "")
        cleared_by = entry.get("cleared_by") or []
        if not name:
            errors.append(f"{component.provenance}: a credential artifact has no name")
            continue
        if not cleared_by:
            errors.append(f"{component.provenance}: {name} names nothing that clears it")
        for module in cleared_by:
            target = root / pathlib.Path(component.tree / module)
            if not target.is_file():
                errors.append(f"{component.tree / module}: named as clearing {name}, but missing")
            elif name not in target.read_text(encoding="utf-8"):
                errors.append(f"{component.tree / module}: no longer clears {name}")
    return errors


# --------------------------------------------------------------------------
# wiring
# --------------------------------------------------------------------------

COMPONENTS = (
    Component(
        name="on-device Google Play downloader",
        tree=DOWNLOADER,
        extra_trees=(BUILD_TOOLS,),
        # PROVENANCE.json carries the machine-readable copy of the policy
        # statement, so it necessarily names the things the policy forbids.
        # Credential and token checks still apply to it; only the vocabulary
        # scan is waived.
        prose=frozenset({DOWNLOADER / "PROVENANCE.json"}),
        extra_checks=(check_device_profiles, check_credential_containment, check_runtime_pins),
    ),
    Component(
        name="mcbedrock-get Windows/Linux helper",
        tree=HELPER,
        prose=frozenset({HELPER / "PROVENANCE.json"}),
        fixture_dirs=frozenset({"tests"}),
        # Local build output, never part of the published source.
        skip_dirs=frozenset({"dist", "build", "build_pyi"}),
        extra_checks=(check_pinned_requirements, check_upstream_pin, check_helper_credentials),
    ),
)

SHARED_CHECKS = (check_open_source, check_no_bypass, check_network)


def check_component(root: pathlib.Path, component: Component) -> list[str]:
    path = root / pathlib.Path(component.provenance)
    if not path.is_file():
        return [f"{component.provenance}: missing provenance manifest"]
    try:
        provenance = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        return [f"{component.provenance}: unreadable provenance manifest: {error}"]

    errors: list[str] = []
    for rule in SHARED_CHECKS + tuple(component.extra_checks):
        errors.extend(rule(root, component, provenance))
    return errors


def check(root: pathlib.Path, components=COMPONENTS) -> list[str]:
    errors: list[str] = []
    for component in components:
        # A checkout that does not contain a component is not a violation.
        if not (root / pathlib.Path(component.tree)).is_dir():
            continue
        errors.extend(check_component(root, component))
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        default=str(pathlib.Path(__file__).resolve().parents[1]),
        help="repository root to check (default: this checkout)",
    )
    args = parser.parse_args()
    root = pathlib.Path(args.root).resolve()
    errors = check(root)
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        print(f"downloader policy: {len(errors)} violation(s)", file=sys.stderr)
        return 1
    checked = [c.name for c in COMPONENTS if (root / pathlib.Path(c.tree)).is_dir()]
    print("downloader policy checks passed: " + "; ".join(checked))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
