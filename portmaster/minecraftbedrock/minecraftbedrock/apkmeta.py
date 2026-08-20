#!/usr/bin/env python3
"""Inspect and transactionally install user-supplied Bedrock APK sets.

The helper deliberately owns grouping and extraction so shell filename
heuristics can never mix splits from different Play downloads.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import uuid
import zipfile
from contextlib import contextmanager
from dataclasses import dataclass, asdict
from pathlib import Path

try:
    import fcntl
except ImportError:  # pragma: no cover - the port and installer run on Linux
    fcntl = None

PACKAGE = "com.mojang.minecraftpe"
MOJANG_CERTS = {
    "31be40096f931cd7f11d5e262d2b2c437c44385fb4ecbc1013d95a7435816f9c"
}
RES_VERSION_CODE = 0x0101021B
RES_VERSION_NAME = 0x0101021C
ABIS = ("arm64-v8a", "armeabi-v7a")
ABI_LABEL = {"arm64-v8a": "arm64", "armeabi-v7a": "armhf"}
BUNDLE_SUFFIXES = {".apks", ".apkm", ".xapk", ".zip"}
INPUT_SUFFIXES = {".apk", *BUNDLE_SUFFIXES}
MAX_BUNDLE_APKS = 128
MAX_BUNDLE_MEMBER_BYTES = 2 * 1024 * 1024 * 1024
MAX_BUNDLE_TOTAL_BYTES = 6 * 1024 * 1024 * 1024
LOCK_NAME = ".install.lock"
JOURNAL_NAME = ".install-transaction.json"


# Extraction takes minutes and the launcher has no window during it, so the
# progress is published to a file the shell polls to draw a bar. Purely
# advisory: if the file cannot be written, the install proceeds regardless.
_PROGRESS_PATH = os.environ.get("MCPE_PROGRESS_FILE")
_progress = {"done": 0, "total": 0, "message": "preparing"}


def begin_progress(total_bytes: int, message: str = "preparing") -> None:
    _progress.update(done=0, total=total_bytes, message=message)
    report_progress()


def report_progress(message: str | None = None, advance: int = 0) -> None:
    if message is not None:
        _progress["message"] = message
    _progress["done"] += advance
    if not _PROGRESS_PATH:
        return
    total = _progress["total"] or 1
    # Held below 100 until the install actually commits.
    percent = min(99, int(100 * _progress["done"] / total))
    # Written atomically: the reader polls this file continuously, and a
    # truncate-then-write would let it see an empty line and reset the bar.
    try:
        path = Path(_PROGRESS_PATH)
        temporary = path.with_suffix(".tmp")
        temporary.write_text(f"{percent} {_progress['message']}\n", encoding="utf-8")
        os.replace(temporary, path)
    except OSError:
        pass


class InstallError(RuntimeError):
    pass


def input_files(directory: Path) -> list[Path]:
    """Return supported installer inputs without depending on shell glob rules."""
    try:
        return sorted(
            (path for path in directory.iterdir()
             if path.is_file() and path.suffix.lower() in INPUT_SUFFIXES),
            key=lambda path: path.name.casefold(),
        )
    except FileNotFoundError:
        return []


def _safe_display_name(value: str) -> str:
    return value.replace("\t", " ").replace("\r", " ").replace("\n", " ")


def expand_input_paths(paths: list[Path], workspace: Path) -> list[tuple[Path, str, str]]:
    """Expand outer APK bundles into a private workspace.

    Each result is ``(real_path, display_name, original_input_name)``.  Inner
    archive names are never used as filesystem paths, which prevents traversal
    and collisions even when a third-party bundle contains hostile names.
    """
    workspace.mkdir(parents=True, exist_ok=True)
    expanded: list[tuple[Path, str, str]] = []
    for source_index, source in enumerate(paths):
        if not source.is_file():
            raise InstallError(f"installer input not found: {source}")
        suffix = source.suffix.lower()
        if suffix not in INPUT_SUFFIXES:
            raise InstallError(f"unsupported installer input: {source.name}")
        if suffix == ".apk":
            expanded.append((source, source.name, source.name))
            continue
        try:
            with zipfile.ZipFile(source) as archive:
                names = archive.namelist()
                # An APK renamed to .zip is still an APK, not an outer bundle.
                if "AndroidManifest.xml" in names:
                    expanded.append((source, source.name, source.name))
                    continue
                members = [entry for entry in archive.infolist()
                           if not entry.is_dir() and entry.filename.lower().endswith(".apk")]
                if not members:
                    raise InstallError(f"{source.name} contains no APK files")
                if len(members) > MAX_BUNDLE_APKS:
                    raise InstallError(
                        f"{source.name} contains too many APK files ({len(members)}; max {MAX_BUNDLE_APKS})"
                    )
                total = 0
                for entry in members:
                    mode = entry.external_attr >> 16
                    if entry.flag_bits & 0x1:
                        raise InstallError(f"encrypted APK bundle member is unsupported: {entry.filename}")
                    if stat.S_ISLNK(mode):
                        raise InstallError(f"symlink APK bundle member is unsafe: {entry.filename}")
                    if entry.file_size > MAX_BUNDLE_MEMBER_BYTES:
                        raise InstallError(f"APK bundle member is too large: {entry.filename}")
                    total += entry.file_size
                    if total > MAX_BUNDLE_TOTAL_BYTES:
                        raise InstallError(f"expanded APK bundle is too large: {source.name}")
                free = shutil.disk_usage(workspace).free
                if free < total + 64 * 1024 * 1024:
                    raise InstallError(
                        f"not enough free space to inspect {source.name}; need about "
                        f"{(total + 64 * 1024 * 1024) // (1024 * 1024)} MiB"
                    )
                for member_index, entry in enumerate(members):
                    token = hashlib.sha256(
                        f"{source_index}\0{member_index}\0{entry.filename}".encode("utf-8", "replace")
                    ).hexdigest()[:16]
                    target = workspace / f"{source_index:03d}-{member_index:03d}-{token}.apk"
                    copied = 0
                    with archive.open(entry) as src, target.open("wb") as dst:
                        while True:
                            chunk = src.read(1024 * 1024)
                            if not chunk:
                                break
                            copied += len(chunk)
                            if copied > entry.file_size or copied > MAX_BUNDLE_MEMBER_BYTES:
                                raise InstallError(f"APK bundle member expanded beyond its declared size: {entry.filename}")
                            dst.write(chunk)
                    if copied != entry.file_size:
                        raise InstallError(f"incomplete APK bundle member: {entry.filename}")
                    display = f"{source.name}:{_safe_display_name(entry.filename)}"
                    expanded.append((target, display, source.name))
        except zipfile.BadZipFile as exc:
            raise InstallError(f"corrupt or incomplete APK bundle: {source.name}") from exc
    return expanded


def _fsync_directory(path: Path) -> None:
    try:
        descriptor = os.open(path, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    except OSError:
        pass


def atomic_write_json(path: Path, value: object) -> None:
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    with temporary.open("w", encoding="utf-8") as output:
        json.dump(value, output, indent=2)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, path)
    _fsync_directory(path.parent)


@contextmanager
def install_lock(versions: Path):
    """Serialize installers with a kernel-owned lock (no stale lock files)."""
    if fcntl is None:
        raise InstallError("safe installation locking requires Linux fcntl support")
    lock_path = versions / LOCK_NAME
    with lock_path.open("a+", encoding="utf-8") as lock:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise InstallError("another Minecraft APK installation is already running") from exc
        lock.seek(0)
        lock.truncate()
        lock.write(f"pid={os.getpid()}\n")
        lock.flush()
        try:
            yield
        finally:
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)


def _transaction_names(journal: dict[str, object]) -> tuple[str, str, list[str]]:
    transaction_id = journal.get("transaction_id")
    stage_name = journal.get("stage_name")
    target_names = journal.get("target_names")
    if (journal.get("schema") != 1 or not isinstance(transaction_id, str)
            or not re.fullmatch(r"[0-9a-f]{32}", transaction_id)
            or not isinstance(stage_name, str) or not stage_name.startswith(".staging-")
            or Path(stage_name).name != stage_name or not isinstance(target_names, list)
            ):
        raise InstallError("installer transaction journal is invalid; refusing unsafe recovery")
    clean_targets: list[str] = []
    for name in target_names:
        if (not isinstance(name, str) or not name or Path(name).name != name
                or name.startswith(".")):
            raise InstallError("installer transaction journal contains an unsafe target")
        clean_targets.append(name)
    return transaction_id, stage_name, clean_targets


def rollback_transaction(versions: Path, journal: dict[str, object]) -> None:
    """Remove only paths cryptographically tagged as belonging to a transaction."""
    transaction_id, stage_name, target_names = _transaction_names(journal)
    for name in target_names:
        target = versions / name
        if not target.exists():
            continue
        try:
            metadata = json.loads((target / "version.json").read_text(encoding="utf-8"))
        except (OSError, ValueError, TypeError) as exc:
            raise InstallError(
                f"cannot safely recover interrupted install: {name} has no valid transaction metadata"
            ) from exc
        if metadata.get("transaction_id") != transaction_id:
            raise InstallError(
                f"cannot safely recover interrupted install: {name} belongs to another transaction"
            )
        shutil.rmtree(target)
    shutil.rmtree(versions / stage_name, ignore_errors=True)


def recover_incomplete_install(versions: Path) -> bool:
    journal_path = versions / JOURNAL_NAME
    if not journal_path.exists():
        return False
    try:
        journal = json.loads(journal_path.read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError) as exc:
        raise InstallError("installer transaction journal is unreadable; refusing unsafe recovery") from exc
    if not isinstance(journal, dict):
        raise InstallError("installer transaction journal is invalid; refusing unsafe recovery")
    rollback_transaction(versions, journal)
    journal_path.unlink()
    _fsync_directory(versions)
    return True


def _read_len8(data: bytes, pos: int) -> tuple[int, int]:
    value = data[pos]
    if value & 0x80:
        return ((value & 0x7F) << 8) | data[pos + 1], pos + 2
    return value, pos + 1


def _read_string_pool(data: bytes, base: int) -> list[str]:
    _, _, _ = struct.unpack_from("<HHI", data, base)
    count, _, flags, strings_start, _ = struct.unpack_from("<IIIII", data, base + 8)
    utf8 = bool(flags & (1 << 8))
    offsets_base = base + 28
    result: list[str] = []
    for index in range(count):
        offset = struct.unpack_from("<I", data, offsets_base + index * 4)[0]
        pos = base + strings_start + offset
        if utf8:
            _, pos = _read_len8(data, pos)
            byte_count, pos = _read_len8(data, pos)
            result.append(data[pos : pos + byte_count].decode("utf-8", "replace"))
        else:
            char_count = struct.unpack_from("<H", data, pos)[0]
            pos += 2
            if char_count & 0x8000:
                char_count = ((char_count & 0x7FFF) << 16) | struct.unpack_from("<H", data, pos)[0]
                pos += 2
            result.append(data[pos : pos + char_count * 2].decode("utf-16-le", "replace"))
    return result


def parse_manifest(data: bytes) -> dict[str, object | None]:
    result: dict[str, object | None] = {
        "package": None, "version_code": None, "version_name": None, "split": None
    }
    if len(data) < 8 or struct.unpack_from("<H", data, 0)[0] != 0x0003:
        return result
    strings: list[str] = []
    resource_map: list[int] = []
    offset = 8
    while offset + 8 <= len(data):
        chunk_type, _, chunk_size = struct.unpack_from("<HHI", data, offset)
        if chunk_size < 8 or offset + chunk_size > len(data):
            break
        if chunk_type == 0x0001:
            strings = _read_string_pool(data, offset)
        elif chunk_type == 0x0180:
            count = (chunk_size - 8) // 4
            resource_map = list(struct.unpack_from(f"<{count}I", data, offset + 8))
        elif chunk_type == 0x0102 and strings:
            _, name, attr_start, _, attr_count = struct.unpack_from("<IIHHH", data, offset + 16)
            tag = strings[name] if name != 0xFFFFFFFF and name < len(strings) else ""
            if tag == "manifest":
                attrs = offset + 16 + attr_start
                for index in range(attr_count):
                    apos = attrs + index * 20
                    name_index = struct.unpack_from("<I", data, apos + 4)[0]
                    raw_index = struct.unpack_from("<I", data, apos + 8)[0]
                    data_type = data[apos + 15]
                    value = struct.unpack_from("<I", data, apos + 16)[0]
                    attr_name = strings[name_index] if name_index < len(strings) else ""
                    resource = resource_map[name_index] if name_index < len(resource_map) else 0
                    text_value = None
                    if raw_index != 0xFFFFFFFF and raw_index < len(strings):
                        text_value = strings[raw_index]
                    elif data_type == 0x03 and value < len(strings):
                        text_value = strings[value]
                    if resource == RES_VERSION_CODE:
                        result["version_code"] = value
                    elif resource == RES_VERSION_NAME:
                        result["version_name"] = text_value or str(value)
                    elif attr_name == "split":
                        result["split"] = text_value
                    elif attr_name == "package":
                        result["package"] = text_value
                return result
        offset += chunk_size
    return result


def _der_tlv(data: bytes, offset: int) -> tuple[int, int, int, int]:
    if offset >= len(data):
        raise ValueError("truncated DER")
    tag = data[offset]
    offset += 1
    if offset >= len(data):
        raise ValueError("truncated DER length")
    first = data[offset]
    offset += 1
    if first & 0x80:
        count = first & 0x7F
        if count == 0 or count > 4 or offset + count > len(data):
            raise ValueError("invalid DER length")
        length = int.from_bytes(data[offset : offset + count], "big")
        offset += count
    else:
        length = first
    end = offset + length
    if end > len(data):
        raise ValueError("DER object extends past input")
    return tag, offset, end, end


def _pkcs7_first_certificate(container: bytes) -> bytes | None:
    """Return the first full DER Certificate from a PKCS#7 SignedData blob."""
    try:
        tag, root_start, root_end, _ = _der_tlv(container, 0)
        if tag != 0x30:
            return None
        pos = root_start
        _tag, _start, _end, pos = _der_tlv(container, pos)  # signedData OID
        tag, explicit_start, _explicit_end, pos = _der_tlv(container, pos)
        if tag != 0xA0 or pos > root_end:
            return None
        tag, signed_start, signed_end, _ = _der_tlv(container, explicit_start)
        if tag != 0x30:
            return None
        pos = signed_start
        for _ in range(3):  # version, digestAlgorithms, encapContentInfo
            _tag, _start, _end, pos = _der_tlv(container, pos)
        while pos < signed_end:
            object_start = pos
            tag, content_start, content_end, pos = _der_tlv(container, pos)
            if tag != 0xA0:  # certificates [0] IMPLICIT CertificateSet
                continue
            cert_pos = content_start
            while cert_pos < content_end:
                cert_start = cert_pos
                cert_tag, _cert_content, _cert_end, cert_pos = _der_tlv(container, cert_pos)
                if cert_tag == 0x30:
                    return container[cert_start:cert_pos]
            return None
    except (ValueError, IndexError):
        return None
    return None


APK_SIG_MAGIC = b"APK Sig Block 42"
APK_SIG_SCHEMES = (0x1B93AD61, 0xF05368C0, 0x7109871A)  # v3.1, v3, v2


def _lp32(data: bytes, offset: int) -> tuple[bytes, int]:
    if offset < 0 or offset + 4 > len(data):
        raise ValueError("truncated APK signing record")
    length = struct.unpack_from("<I", data, offset)[0]
    start, end = offset + 4, offset + 4 + length
    if end > len(data):
        raise ValueError("APK signing record extends past its container")
    return data[start:end], end


def _verify_apk_signer(certificate: bytes, public_key: bytes, signed_data: bytes,
                       signatures: bytes) -> bool:
    openssl = shutil.which("openssl")
    if not openssl:
        return False
    records: list[tuple[int, bytes]] = []
    try:
        offset = 0
        while offset < len(signatures):
            record, offset = _lp32(signatures, offset)
            if len(record) < 4:
                raise ValueError("short APK signature record")
            algorithm = struct.unpack_from("<I", record, 0)[0]
            signature, end = _lp32(record, 4)
            if end != len(record):
                raise ValueError("trailing APK signature data")
            records.append((algorithm, signature))
    except (ValueError, struct.error):
        return False

    algorithms: dict[int, tuple[str, list[str]]] = {
        0x0101: ("sha256", ["-sigopt", "rsa_padding_mode:pss", "-sigopt", "rsa_pss_saltlen:32"]),
        0x0102: ("sha512", ["-sigopt", "rsa_padding_mode:pss", "-sigopt", "rsa_pss_saltlen:64"]),
        0x0103: ("sha256", []), 0x0104: ("sha512", []),
        0x0201: ("sha256", []), 0x0202: ("sha512", []),
        0x0301: ("sha256", []),
    }
    with tempfile.TemporaryDirectory(prefix="mcpe-apk-signing-block-") as temp_dir:
        temp = Path(temp_dir)
        (temp / "certificate.der").write_bytes(certificate)
        (temp / "public.der").write_bytes(public_key)
        (temp / "signed.bin").write_bytes(signed_data)
        public_pem = subprocess.run(
            [openssl, "pkey", "-pubin", "-inform", "DER", "-in", str(temp / "public.der")],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False,
        )
        cert_public_pem = subprocess.run(
            [openssl, "x509", "-inform", "DER", "-in", str(temp / "certificate.der"), "-pubkey", "-noout"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False,
        )
        if public_pem.returncode or cert_public_pem.returncode:
            return False
        supplied_der = subprocess.run(
            [openssl, "pkey", "-pubin", "-outform", "DER"], input=public_pem.stdout,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False,
        )
        certificate_der = subprocess.run(
            [openssl, "pkey", "-pubin", "-outform", "DER"], input=cert_public_pem.stdout,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False,
        )
        if (supplied_der.returncode or certificate_der.returncode or
                supplied_der.stdout != certificate_der.stdout):
            return False
        (temp / "public.pem").write_bytes(public_pem.stdout)
        for algorithm, signature in records:
            params = algorithms.get(algorithm)
            if not params:
                continue
            digest, options = params
            (temp / "signature.bin").write_bytes(signature)
            verify = subprocess.run(
                [openssl, "dgst", f"-{digest}", "-verify", str(temp / "public.pem"),
                 "-signature", str(temp / "signature.bin"), *options,
                 str(temp / "signed.bin")],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
            )
            if verify.returncode == 0:
                return True
    return False


def _apk_signing_certificate(path: Path) -> tuple[bytes | None, bool]:
    """Extract and verify the first v2/v3 signer without Android SDK tools."""
    try:
        with path.open("rb") as handle:
            handle.seek(0, os.SEEK_END)
            file_size = handle.tell()
            tail_size = min(file_size, 22 + 0xFFFF)
            handle.seek(file_size - tail_size)
            tail = handle.read(tail_size)
            eocd = tail.rfind(b"PK\x05\x06")
            if eocd < 0 or eocd + 22 > len(tail):
                return None, False
            comment_length = struct.unpack_from("<H", tail, eocd + 20)[0]
            if eocd + 22 + comment_length != len(tail):
                return None, False
            central_directory = struct.unpack_from("<I", tail, eocd + 16)[0]
            if central_directory < 32:
                return None, False
            handle.seek(central_directory - 24)
            footer = handle.read(24)
            block_size = struct.unpack_from("<Q", footer, 0)[0]
            if footer[8:] != APK_SIG_MAGIC or block_size < 24 or block_size > 64 * 1024 * 1024:
                return None, False
            block_start = central_directory - block_size - 8
            if block_start < 0:
                return None, False
            handle.seek(block_start)
            block = handle.read(block_size + 8)
            if len(block) != block_size + 8 or struct.unpack_from("<Q", block, 0)[0] != block_size:
                return None, False

        schemes: dict[int, bytes] = {}
        offset, pairs_end = 8, len(block) - 24
        while offset < pairs_end:
            if offset + 8 > pairs_end:
                raise ValueError("truncated APK signing pair")
            pair_length = struct.unpack_from("<Q", block, offset)[0]
            offset += 8
            pair_end = offset + pair_length
            if pair_length < 4 or pair_end > pairs_end:
                raise ValueError("invalid APK signing pair length")
            scheme = struct.unpack_from("<I", block, offset)[0]
            if scheme in APK_SIG_SCHEMES:
                schemes[scheme] = block[offset + 4:pair_end]
            offset = pair_end
        for scheme in APK_SIG_SCHEMES:
            value = schemes.get(scheme)
            if not value:
                continue
            signers, _ = _lp32(value, 0)
            signer, _ = _lp32(signers, 0)
            signed_data, signer_offset = _lp32(signer, 0)
            if scheme in (0x1B93AD61, 0xF05368C0):
                signer_offset += 8  # min/max SDK outside signed-data in v3
            signatures, signer_offset = _lp32(signer, signer_offset)
            public_key, _ = _lp32(signer, signer_offset)
            _digests, signed_offset = _lp32(signed_data, 0)
            certificates, _ = _lp32(signed_data, signed_offset)
            certificate, _ = _lp32(certificates, 0)
            return certificate, _verify_apk_signer(
                certificate, public_key, signed_data, signatures
            )
    except (OSError, ValueError, struct.error):
        return None, False
    return None, False


def certificate_digest(path: Path, archive: zipfile.ZipFile) -> tuple[str, bool]:
    apksigner = shutil.which("apksigner")
    if apksigner:
        result = subprocess.run(
            [apksigner, "verify", "--print-certs", str(path)],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False,
        )
        match = re.search(r"certificate SHA-256 digest:\s*([0-9a-f:]+)", result.stdout, re.I)
        if match:
            return match.group(1).replace(":", "").lower(), True

    names = [n for n in archive.namelist() if re.match(r"META-INF/.*\.(RSA|DSA|EC)$", n, re.I)]
    if names:
        signature_name = sorted(names)[0]
        container = archive.read(signature_name)
        certificate = _pkcs7_first_certificate(container)
        verified = False
        openssl = shutil.which("openssl")
        if openssl:
            cert_result = subprocess.run(
                [openssl, "pkcs7", "-inform", "DER", "-print_certs", "-outform", "PEM"],
                input=container, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False,
            )
            if cert_result.returncode == 0:
                der_result = subprocess.run(
                    [openssl, "x509", "-outform", "DER"], input=cert_result.stdout,
                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False,
                )
                if der_result.returncode == 0 and der_result.stdout:
                    certificate = der_result.stdout

            sf_names = [n for n in archive.namelist() if re.match(r"META-INF/.*\.SF$", n, re.I)]
            if sf_names:
                with tempfile.TemporaryDirectory(prefix="mcpe-apk-signature-") as temp_dir:
                    signature_path = Path(temp_dir) / "signature.der"
                    content_path = Path(temp_dir) / "signature.sf"
                    signature_path.write_bytes(container)
                    content_path.write_bytes(archive.read(sorted(sf_names)[0]))
                    verify = subprocess.run(
                        [openssl, "cms", "-verify", "-binary", "-inform", "DER",
                         "-in", str(signature_path), "-content", str(content_path),
                         "-noverify", "-out", os.devnull],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
                    )
                    verified = verify.returncode == 0
        if certificate:
            return hashlib.sha256(certificate).hexdigest(), verified
        # A container hash is only useful to detect a mismatch in synthetic
        # tests. Production validation below never treats it as an identity.
        return "container:" + hashlib.sha256(container).hexdigest(), False
    certificate, verified = _apk_signing_certificate(path)
    if certificate:
        return hashlib.sha256(certificate).hexdigest(), verified
    return "unavailable", False


@dataclass
class ApkInfo:
    path: str
    name: str
    input_name: str
    package: str | None
    version_code: int | None
    version_name: str | None
    split: str | None
    abis: list[str]
    has_assets: bool
    has_resource_packs: bool
    has_pairip: bool
    signer: str
    signer_verified: bool
    role: str


def inspect_apk(path: Path, display_name: str | None = None,
                input_name: str | None = None) -> ApkInfo:
    if not path.is_file():
        raise InstallError(f"APK not found: {path}")
    try:
        with zipfile.ZipFile(path) as archive:
            bad = archive.testzip()
            if bad:
                raise InstallError(f"corrupt APK {path.name}: first bad entry is {bad}")
            try:
                manifest = parse_manifest(archive.read("AndroidManifest.xml"))
            except KeyError as exc:
                raise InstallError(f"{path.name} has no AndroidManifest.xml") from exc
            names = archive.namelist()
            abis = [abi for abi in ABIS if f"lib/{abi}/libminecraftpe.so" in names]
            has_assets = any(n.startswith("assets/") and not n.endswith("/") for n in names)
            has_resource_packs = any(
                n.startswith("assets/resource_packs/") or n.startswith("assets/assets/resource_packs/")
                for n in names
            )
            has_pairip = any(n.endswith("/libpairipcore.so") for n in names)
            signer, verified = certificate_digest(path, archive)
    except zipfile.BadZipFile as exc:
        raise InstallError(f"corrupt or incomplete APK: {path.name}") from exc

    if abis and has_assets:
        role = "full"
    elif abis:
        role = "native"
    elif not manifest.get("split"):
        # The absence of a split name is what makes an APK the base, and that
        # takes precedence over what it happens to carry. Up to 1.16 the base
        # also holds the resource packs; from 1.21 they are split out into an
        # install_pack, which does declare a split name and so still lands
        # below as "assets".
        role = "base"
    elif has_resource_packs:
        role = "assets"
    else:
        role = "optional"
    return ApkInfo(
        path=str(path.resolve()), name=display_name or path.name,
        input_name=input_name or path.name,
        package=manifest.get("package"), version_code=manifest.get("version_code"),
        version_name=manifest.get("version_name"), split=manifest.get("split"),
        abis=abis, has_assets=has_assets, has_resource_packs=has_resource_packs,
        has_pairip=has_pairip, signer=signer, signer_verified=verified, role=role,
    )


def normalized_group(infos: list[ApkInfo]) -> tuple[str, int, str]:
    packages = {i.package for i in infos if i.package}
    codes = {i.version_code for i in infos if i.version_code is not None}
    names = {i.version_name for i in infos if i.version_name}
    if len(packages) != 1 or len(codes) != 1 or len(names) > 1:
        summary = ", ".join(f"{i.name}={i.package}/{i.version_name}/{i.version_code}" for i in infos)
        raise InstallError(f"selected APKs are not one package/version set: {summary}")
    if not names:
        raise InstallError("split set has no versionName; include its base APK")
    package, code, version = next(iter(packages)), next(iter(codes)), next(iter(names))
    if package != PACKAGE:
        raise InstallError(f"unsupported Android package {package!r}; expected {PACKAGE}")
    return package, int(code), str(version)


def validate_signers(infos: list[ApkInfo]) -> tuple[str, str]:
    allow_fixture = os.getenv("MCPE_ALLOW_UNVERIFIED_APK") == "1"
    if not allow_fixture and any(
        info.signer == "unavailable" or info.signer.startswith("container:") for info in infos
    ):
        raise InstallError("every APK split must expose the same signing certificate")
    available = {i.signer for i in infos if i.signer != "unavailable"}
    if len(available) > 1:
        raise InstallError("selected APK splits do not have the same signing identity")
    digest = next(iter(available)) if available else "unavailable"
    if digest in MOJANG_CERTS:
        fully_verified = all(i.signer == digest and i.signer_verified for i in infos)
        return digest, "verified_mojang" if fully_verified else "mojang_certificate_only"
    if allow_fixture:
        return digest, "unverified_test_fixture"
    if digest.startswith("container:") or digest == "unavailable":
        raise InstallError("could not extract a signing certificate; install openssl or apksigner")
    raise InstallError(f"APK certificate is not in the Mojang allowlist: {digest}")


def safe_version(value: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9._+-]", "_", value).strip(".")
    if not cleaned:
        raise InstallError("manifest has no usable versionName")
    return cleaned


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def compatibility(
    gamedir: Path, version: str, abi: str, game_library_sha256: str | None = None
) -> dict[str, object]:
    registry = gamedir / "compat" / "compatibility.json"
    result: dict[str, object] = {"status": "best_effort", "profile": "default"}
    try:
        doc = json.loads(registry.read_text(encoding="utf-8"))
        label = ABI_LABEL[abi]
        candidates = [
            row for row in doc["versions"]
            if row["version"] == version and row["abi"] == label
        ]
        fingerprint = (game_library_sha256 or "").lower()
        exact = next((
            row for row in candidates
            if fingerprint and str(row.get("game_library_sha256", "")).lower() == fingerprint
        ), None)
        fallback = next((row for row in candidates if not row.get("game_library_sha256")), None)
        selected = exact or fallback
        if selected:
            result.update(selected)
    except (OSError, ValueError, KeyError):
        pass
    try:
        parts = tuple(int(p) for p in re.findall(r"\d+", version)[:2])
        if parts >= (1, 26):
            result.update(status="unsupported", reason="PairIP/new Android ABI")
        elif parts < (1, 16) or parts > (1, 21):
            result.update(status="unsupported", reason="outside the evidence-based 1.16-1.21 range")
    except ValueError:
        result.update(status="unsupported", reason="unparseable Bedrock version")
    return result


def choose_sources(infos: list[ApkInfo]) -> tuple[dict[str, ApkInfo], ApkInfo, ApkInfo | None]:
    full = [i for i in infos if i.role == "full"]
    if full:
        if len(full) != 1:
            raise InstallError("select exactly one full APK at a time")
        return {abi: full[0] for abi in full[0].abis}, full[0], None
    base = [i for i in infos if i.role == "base"]
    assets = [i for i in infos if i.role == "assets"]
    natives = [i for i in infos if i.role == "native"]
    if len(base) != 1:
        raise InstallError("split set must contain exactly one base APK")
    if not assets and base[0].has_resource_packs:
        # 1.16-era sets have no install_pack: the assets live in the base APK.
        assets = [base[0]]
    if len(assets) != 1:
        raise InstallError("split set must contain exactly one install-pack/assets APK")
    by_abi: dict[str, ApkInfo] = {}
    for info in natives:
        for abi in info.abis:
            if abi in by_abi:
                raise InstallError(f"split set contains multiple native APKs for {abi}")
            by_abi[abi] = info
    if not by_abi:
        raise InstallError("split set is missing an ARM native-library APK")
    return by_abi, assets[0], base[0]


def selected_size(native: ApkInfo, assets: ApkInfo, abi: str) -> int:
    total = 0
    seen: set[str] = set()
    for info, prefix in ((native, f"lib/{abi}/"), (assets, "assets/")):
        if info.path in seen:
            continue
        seen.add(info.path)
        with zipfile.ZipFile(info.path) as archive:
            total += sum(entry.file_size for entry in archive.infolist() if entry.filename.startswith(prefix))
    return total


def prefix_bytes(archive_path: str, prefix: str) -> int:
    """Uncompressed size of everything under `prefix`, for progress totals."""
    with zipfile.ZipFile(archive_path) as archive:
        return sum(
            entry.file_size
            for entry in archive.infolist()
            if entry.filename.startswith(prefix) and not entry.filename.endswith("/")
        )


def extract_prefix(archive_path: str, prefix: str, destination: Path) -> None:
    with zipfile.ZipFile(archive_path) as archive:
        for entry in archive.infolist():
            name = entry.filename
            if not name.startswith(prefix) or name.endswith("/"):
                continue
            rel = Path(name)
            if rel.is_absolute() or ".." in rel.parts:
                raise InstallError(f"unsafe APK path: {name}")
            target = destination / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(entry) as src, target.open("wb") as dst:
                shutil.copyfileobj(src, dst)
            report_progress(advance=entry.file_size)


def install(gamedir: Path, paths: list[Path]) -> list[Path]:
    versions = gamedir / "versions"
    versions.mkdir(parents=True, exist_ok=True)
    with install_lock(versions):
        if recover_incomplete_install(versions):
            print("RECOVERED=interrupted-install")
        transaction_id = uuid.uuid4().hex
        stage_root = versions / f".staging-{os.getpid()}-{transaction_id[:8]}"
        bundle_workspace = stage_root / "bundle-apks"
        journal_path = versions / JOURNAL_NAME
        journal: dict[str, object] = {
            "schema": 1,
            "transaction_id": transaction_id,
            "stage_name": stage_root.name,
            "target_names": [],
            "committed": [],
        }
        journal_written = False
        try:
            stage_root.mkdir()
            atomic_write_json(journal_path, journal)
            journal_written = True
            # Reading and sizing the archives takes a noticeable while on a
            # handheld, so say so before it starts rather than showing idle UI.
            report_progress("reading APK files")
            expanded = expand_input_paths(paths, bundle_workspace)
            infos = [inspect_apk(path, display, original)
                     for path, display, original in expanded]
            package, version_code, version = normalized_group(infos)
            signer, signer_status = validate_signers(infos)
            if any(info.has_pairip for info in infos):
                raise InstallError(
                    "PairIP licensing detected. Bedrock 1.26+ requires legal upstream launcher support; no DRM bypass is attempted."
                )
            native_by_abi, assets_source, base_source = choose_sources(infos)
            targets: dict[str, Path] = {}
            for abi in native_by_abi:
                target = versions / f"{safe_version(version)}-{version_code}-{ABI_LABEL[abi]}"
                if target.exists():
                    raise InstallError(f"version already installed: {target.name}")
                targets[abi] = target
            journal["target_names"] = [target.name for target in targets.values()]
            atomic_write_json(journal_path, journal)

            required = sum(
                selected_size(native_by_abi[abi], assets_source, abi)
                for abi in native_by_abi
            )
            free = shutil.disk_usage(versions).free
            if free < required + 64 * 1024 * 1024:
                raise InstallError(
                    f"not enough free space: need about "
                    f"{(required + 64 * 1024 * 1024) // (1024 * 1024)} MiB"
                )

            begin_progress(
                sum(
                    prefix_bytes(native_by_abi[abi].path, f"lib/{abi}/")
                    + prefix_bytes(assets_source.path, "assets/")
                    for abi in native_by_abi
                ),
                "starting",
            )

            for abi, native in native_by_abi.items():
                target_name = targets[abi].name
                stage = stage_root / target_name
                stage.mkdir()
                report_progress(f"game code ({ABI_LABEL[abi]})")
                extract_prefix(native.path, f"lib/{abi}/", stage)
                report_progress(f"game assets ({ABI_LABEL[abi]})")
                extract_prefix(assets_source.path, "assets/", stage)
                game_lib = stage / "lib" / abi / "libminecraftpe.so"
                if not game_lib.is_file():
                    raise InstallError(f"{abi} extraction did not produce libminecraftpe.so")
                if not (stage / "assets").is_dir():
                    raise InstallError("asset extraction produced no assets directory")
                fmod = stage / "lib" / abi / "libfmod.so"
                if fmod.is_file():
                    shutil.copy2(fmod, fmod.with_name("libfmod.so.12.0"))
                if abi == "armeabi-v7a":
                    for shim in ("libc.so", "libm.so"):
                        candidates = [
                            gamedir / "bin32" / "lib" / abi / shim,
                            gamedir / "lib32" / abi / shim,
                        ]
                        source = next((candidate for candidate in candidates if candidate.is_file()), None)
                        if source:
                            shutil.copy2(source, stage / "lib" / abi / shim)
                report_progress(f"checking files ({ABI_LABEL[abi]})")
                library_sha256 = file_sha256(game_lib)
                compat = compatibility(gamedir, version, abi, library_sha256)
                metadata = {
                    "schema": 2, "package": package, "version_name": version,
                    "version_code": version_code, "abi": abi, "abi_label": ABI_LABEL[abi],
                    "game_library_sha256": library_sha256,
                    "game_library_stat": {
                        "size": game_lib.stat().st_size,
                        "mtime_ns": game_lib.stat().st_mtime_ns,
                        "ctime_ns": game_lib.stat().st_ctime_ns,
                    },
                    "signer": signer, "signer_status": signer_status,
                    "sources": sorted({info.input_name for info in infos}),
                    "source_members": sorted({info.name for info in infos}),
                    "transaction_id": transaction_id,
                    "compatibility": compat,
                }
                atomic_write_json(stage / "version.json", metadata)
                if compat.get("status") == "unsupported":
                    raise InstallError(
                        f"{version}/{ABI_LABEL[abi]} is unsupported: "
                        f"{compat.get('reason', 'registry policy')}"
                    )

            # Make extracted content durable before making version directories
            # visible. This is intentionally an install-time cost, not a launch
            # cost, and can be disabled only for controlled test environments.
            if hasattr(os, "sync") and os.getenv("MCPE_INSTALL_SYNC", "1") != "0":
                os.sync()
            report_progress("finishing")
            committed: list[Path] = []
            for abi, target in targets.items():
                os.replace(stage_root / target.name, target)
                committed.append(target)
                journal["committed"] = [path.name for path in committed]
                atomic_write_json(journal_path, journal)
            _fsync_directory(versions)
            shutil.rmtree(stage_root)
            journal_path.unlink()
            _fsync_directory(versions)
            return committed
        except Exception:
            if journal_written and journal_path.exists():
                rollback_transaction(versions, journal)
                journal_path.unlink()
                _fsync_directory(versions)
            else:
                shutil.rmtree(stage_root, ignore_errors=True)
            raise


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--inspect", action="store_true")
    parser.add_argument("--install", action="store_true")
    parser.add_argument("--gamedir", type=Path)
    parser.add_argument("apks", nargs="+", type=Path)
    args = parser.parse_args()
    try:
        if args.inspect:
            with tempfile.TemporaryDirectory(prefix="mcpe-apk-inspect-") as temporary:
                expanded = expand_input_paths(args.apks, Path(temporary))
                print(json.dumps([
                    asdict(inspect_apk(path, display, original))
                    for path, display, original in expanded
                ], indent=2))
            return 0
        if args.install:
            if not args.gamedir:
                raise InstallError("--gamedir is required for installation")
            installed = install(args.gamedir.resolve(), args.apks)
            for path in installed:
                print(f"INSTALLED={path.name}")
            return 0
        parser.error("choose --inspect or --install")
    except (InstallError, OSError, zipfile.BadZipFile, struct.error) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
