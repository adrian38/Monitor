"""Static repository checks that do not launch MetaTrader."""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCES = {
    "master": ROOT / "CopyMonitor_Master_MT5_v1_13_MULTI.mq5",
    "slave": ROOT / "CopyMonitor_Slave_MT5_v1_16_MULTI.mq5",
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


def check_protocol(master: str, slave: str, failures: list[str]) -> None:
    for token in ("META|2|", '"POS|"', '"ORD|"', '"END\\r\\n"'):
        require(token in master, f"master: protocol token missing: {token}", failures)

    require(
        "ACCOUNT_COMPANY" in master,
        "master: schema 2 must publish the Master broker",
        failures,
    )

    for token in ('p[0]=="META"', 'p[1]=="1"', 'p[1]=="2"', 'p[0]=="POS"', 'p[0]=="ORD"', 'p[0]=="END"'):
        require(token in slave, f"slave: protocol reader missing: {token}", failures)

    require(
        's.open_total==ArraySize(s.pos)' in slave
        and 's.pending_total==ArraySize(s.ord)' in slave,
        "slave: snapshot count integrity check missing",
        failures,
    )
    require("g_trade.OrderDelete" not in master, "master: trading action detected", failures)
    require("PositionClose" not in slave, "slave: automatic position close detected", failures)


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
        # A created copy must be verified as owned, or blocked, so the same
        # missing pending is never created twice.
        "StillOwnedPending(o,created_ticket,live)",
        "IsCreateBlocked(",
        "BlockCreate(",
        "PruneState(",
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
    ):
        require(note in index, f"ai_context index missing {note}", failures)
        require((ROOT / "ai_context" / note).is_file(), f"missing ai_context/{note}", failures)


def main() -> int:
    failures: list[str] = []
    source = {name: check_source(name, path, failures) for name, path in SOURCES.items()}
    check_protocol(source["master"], source["slave"], failures)
    check_telegram_contract(source["slave"], failures)
    check_automatic_corrections(source["slave"], failures)
    check_context(failures)

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1

    print(f"OK: {len(SOURCES)} MQL5 sources and shared protocol verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())

