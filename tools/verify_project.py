"""Static repository checks that do not launch MetaTrader."""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCES = {
    "master": ROOT / "CopyMonitor_Master_MT5_v1_14_MULTI.mq5",
    "slave": ROOT / "CopyMonitor_Slave_MT5_v1_17_MULTI.mq5",
}


def require(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def property_version(source: str) -> str | None:
    match = re.search(r'^#property\s+version\s+"([^"]+)"', source, re.MULTILINE)
    return match.group(1) if match else None


def check_source(name: str, path: Path, failures: list[str]) -> str:
    require(path.is_file(), f"missing source: {path.name}", failures)
    if not path.is_file():
        return ""

    source = path.read_text(encoding="utf-8")
    version = property_version(source)
    file_version = re.search(r"_v(\d+)_(\d+)_", path.name)
    expected = f"{file_version.group(1)}.{file_version.group(2)}" if file_version else None

    require(version == expected, f"{name}: filename/property version mismatch", failures)
    require(
        bool(version and f"v{version} MULTI" in source),
        f"{name}: visible version label is stale",
        failures,
    )
    require(source.count("{") == source.count("}"), f"{name}: unbalanced braces", failures)
    require("#property strict" in source, f"{name}: strict mode missing", failures)
    return source


def function_body(source: str, signature: str) -> str | None:
    """Return the normalised body of a function, for cross-EA comparison."""
    start = source.find(signature)
    if start < 0:
        return None
    open_brace = source.find("{", start)
    if open_brace < 0:
        return None

    depth = 0
    for index in range(open_brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                body = source[open_brace : index + 1]
                return re.sub(r"\s+", " ", body)
    return None


def check_protocol(master: str, slave: str, failures: list[str]) -> None:
    for token in ('"META|"', '"POS|"', '"ORD|"', '"END\\r\\n"'):
        require(token in master, f"master: protocol token missing: {token}", failures)

    require(
        "#define CM_SNAPSHOT_SCHEMA   3" in master,
        "master: published schema must be 3",
        failures,
    )
    require(
        '"META|"+IntegerToString(CM_SNAPSHOT_SCHEMA)' in master,
        "master: META must declare the schema constant",
        failures,
    )
    require(
        "ACCOUNT_COMPANY" in master,
        "master: schema 2 must publish the Master broker",
        failures,
    )
    # Schema 3 appends the stop-limit price at the end of every ORD record.
    require(
        'DoubleToString(stoplimit,10)+"\\r\\n"' in master,
        "master: schema 3 must publish the pending stop-limit price",
        failures,
    )

    for token in ('p[0]=="META"', 'p[0]=="POS"', 'p[0]=="ORD"', 'p[0]=="END"'):
        require(token in slave, f"slave: protocol reader missing: {token}", failures)

    for token in ('if(token=="1") return 1;', 'if(token=="2") return 2;', 'if(token=="3") return 3;'):
        require(token in slave, f"slave: schema reader missing: {token}", failures)
    require(
        "SnapshotSchema(p[1])" in slave,
        "slave: the META schema field must be validated",
        failures,
    )
    require(
        "x.stoplimit=(n>=9)?StringToDouble(p[8]):0.0;" in slave,
        "slave: schema 3 stop-limit price is not read back",
        failures,
    )
    require(
        "CM_SNAP_SCHEMA" in slave and 'PersistAlert("SCHEMA|"' in slave,
        "slave: an unreadable schema must raise a non-optional alert",
        failures,
    )

    require(
        's.open_total!=ArraySize(s.pos)' in slave
        and 's.pending_total!=ArraySize(s.ord)' in slave,
        "slave: snapshot count integrity check missing",
        failures,
    )
    require("g_trade.OrderDelete" not in master, "master: trading action detected", failures)
    require("PositionClose" not in slave, "slave: automatic position close detected", failures)


def check_shared_contract(master: str, slave: str, failures: list[str]) -> None:
    """Whatever the Slave relies on must be written the same way in the Master."""
    master_rule = function_body(master, "bool ChannelIdValid(")
    slave_rule = function_body(slave, "bool ChannelIdValid(")

    require(master_rule is not None, "master: ChannelIdValid missing", failures)
    require(slave_rule is not None, "slave: ChannelIdValid missing", failures)
    require(
        master_rule is not None and master_rule == slave_rule,
        "channel id rule differs between Master and Slave",
        failures,
    )

    for name, source in (("master", master), ("slave", slave)):
        require(
            "#define CM_CHANNEL_MAX_LEN   32" in source
            or "#define CM_CHANNEL_MAX_LEN     32" in source,
            f"{name}: channel length limit missing or different",
            failures,
        )
        require(
            '"CopyMonitorMulti\\\\CM_"' in source,
            f"{name}: shared snapshot path differs",
            failures,
        )


def check_publication(master: str, failures: list[str]) -> None:
    required = (
        # The snapshot is written aside and renamed, so a reader never sees a
        # half written file.
        '.tmp"',
        "FileMove(",
        "FILE_REWRITE",
        # A reader must never be refused because the writer holds the handle.
        "FILE_SHARE_READ",
        # META totals are derived from the rows that were really written.
        "BuildSnapshot(",
    )
    for token in required:
        require(token in master, f"master: robust publication missing: {token}", failures)


def check_telegram_contract(slave: str, failures: list[str]) -> None:
    required = (
        '"PORTAFOLIO ALIAS: "',
        '"ID MASTER: "',
        '"BROKER MASTER: "',
        '"ID SLAVE: "',
        '"BROKER SLAVE: "',
        '"Estado: POSICIÓN ACTIVA',
        '"Estado: ORDEN PENDIENTE',
        '"Volumen Slave: "',
        '"Stop Loss: "',
        '"Take Profit: "',
        '"Ticket Master: "',
        '"Ticket Slave: "',
        'OrderTypeText(order.type)',
        # A long grouped alert must be split: Telegram drops anything over 4096
        # characters and the whole notice would be lost.
        "TgSplit(",
        "CM_TG_CHUNK_CHARS",
        # A notice that could not be delivered waits in a bounded queue.
        "TgEnqueue(",
        "TgFlush(",
    )
    for token in required:
        require(token in slave, f"slave: Telegram contract missing: {token}", failures)

    for internal_label in ('"Owner comment:', '"Channel:', '"Profile:'):
        require(
            internal_label not in slave,
            f"slave: internal routing data exposed in messages: {internal_label}",
            failures,
        )
    require(
        '"Multiplicador: "' not in slave,
        "slave: internal multiplier exposed in Telegram messages",
        failures,
    )


def check_automatic_corrections(slave: str, failures: list[str]) -> None:
    required = (
        "InpAutoFixPositionSLTP",
        "InpAutoCreateMissingPending",
        "InpAutoModifyPending",
        "InpAutoFixPersistSeconds",
        "ConfirmProblem(",
        "FixPositionStops(",
        "CreatePendingCopy(",
        "ModifyPendingCopy(",
        "ResolveAlert(",
        "g_trade.OrderDelete(",
        # A created copy must be verified as owned AND matchable, or blocked, so
        # the same missing pending is never created twice.
        "StillOwnedPending(o,created_ticket,live)",
        "OrdCompatible(o,master,live)",
        "IsCreateBlocked(",
        "BlockCreate(",
        "PruneState(",
        # Corrections are never attempted when the terminal forbids trading, and
        # never with prices the broker must reject: both report BLOQUEADO.
        "TradingPermitted(",
        "PendingPriceAcceptable(",
        "PositionStopsAcceptable(",
        "SymbolAcceptsNewOrders(",
        # Alerts about tickets that no longer exist must be closed.
        "ResolveVanishedAlerts(",
    )
    for token in required:
        require(token in slave, f"slave: automatic correction missing: {token}", failures)

    for forbidden in ("g_trade.PositionOpen(", "g_trade.PositionClose("):
        require(forbidden not in slave, f"slave: forbidden position action: {forbidden}", failures)

    # Correction notices are mandatory; the old opt-out switches are gone.
    for dead in ("InpNotifyDeleteSuccess", "InpNotifyDeleteFailure"):
        require(dead not in slave, f"slave: removed input still referenced: {dead}", failures)


def check_context(failures: list[str]) -> None:
    index = (ROOT / "ai_context" / "main.md").read_text(encoding="utf-8")
    for note in (
        "architecture.md",
        "protocol_and_safety.md",
        "development.md",
        "pending_matching.md",
        "telegram_messages.md",
        "automatic_corrections.md",
        "robustness.md",
    ):
        require(note in index, f"ai_context index missing {note}", failures)
        require((ROOT / "ai_context" / note).is_file(), f"missing ai_context/{note}", failures)


def check_documentation(failures: list[str]) -> None:
    """Docs must name the sources that actually exist."""
    expected = {path.name for path in SOURCES.values()}
    for relative in ("README.md", "ai_context/architecture.md"):
        text = (ROOT / relative).read_text(encoding="utf-8")
        for name in expected:
            require(name in text, f"{relative}: does not reference {name}", failures)


def main() -> int:
    failures: list[str] = []
    source = {name: check_source(name, path, failures) for name, path in SOURCES.items()}
    check_protocol(source["master"], source["slave"], failures)
    check_shared_contract(source["master"], source["slave"], failures)
    check_publication(source["master"], failures)
    check_telegram_contract(source["slave"], failures)
    check_automatic_corrections(source["slave"], failures)
    check_context(failures)
    check_documentation(failures)

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1

    print(f"OK: {len(SOURCES)} MQL5 sources and shared protocol verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
