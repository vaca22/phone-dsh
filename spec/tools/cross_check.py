#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Cross-tree consistency gate for the four contract trees under spec/.

Each contract tree owns a checker for its own files.  This gate checks the
seams between the trees: path references that cross a tree boundary, the
platform whitelist against the rest of the specification, the bridge method
registry against its golden vectors, the host/trajectory/UI event vocabulary against the
single mapping table in ``spec/host/v1/event-kinds.md``, the signature-surface naming of the UI
tree, the device-capability vocabulary, golden-fixture coverage, and schema file-name
uniqueness.

The tool is read-only and uses only the Python standard library.  It prints
one line per invariant and exits 0 only when all eight invariants hold.
"""

import argparse
import fnmatch
import json
import re
import sys
from pathlib import Path, PurePosixPath

SPEC = "spec"
BRIDGE_DOC = "spec/v1/bridge.md"
BRIDGE_GOLDEN = "spec/v1/golden/bridge"
EVENT_SCHEMA = "spec/host/v1/schema/harness-event.schema.json"
EVENT_KINDS_DOC = "spec/host/v1/event-kinds.md"
TRAJECTORY_DOC = "spec/v1/trajectory.md"
TRAJECTORY_SCHEMA = "spec/v1/schema/trajectory.schema.json"
TRAJECTORY_GOLDEN = "spec/v1/golden/trajectory"
TOKENS_DOC = "spec/ui/v1/tokens.json"
UI_README = "spec/ui/v1/README.md"
WHITELIST_DOC = "spec/platform/whitelist.json"
DEVICE_SCHEMA = "spec/host/v1/schema/device-capabilities.schema.json"
DEVICE_GOLDEN_GLOB = "device-*.json"

# The host tree owns the crosswalk format; this gate reads the same parser so
# the two checkers cannot disagree about what the table says.
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "spec" / "host" / "v1" / "tools"))
from host_check import parse_event_kinds  # noqa: E402

# Extensions a `spec/...` reference may carry.  Longest first, with a
# non-extension lookahead: the path class is greedy and contains `.`, so a bare
# `json` alternative would carve `.../chat-basic/expected.jsonl` down to
# `.../chat-basic/expected.json` -- a path that never exists, which made this
# gate report a phantom missing file.  A lane worked around it by no longer
# writing `.jsonl` paths in prose; the reference is legal, so the regex is what
# had to change.
REF_EXTENSIONS = ("jsonl", "json", "md", "py")
REF_RE = re.compile(
    r"spec/[A-Za-z0-9_./-]+\.(?:{})(?![A-Za-z0-9_-])".format("|".join(REF_EXTENSIONS))
)
PLACEHOLDER_REFS = frozenset({"spec/v1/file.md"})
BASELINE_ENTRYPOINTS = ("spec/README.md", "AGENTS.md")
BASELINE_LINK_RE = re.compile(r"\[[^\]\n]+\]\(([^)\n]+)\)")
PLATFORM_MENTION_RE = re.compile(r"platform\.[A-Za-z0-9_.-]+")

SIGNATURE_SURFACES = (
    "bubble",
    "toolRow",
    "thinkingPill",
    "approvalCard",
    "composer",
    "failLoudBanner",
)

# The three documents spell the same six surfaces in three styles.  The alias
# table makes the comparison case-sensitive while refusing unknown spellings.
SURFACE_ALIASES = {
    "bubble": "bubble",
    "气泡": "bubble",
    "toolRow": "toolRow",
    "tool-row": "toolRow",
    "工具行": "toolRow",
    "thinkingPill": "thinkingPill",
    "thinking-pill": "thinkingPill",
    "thinking_pill": "thinkingPill",
    "approvalCard": "approvalCard",
    "approval-card": "approvalCard",
    "审批卡": "approvalCard",
    "composer": "composer",
    "failLoudBanner": "failLoudBanner",
    "fail-loud-banner": "failLoudBanner",
    "fail-loud 横幅": "failLoudBanner",
    "fail-loud": "failLoudBanner",
}

# Golden fixture families and the checker that reads each family.  A new
# golden directory that is not listed here is reported as an orphan.
GOLDEN_READERS = (
    ("spec/bot/v1/golden", "*.json", "spec/bot/v1/tools/validate_vectors.py", False),
    ("spec/bot/v2/golden", "*.json", "spec/bot/v2/tools/validate_vectors.py", False),
    ("spec/host/v1/golden", "*.json", "spec/host/v1/tools/host_check.py", False),
    ("spec/platform/golden", "*.json", "spec/platform/tools/platform_check.py", False),
    ("spec/ui/v1/golden", "tokens.golden.json", "spec/ui/v1/tools/ui_check.py", False),
    ("spec/ui/v1/golden", "surface-projection.golden.json", "spec/ui/v1/tools/ui_check.py", False),
    ("spec/v1/golden/native-mcp", "*.json", "spec/v1/tools/native_mcp_check.py", False),
    ("spec/ui/v1/golden/page-completeness", "fixture.json", "spec/ui/v1/tools/test_extract_ios_pages.py", False),
    ("spec/ui/v1/golden/page-completeness", "cases.schema.json", "spec/ui/v1/tools/test_extract_ios_pages.py", False),
    ("spec/v1/golden/native-mcp", "ble-devices.json", "Tests/PhoneDSHBLETests/BLEDeviceMCPTests.swift", False),
    ("spec/v1/golden/native-mcp", "connect.json", "Tests/PhoneDSHADBTests/ADBMCPTests.swift", False),
    ("spec/v1/golden/native-mcp", "tap.json", "Tests/PhoneDSHADBTests/ADBMCPTests.swift", False),
    ("spec/v1/golden/native-mcp", "file-transfer.json", "Tests/PhoneDSHADBTests/ADBFileTransferTests.swift", False),
    ("spec/v1/golden/native-mcp", "package-management.json", "Tests/PhoneDSHADBTests/ADBPackageTests.swift", False),
    ("spec/v1/golden/frames", "*.json", "spec/v1/tools/spec_golden.py", False),
    ("spec/v1/golden/wal", "*.json", "spec/v1/tools/spec_golden.py", False),
    ("spec/v1/golden/wal/lifecycle", "*.json", "spec/v1/tools/spec_golden.py", False),
    ("spec/v1/golden/wal/replay", "*.json", "spec/v1/tools/spec_golden.py", False),
    ("spec/v1/golden/bridge", "*.json", "spec/v1/tools/bridge_check.py", False),
    ("spec/v1/golden/gateway", "*.json", "spec/v1/tools/gateway_check.py", False),
    ("spec/v1/golden/gateway/official-deepseek-web", "cases.json", "harmony/tests/official-web.test.mjs", False),
    ("spec/v1/golden/gateway/independent-search", "cases.json", "plugins/tests/llm-install.test.ts", False),
    ("spec/v1/golden/tono-account", "cases.json", "Tests/PhoneDSHTests/TonoAccountSessionTests.swift", False),
    ("spec/v1/golden/tono-account", "cases.json", "Tests/PhoneDSHGatewayTests/TonoCloudResponsePolicyTests.swift", False),
    ("spec/v1/golden/tono-account", "cases.json", "android/net/src/test/kotlin/com/phonedsh/account/TonoAccountCasesTest.kt", False),
    ("spec/v1/golden/tono-account", "cases.json", "android/net/src/test/kotlin/com/phonedsh/loopback/LoopbackModelProxyTest.kt", False),
    ("spec/v1/golden/cloud-voice", "cases.json", "Tests/PhoneDSHTests/CloudVoiceTests.swift", False),
    ("spec/device/v1/golden", "tonolink-voice.json", "Tests/PhoneDSHBLETests/TonoLinkVoiceTests.swift", False),
    ("spec/device/v1/golden", "tonolink-hid-consumer-control.json", "Tests/PhoneDSHBLETests/TonoLinkVolumeCommandTests.swift", False),
    ("spec/v1/golden/mcp-long-call", "cases.json", "Tests/PhoneDSHBotTests/MCP/BotMCPLongCallTests.swift", False),
    ("spec/v1/golden/perturbations", "*.json", "spec/v1/tools/fixture_check.py", False),
    ("spec/v1/golden/upstream", "*.json", "spec/v1/tools/fixture_check.py", False),
    ("spec/v1/golden/trajectory", "notes.json", "spec/v1/tools/trajectory_norm.py", True),
    ("spec/device/v1/golden", "standard-gatt-discovery-mutations.json", "spec/v1/tools/test_spec_golden.py", False),
    ("spec/pclink/v1/golden", "pclink-v1-vectors.json", "spec/pclink/v1/tools/vectors.mjs", False),
    ("spec/pclink/v1/golden", "schema-samples.json", "spec/pclink/v1/tools/check_samples.py", False),
)


class GoldenReader(object):
    """One checker reading one golden directory with one file pattern."""

    def __init__(self, base, pattern, checker, recursive=False):
        self.base = base
        self.pattern = pattern
        self.checker = checker
        self.recursive = recursive


class Result(object):
    """The outcome of one invariant."""

    def __init__(self, key, title, ok=True, summary=""):
        self.key = key
        self.title = title
        self.ok = ok
        self.summary = summary
        self.details = []
        self.notes = []

    def fail(self, message):
        self.ok = False
        self.details.append(message)

    def note(self, message):
        self.notes.append(message)


def _rel(root, path):
    try:
        return path.relative_to(root).as_posix()
    except ValueError:
        return str(path)


def _loc(root, path, lineno=None):
    where = _rel(root, path)
    if lineno is not None:
        where = "{}:{}".format(where, lineno)
    return where


def _load_json(res, root, path, label=None):
    label = label or _rel(root, path)
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        res.fail("{}: cannot read ({})".format(label, exc.strerror or exc))
    except ValueError as exc:
        res.fail("{}: invalid JSON ({})".format(label, exc))
    return None


def _text_files(root, tree="spec"):
    base = root / tree
    if not base.is_dir():
        return []
    return [
        path
        for path in sorted(base.rglob("*"))
        if path.is_file() and path.suffix in (".md", ".json")
    ]


# 1. Reference reachability -------------------------------------------------


def _check_baseline_links(root, res):
    """Keep the protocol index navigable and the two agent entrypoints unified.

    This checks only the two owned entrypoints, not arbitrary Markdown syntax or
    external URLs. It proves reachability, never semantic/runtime conformance.
    """
    count = 0
    repo = root.resolve()
    for rel in BASELINE_ENTRYPOINTS:
        path = root / rel
        try:
            text = path.read_text(encoding="utf-8")
        except OSError:
            res.fail("{}: missing or unreadable baseline entrypoint".format(rel))
            continue
        for match in BASELINE_LINK_RE.finditer(text):
            destination = match.group(1).strip()
            if not destination:
                continue
            # Allow ordinary Markdown titles and <paths with spaces>.
            target = (destination[1:destination.index(">")]
                      if destination.startswith("<") and ">" in destination
                      else destination.split()[0])
            target = target.split("#", 1)[0]
            if not target or target.startswith("//") or re.match(r"^[A-Za-z][A-Za-z0-9+.-]*:", target):
                continue
            count += 1
            where = "{}:{}".format(rel, text.count("\n", 0, match.start()) + 1)
            resolved = (path.parent / target).resolve()
            if Path(target).is_absolute() or not resolved.is_relative_to(repo):
                res.fail("{}: baseline link escapes the repository: {}".format(where, target))
            elif not resolved.exists():
                res.fail("{} -> {} (missing baseline link)".format(where, target))
    alias = root / "CLAUDE.md"
    if alias.is_symlink() or not alias.is_file():
        res.fail("CLAUDE.md must be a regular file importing @AGENTS.md")
    else:
        try:
            lines = [line.strip() for line in alias.read_text(encoding="utf-8").splitlines() if line.strip()]
            if not lines or lines[0] != "@AGENTS.md":
                res.fail("CLAUDE.md first nonempty line must be @AGENTS.md")
        except (OSError, UnicodeError):
            res.fail("CLAUDE.md must be readable UTF-8")
    return count


def check_references(root):
    res = Result("reference-reachability", "spec path references exist")
    baseline_links = _check_baseline_links(root, res)
    files = _text_files(root)
    if not files:
        res.fail("no README or JSON file found under spec/")
        return res
    occurrences = 0
    placeholders = 0
    for path in files:
        try:
            text = path.read_text(encoding="utf-8")
        except OSError as exc:
            res.fail("{}: cannot read ({})".format(_rel(root, path), exc.strerror or exc))
            continue
        for match in REF_RE.finditer(text):
            ref = match.group(0).rstrip(".,;:")
            if ref in PLACEHOLDER_REFS:
                placeholders += 1
                continue
            occurrences += 1
            lineno = text.count("\n", 0, match.start()) + 1
            parts = PurePosixPath(ref).parts
            if ".." in parts or ref.startswith("/"):
                res.fail("{}: reference escapes the repository: {}".format(
                    _loc(root, path, lineno), ref))
                continue
            if not (root / ref).is_file():
                res.fail("{} -> {} (missing)".format(_loc(root, path, lineno), ref))
    res.summary = "{} references in {} files; {} placeholder(s) ignored; {} baseline links".format(
        occurrences, len(files), placeholders, baseline_links)
    return res


# 2. Platform whitelist against host/ui ------------------------------------


def check_platform_contract(root):
    res = Result("platform-contract", "whitelist references resolve and names agree")
    path = root / WHITELIST_DOC
    if not path.is_file():
        res.fail("{}: missing".format(WHITELIST_DOC))
        return res
    entries = _load_json(res, root, path)
    if not isinstance(entries, list):
        res.fail("{}: root must be an array".format(WHITELIST_DOC))
        return res

    ids = set()
    capabilities = set()
    refs = 0
    for index, entry in enumerate(entries):
        where = "{}[{}]".format(WHITELIST_DOC, index)
        if not isinstance(entry, dict):
            res.fail("{}: entry is not an object".format(where))
            continue
        ident = entry.get("id")
        if not isinstance(ident, str) or not ident:
            res.fail("{}: missing id".format(where))
        elif ident in ids:
            res.fail("{}: duplicate id {!r}".format(where, ident))
        else:
            ids.add(ident)
        capability = entry.get("capability")
        if isinstance(capability, str) and capability:
            capabilities.add(capability)
        spec_ref = entry.get("spec_ref")
        if not isinstance(spec_ref, str) or not spec_ref.strip():
            res.fail("{}: missing spec_ref".format(where))
            continue
        target = spec_ref.split()[0].strip("`")
        refs += 1
        if ".." in PurePosixPath(target).parts or target.startswith("/"):
            res.fail("{}: spec_ref escapes the repository: {!r}".format(where, target))
        elif not (root / target).is_file():
            res.fail("{}: spec_ref target is missing: {}".format(where, target))

    mentions = []
    for tree in ("spec/host", "spec/ui"):
        for doc in _text_files(root, tree):
            try:
                text = doc.read_text(encoding="utf-8")
            except OSError:
                continue
            for match in PLATFORM_MENTION_RE.finditer(text):
                token = match.group(0).rstrip(".,;:")
                if token in ("platform.", "platform.<slug>"):
                    continue
                lineno = text.count("\n", 0, match.start()) + 1
                mentions.append((_loc(root, doc, lineno), token))
    unknown = sorted({token for _where, token in mentions if token not in ids})
    for token in unknown:
        where = next(where for where, seen in mentions if seen == token)
        res.fail("{}: unknown platform id {!r} (not in whitelist.json)".format(where, token))

    if not mentions:
        res.note("no platform.<id> reference in spec/host or spec/ui; the reverse check is vacuous")
    res.summary = "{} entries, {} spec_refs, {} host/ui platform references, {}".format(
        len(entries), refs, len(mentions), "{} unknown".format(len(unknown)))
    res.note("capability names seen in the whitelist: {}".format(
        ", ".join(sorted(capabilities)) if capabilities else "none"))
    return res


# 3. Bridge registry against golden vectors --------------------------------


def _bridge_registry(text):
    lines = text.splitlines()
    start = None
    for index, line in enumerate(lines):
        if line.startswith("## 11."):
            start = index
            break
    if start is None:
        return None
    end = len(lines)
    for index in range(start + 1, len(lines)):
        if lines[index].startswith("## "):
            end = index
            break
    methods = []
    for line in lines[start:end]:
        match = re.match(r"^\|\s*`([^`]+)`\s*\|", line)
        if match:
            methods.append((match.group(1), _registry_row_is_declared_unimplemented(line)))
    return methods


def _registry_row_is_declared_unimplemented(line):
    """True when the row's Status cell says the method is not implemented.

    A registered method that no host implements has no shape to pin, so demanding
    a golden vector for it would make the vector a fabrication. But the exemption
    must be *earned by the text*: the status cell has to say so, and a method that
    claims both "not implemented" and a positive vector fails below.
    """
    cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
    return any("not implemented" in cell.lower() for cell in cells[1:])


def _bridge_envelopes(document):
    instance = document.get("instance") if isinstance(document, dict) else None
    if isinstance(instance, list):
        for item in instance:
            if isinstance(item, dict) and isinstance(item.get("instance"), dict):
                yield item["instance"]
    elif isinstance(instance, dict):
        yield instance


def check_bridge_registry(root):
    res = Result("bridge-registry", "bridge.md registry and golden methods agree")
    doc_path = root / BRIDGE_DOC
    if not doc_path.is_file():
        res.fail("{}: missing".format(BRIDGE_DOC))
        return res
    try:
        registry = _bridge_registry(doc_path.read_text(encoding="utf-8"))
    except OSError as exc:
        res.fail("{}: cannot read ({})".format(BRIDGE_DOC, exc.strerror or exc))
        return res
    if registry is None:
        res.fail("{}: section 11 (Method registry) is missing".format(BRIDGE_DOC))
        return res
    if not registry:
        res.fail("{}: section 11 lists no method".format(BRIDGE_DOC))
        return res
    declared_unimplemented = {name for name, pending in registry if pending}
    registry = [name for name, _ in registry]
    seen = set()
    for method in registry:
        if method in seen:
            res.fail("{}: duplicate registry method {!r}".format(BRIDGE_DOC, method))
        seen.add(method)
    registry = set(registry)

    golden_dir = root / BRIDGE_GOLDEN
    if not golden_dir.is_dir():
        res.fail("{}: directory is missing".format(BRIDGE_GOLDEN))
        return res
    files = sorted(golden_dir.glob("*.json"))
    if not files:
        res.fail("{}: no golden vector".format(BRIDGE_GOLDEN))
        return res

    positive = set()
    sources = {}
    negative = set()
    negative_files = []
    for path in files:
        document = _load_json(res, root, path)
        if document is None:
            continue
        envelopes = list(_bridge_envelopes(document))
        is_negative = any(
            isinstance(envelope.get("error"), dict)
            and envelope["error"].get("code") == "BRIDGE_METHOD_UNKNOWN"
            for envelope in envelopes
        )
        if is_negative:
            negative_files.append(_rel(root, path))
        for envelope in envelopes:
            method = envelope.get("method")
            if not isinstance(method, str):
                continue
            if is_negative:
                negative.add(method)
            else:
                positive.add(method)
                sources.setdefault(method, _rel(root, path))

    # A method declared `not implemented` has no shape to pin yet, so it needs no
    # vector — but claiming both is a contradiction, because a vector would be
    # evidence for a method the same table says does not exist.
    for method in sorted(declared_unimplemented & positive):
        res.fail("{}: registry method {!r} is declared not implemented "
                 "but carries a positive golden vector".format(BRIDGE_DOC, method))
    for method in sorted(registry - positive - declared_unimplemented):
        res.fail("{}: registry method {!r} has no non-negative golden vector".format(
            BRIDGE_DOC, method))
    for method in sorted(declared_unimplemented - set(registry)):
        res.fail("{}: registry method {!r} is not implemented yet".format(BRIDGE_DOC, method))
    for method in sorted(positive - registry):
        res.fail("{}: golden method {!r} is absent from the registry".format(
            sources.get(method, BRIDGE_GOLDEN), method))
    for method in sorted(negative & registry):
        res.fail("{}: negative vector carries registered method {!r}".format(
            BRIDGE_GOLDEN, method))

    if negative_files:
        res.note("negative vectors (method intentionally absent): {}".format(
            ", ".join(sorted(negative_files))))
    res.summary = ("{}/{} implemented registry methods covered; {} positive, {} negative, "
                   "{} declared not implemented").format(
        len((set(registry) - declared_unimplemented) & positive),
        len(set(registry) - declared_unimplemented),
        len(positive), len(negative), len(declared_unimplemented))
    return res


# 4. Event-kind closure -----------------------------------------------------


def _host_event_kinds(schema):
    kinds = set()
    one_of = schema.get("oneOf") if isinstance(schema, dict) else None
    variants = one_of if isinstance(one_of, list) else []
    for variant in variants:
        if not isinstance(variant, dict):
            continue
        properties = variant.get("properties")
        if not isinstance(properties, dict):
            continue
        kind = properties.get("kind")
        if not isinstance(kind, dict):
            continue
        if isinstance(kind.get("const"), str):
            kinds.add(kind["const"])
        values = kind.get("enum")
        if isinstance(values, list):
            for value in values:
                if isinstance(value, str):
                    kinds.add(value)
    return kinds


def _trajectory_declared_kinds(text):
    kinds = set()
    for match in re.finditer(r"`([^`]+)`", text):
        token = match.group(1)
        if token.startswith("spec/") or token.count("/") != 1:
            continue
        left, right = token.split("/")
        if re.match(r"^[a-z][a-z0-9-]*$", left) and re.match(r"^[a-z][a-z0-9-]*$", right):
            kinds.add(token)
    return kinds


def _schema_type_kinds(schema):
    kinds = set()
    properties = schema.get("properties") if isinstance(schema, dict) else None
    if not isinstance(properties, dict):
        return kinds
    for member in ("kind", "type"):
        declaration = properties.get(member)
        if not isinstance(declaration, dict):
            continue
        if isinstance(declaration.get("const"), str):
            kinds.add(declaration["const"])
        values = declaration.get("enum")
        if isinstance(values, list):
            for value in values:
                if isinstance(value, str):
                    kinds.add(value)
    return kinds


def _trajectory_expected_kinds(root, res):
    """Types in the trajectory oracle's *expected* rows only.

    The input fixtures also carry stage-1 noise types (``metric/sample`` and
    friends); those are dropped before output and are not event vocabulary.
    """

    kinds = set()
    base = root / TRAJECTORY_GOLDEN
    if not base.is_dir():
        res.fail("{}: directory is missing".format(TRAJECTORY_GOLDEN))
        return kinds
    files = sorted(base.rglob("*expected*.jsonl"))
    if not files:
        res.fail("{}: no *expected*.jsonl row file".format(TRAJECTORY_GOLDEN))
        return kinds
    for path in files:
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except OSError as exc:
            res.fail("{}: cannot read ({})".format(_rel(root, path), exc.strerror or exc))
            continue
        for lineno, line in enumerate(lines, 1):
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except ValueError as exc:
                res.fail("{}: invalid JSONL ({})".format(_loc(root, path, lineno), exc))
                continue
            if isinstance(row, dict) and isinstance(row.get("type"), str):
                kinds.add(row["type"])
    return kinds


# A host kind is snake_case and the UI writes it in the Event column; a
# projection or synthetic type carries a slash. A bare state word (`running`)
# is not an event name and is ignored.
EVENT_TOKEN_RE = re.compile(
    r"^(?:[a-z][a-z0-9-]*/(?:[a-z0-9*-]+/)*[a-z0-9*-]+|[a-z][a-z0-9]*_[a-z0-9_]*)$"
)


def _ui_event_kinds(root):
    path = root / UI_README
    if not path.is_file():
        return set()
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return set()
    start = None
    for index, line in enumerate(lines):
        if line.startswith("## 3."):
            start = index
            break
    if start is None:
        return set()
    end = len(lines)
    for index in range(start + 1, len(lines)):
        if lines[index].startswith("## "):
            end = index
            break
    kinds = set()
    for line in lines[start:end]:
        if not line.strip().startswith("|"):
            continue
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if not cells:
            continue
        for token in re.findall(r"`([^`]+)`", cells[0]):
            if EVENT_TOKEN_RE.match(token):
                kinds.add(token)
    return kinds


def _event_kind_covered(known, name):
    """Whether *name* is one of *known* or a family of one (``*`` suffix)."""

    for item in known:
        if item == name:
            return True
        if item.endswith("*") and name.startswith(item[:-1]):
            return True
        if name.endswith("*") and item.startswith(name[:-1]):
            return True
    return False


def check_event_kinds(root):
    res = Result("event-kind-closure",
                 "one mapping table closes the host, trajectory and UI vocabularies")
    host_path = root / EVENT_SCHEMA
    if not host_path.is_file():
        res.fail("{}: missing".format(EVENT_SCHEMA))
        return res
    host_schema = _load_json(res, root, host_path)
    host_kinds = _host_event_kinds(host_schema) if isinstance(host_schema, dict) else set()
    if not host_kinds:
        res.fail("{}: no event kind const/enum found".format(EVENT_SCHEMA))
        return res

    doc_path = root / EVENT_KINDS_DOC
    if not doc_path.is_file():
        res.fail("{}: missing; the three vocabularies need one crosswalk".format(EVENT_KINDS_DOC))
        return res
    try:
        data, problems = parse_event_kinds(doc_path.read_text(encoding="utf-8"))
    except OSError as exc:
        res.fail("{}: cannot read ({})".format(EVENT_KINDS_DOC, exc.strerror or exc))
        return res
    for problem in problems:
        res.fail("{}: {}".format(EVENT_KINDS_DOC, problem))
    table_kinds = set(data["host"])
    for kind in sorted(host_kinds - table_kinds):
        res.fail("{}: mapping table misses host kind {!r}".format(EVENT_KINDS_DOC, kind))
    for kind in sorted(table_kinds - host_kinds):
        res.fail("{}: mapping table declares unknown host kind {!r}".format(EVENT_KINDS_DOC, kind))
    projection_types = set(data["projection_types"])
    synthetic = set(data["synthetic"])
    # "mapped" is every name the crosswalk maps: the host kinds, their
    # projection types, and the explicitly not-projected names.  A declared
    # name may only escape it when section 2 defines it as synthetic.
    mapped = table_kinds | projection_types | set(data["not_projected"])
    covered = mapped | synthetic

    if not (root / TRAJECTORY_DOC).is_file():
        res.fail("{}: missing".format(TRAJECTORY_DOC))
        return res
    if not (root / TRAJECTORY_SCHEMA).is_file():
        res.fail("{}: missing".format(TRAJECTORY_SCHEMA))
        return res
    try:
        doc_text = (root / TRAJECTORY_DOC).read_text(encoding="utf-8")
    except OSError as exc:
        res.fail("{}: cannot read ({})".format(TRAJECTORY_DOC, exc.strerror or exc))
        return res
    schema = _load_json(res, root, root / TRAJECTORY_SCHEMA)
    declared = _trajectory_declared_kinds(doc_text)
    declared |= _schema_type_kinds(schema) if isinstance(schema, dict) else set()
    ui_kinds = _ui_event_kinds(root)
    expected = _trajectory_expected_kinds(root, res)

    uncovered = 0
    for kind in sorted(declared):
        if not _event_kind_covered(covered, kind):
            uncovered += 1
            res.fail("{}: declared event type {!r} is not covered by {}".format(
                TRAJECTORY_DOC, kind, EVENT_KINDS_DOC))
    for kind in sorted(ui_kinds):
        if not _event_kind_covered(covered, kind):
            uncovered += 1
            res.fail("{}: state-machine event {!r} is not covered by {}".format(
                UI_README, kind, EVENT_KINDS_DOC))
    for kind in sorted(expected):
        if not _event_kind_covered(covered, kind):
            uncovered += 1
            res.fail("{}: fixture event type {!r} is not covered by {}".format(
                TRAJECTORY_GOLDEN, kind, EVENT_KINDS_DOC))

    unused = sorted(host_kinds - expected)
    if unused:
        res.note("host kinds with no trajectory row: {}".format(", ".join(unused)))
    if ui_kinds:
        res.note("UI state-machine event names: {}".format(", ".join(sorted(ui_kinds))))
    res.summary = (
        "declared={}, fixture types={}, host kinds={}, projection types={}, synthetic={}; "
        "{} host kind(s) off the table, {} declared/fixture name(s) uncovered"
    ).format(
        len(declared), len(expected), len(host_kinds), len(projection_types), len(synthetic),
        len(host_kinds - table_kinds) + len(table_kinds - host_kinds), uncovered,
    )
    return res


# 5. Signature-surface closure ---------------------------------------------


def _readme_surfaces(root, res):
    path = root / UI_README
    if not path.is_file():
        res.fail("{}: missing".format(UI_README))
        return {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        res.fail("{}: cannot read ({})".format(UI_README, exc.strerror or exc))
        return {}
    header = None
    for index, line in enumerate(lines):
        if line.strip().startswith("| 签名面 |"):
            header = index
            break
    if header is None:
        res.fail("{}: section 4 signature-surface table is missing".format(UI_README))
        return {}
    rows = {}
    for line in lines[header + 1:]:
        if not line.startswith("|"):
            break
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if not cells or not cells[0] or set(cells[0]) <= set("-: "):
            continue
        if cells[0] == "签名面":
            continue
        label = cells[0]
        canonical = SURFACE_ALIASES.get(label)
        if canonical is None:
            res.fail("{}: unknown signature-surface label {!r}".format(UI_README, label))
            continue
        if canonical in rows:
            res.fail("{}: signature surface {!r} is documented twice".format(UI_README, canonical))
            continue
        tokens = set()
        for cell in cells[1:]:
            for token in re.findall(r"`([^`]+)`", cell):
                token = token.strip()
                if not token:
                    continue
                if "." in token:
                    tokens.add(token)
                else:
                    tokens.add("geometry." + token)
        rows[canonical] = tokens
    return rows


def _trajectory_surfaces(root, res):
    path = root / TRAJECTORY_DOC
    if not path.is_file():
        res.fail("{}: missing".format(TRAJECTORY_DOC))
        return None
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        res.fail("{}: cannot read ({})".format(TRAJECTORY_DOC, exc.strerror or exc))
        return None
    index = None
    for position, line in enumerate(lines):
        if "six signature surfaces" not in line:
            continue
        paragraph = line
        cursor = position + 1
        while cursor < len(lines) and lines[cursor].strip():
            paragraph += " " + lines[cursor]
            cursor += 1
        if "`bubble`" in paragraph:
            index = position
            break
    if index is None:
        res.note("{}: does not reference the six signature surfaces; cross-reference skipped".format(
            TRAJECTORY_DOC))
        return None
    paragraph = lines[index]
    cursor = index + 1
    while cursor < len(lines) and lines[cursor].strip():
        paragraph += " " + lines[cursor]
        cursor += 1
    tail = paragraph.split("six signature surfaces", 1)[1]
    tail = re.split(r"[—-]\s*and is judged", tail, 1)[0]
    found = set()
    for token in re.findall(r"`([^`]+)`", tail):
        canonical = SURFACE_ALIASES.get(token)
        if canonical is None:
            res.fail("{}: unknown signature-surface spelling {!r}".format(TRAJECTORY_DOC, token))
            continue
        found.add(canonical)
    return found


def check_signature_surfaces(root):
    res = Result("signature-surfaces", "six signature surfaces agree across UI documents")
    tokens_path = root / TOKENS_DOC
    if not tokens_path.is_file():
        res.fail("{}: missing".format(TOKENS_DOC))
        return res
    document = _load_json(res, root, tokens_path)
    if not isinstance(document, dict):
        res.fail("{}: root is not an object".format(TOKENS_DOC))
        return res
    surfaces = document.get("signatureSurfaces")
    if not isinstance(surfaces, dict):
        res.fail("{}: signatureSurfaces is missing".format(TOKENS_DOC))
        return res

    keys = set(surfaces)
    readme = _readme_surfaces(root, res)
    trajectory = _trajectory_surfaces(root, res)

    def compare(name, other):
        missing = sorted(keys - other)
        extra = sorted(other - keys)
        for surface in missing:
            res.fail("{}: surface {!r} is missing".format(name, surface))
        for surface in extra:
            res.fail("{}: unknown surface {!r}".format(name, surface))

    compare(UI_README, set(readme))
    if trajectory is not None:
        compare(TRAJECTORY_DOC, trajectory)

    drift = 0
    for surface in sorted(keys & set(readme)):
        declared = set(surfaces[surface].get("tokens") or []) if isinstance(
            surfaces[surface], dict) else set()
        documented = readme[surface]
        missing = sorted(declared - documented)
        extra = sorted(documented - declared)
        if missing or extra:
            drift += 1
            for token in missing:
                res.fail("{}: surface {!r} omits token {!r}".format(UI_README, surface, token))
            for token in extra:
                res.fail("{}: surface {!r} lists token {!r} not in tokens.json".format(
                    UI_README, surface, token))

    res.summary = "{} surfaces in tokens.json, {} in README, {} in trajectory.md; {} token-composition drift(s)".format(
        len(keys), len(readme), len(trajectory) if trajectory is not None else 0, drift)
    res.note("README labels are display names; the checker canonicalises them with SURFACE_ALIASES")
    return res


# 6. Capability vocabulary --------------------------------------------------


def check_capabilities(root):
    res = Result("capability-vocabulary", "device golden capabilities exist in the schema")
    schema_path = root / DEVICE_SCHEMA
    if not schema_path.is_file():
        res.fail("{}: missing".format(DEVICE_SCHEMA))
        return res
    schema = _load_json(res, root, schema_path)
    properties = None
    if isinstance(schema, dict):
        capabilities = schema.get("properties", {}).get("capabilities")
        if isinstance(capabilities, dict):
            properties = capabilities.get("properties")
    if not isinstance(properties, dict) or not properties:
        res.fail("{}: no capability properties found".format(DEVICE_SCHEMA))
        return res
    declared = set(properties)
    wildcards = tuple(name[:-1] for name in declared if name.endswith(".*") and len(name) > 2)

    golden_dir = root / "spec/host/v1/golden"
    if not golden_dir.is_dir():
        res.fail("spec/host/v1/golden: directory is missing")
        return res
    files = sorted(golden_dir.glob(DEVICE_GOLDEN_GLOB))
    if not files:
        res.fail("spec/host/v1/golden: no device-*.json golden")
        return res

    used = set()
    unknown = set()
    checked = 0
    for path in files:
        document = _load_json(res, root, path)
        if not isinstance(document, dict):
            continue
        instance = document.get("instance")
        if not isinstance(instance, dict):
            continue
        capabilities = instance.get("capabilities")
        if not isinstance(capabilities, dict):
            continue
        checked += 1
        for name in sorted(capabilities):
            used.add(name)
            if name in declared:
                continue
            if any(name.startswith(prefix) for prefix in wildcards):
                continue
            unknown.add(name)
            res.fail("{}: capability {!r} is not declared by {}".format(
                _rel(root, path), name, DEVICE_SCHEMA))

    if checked == 0:
        res.fail("spec/host/v1/golden: no device golden carries a capabilities map")
    unused = sorted(declared - used)
    families = sorted({name.split(".", 1)[0] for name in declared if "." in name})
    res.note("declared capability families: {}".format(", ".join(families)))
    if unused:
        res.note("declared but not used by device goldens (must be marked provisional; "
                 "host_check enforces it): {}".format(", ".join(unused)))
    res.summary = "{} capability maps, {} names used, {} declared, {} undeclared".format(
        checked, len(used), len(declared), len(unknown))
    return res


# 7. Golden fixture coverage ------------------------------------------------


def check_fixture_coverage(root, readers=None):
    res = Result("fixture-coverage", "every golden JSON is read and no reader glob is empty")
    readers = tuple(GOLDEN_READERS if readers is None else readers)
    readers = tuple(
        item if isinstance(item, GoldenReader) else GoldenReader(*item)
        for item in readers
    )
    spec_root = root / SPEC
    if not spec_root.is_dir():
        res.fail("spec: directory is missing")
        return res

    for reader in readers:
        checker_path = root / reader.checker
        base = root / reader.base
        if not checker_path.is_file():
            res.fail("{}: reader for {} is missing".format(reader.checker, reader.base))
            continue
        try:
            source = checker_path.read_text(encoding="utf-8")
        except OSError as exc:
            res.fail("{}: cannot read ({})".format(reader.checker, exc.strerror or exc))
            continue
        if reader.pattern not in source:
            res.fail("{}: does not contain the glob {!r}".format(reader.checker, reader.pattern))
        if not base.is_dir():
            res.fail("{}: directory is missing".format(reader.base))
            continue
        matches = sorted(base.rglob(reader.pattern) if reader.recursive else base.glob(reader.pattern))
        matches = [path for path in matches if path.is_file()]
        if not matches:
            res.fail("{}: glob {!r} is empty".format(reader.base, reader.pattern))

    golden_files = [
        path
        for path in sorted(spec_root.rglob("*.json"))
        if path.is_file() and "golden" in path.relative_to(spec_root).parts
    ]
    covered = 0
    for path in golden_files:
        found = False
        for reader in readers:
            base = root / reader.base
            try:
                relative = path.relative_to(base)
            except ValueError:
                continue
            if not reader.recursive and len(relative.parts) != 1:
                continue
            if fnmatch.fnmatch(path.name, reader.pattern):
                found = True
                break
        if found:
            covered += 1
        else:
            res.fail("{}: orphan golden (no checker glob covers it)".format(_rel(root, path)))

    res.summary = "{}/{} golden JSON files covered; {} reader glob(s)".format(
        covered, len(golden_files), len(readers))
    return res


# 8. Schema basename uniqueness --------------------------------------------


def check_schema_basenames(root):
    res = Result("schema-basenames", "schema file basenames are unique across trees")
    spec_root = root / SPEC
    if not spec_root.is_dir():
        res.fail("spec: directory is missing")
        return res
    schemas = [
        path
        for path in sorted(spec_root.rglob("*.schema.json"))
        if path.is_file() and path.parent.name == "schema"
    ]
    if not schemas:
        res.fail("spec: no *.schema.json file found")
        return res
    groups = {}
    for path in schemas:
        groups.setdefault(path.name, []).append(_rel(root, path))
    duplicates = {name: paths for name, paths in groups.items() if len(paths) > 1}
    for name in sorted(duplicates):
        res.fail("duplicate schema basename {!r}: {}".format(name, ", ".join(duplicates[name])))
    res.summary = "{} schema files, {} unique basenames, {} duplicate(s)".format(
        len(schemas), len(groups), len(duplicates))
    return res


CHECKS = (
    ("reference-reachability", check_references),
    ("platform-contract", check_platform_contract),
    ("bridge-registry", check_bridge_registry),
    ("event-kind-closure", check_event_kinds),
    ("signature-surfaces", check_signature_surfaces),
    ("capability-vocabulary", check_capabilities),
    ("fixture-coverage", check_fixture_coverage),
    ("schema-basenames", check_schema_basenames),
)


def run_checks(root):
    results = []
    for key, function in CHECKS:
        try:
            result = function(root)
        except Exception as exc:  # keep the remaining invariants running
            result = Result(key, "checker crashed", False,
                            "{}: {}".format(type(exc).__name__, exc))
        results.append(result)
    return results


def render(results):
    total = len(results)
    ok_count = 0
    for index, result in enumerate(results, 1):
        status = "ok" if result.ok else "fail"
        if result.ok:
            ok_count += 1
        print("[{}/{}] {:<24} {:<4}  {}".format(
            index, total, result.key, status, result.summary))
        for detail in result.details:
            print("      - {}".format(detail))
        for note in result.notes:
            print("      note: {}".format(note))
    print("")
    print("{} invariants: {} ok, {} fail".format(total, ok_count, total - ok_count))
    return 0 if ok_count == total else 1


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Check consistency between the spec/ contract trees.")
    parser.add_argument("--root", default=".", help="repository root (default: .)")
    args = parser.parse_args(argv)
    root = Path(args.root).resolve()
    if not (root / SPEC).is_dir():
        print("cross_check: {} does not contain a spec/ directory".format(root), file=sys.stderr)
        return 2
    results = run_checks(root)
    return render(results)


if __name__ == "__main__":
    sys.exit(main())
