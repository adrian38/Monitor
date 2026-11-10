"""Static repository checks that do not launch MetaTrader."""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCES = {
    "master": ROOT / "CopyMonitor_Master_MT5_v1_14_MULTI.mq5",
    "slave": ROOT / "CopyMonitor_Slave_MT5_v1_24_MULTI.mq5",
}
# MT4 port of the same pair. It writes and reads the very same snapshot, so a
# Master of one platform can feed a Slave of the other.
MT4_SOURCES = {
    "master": ROOT / "CopyMonitor_Master_MT4_v1_00_MULTI.mq4",
    "slave": ROOT / "CopyMonitor_Slave_MT4_v1_04_MULTI.mq4",
}
# Standalone MT4 connection watchdog. It shares no snapshot with the EA pairs.
WATCHDOG = ROOT / "CopyMonitor_Watchdog_MT4_v1_00.mq4"


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


def check_shared_contract(sources: dict[str, str], failures: list[str]) -> None:
    """Every EA that touches the snapshot must derive its name the same way.

    The rule is compared across platforms, not only inside each pair: an MT4
    Master may feed an MT5 Slave, so a divergent rule would leave one of them
    reading a file nobody writes.
    """
    reference_name, reference_rule = None, None

    for name, source in sources.items():
        rule = function_body(source, "bool ChannelIdValid(")
        require(rule is not None, f"{name}: ChannelIdValid missing", failures)
        if rule is None:
            continue
        if reference_rule is None:
            reference_name, reference_rule = name, rule
            continue
        require(
            rule == reference_rule,
            f"channel id rule differs between {reference_name} and {name}",
            failures,
        )

    for name, source in sources.items():
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
        "InpTelegramChunkChars",
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


# The scope of the automatic corrections is the same on both platforms; only
# the trade API underneath differs.
SHARED_CORRECTION_TOKENS = (
    "InpAutoFixPositionSLTP",
    "InpAutoFixPendingSLTP",
    "InpAutoCreateMissingPending",
    "InpAutoModifyPending",
    "InpAutoFixPersistSeconds",
    "ConfirmProblem(",
    "FixPositionStops(",
    "CreatePendingCopy(",
    "ModifyPendingCopy(",
    "ResolveAlert(",
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
    "MasterPositionPresent(",
    # Retiring a whole key family is only for a watch the user switched off.
    "ClearAlertsWithPrefix(",
    # A copy that filled before its Master is a position, not a missing
    # pending: recreating it would duplicate the trade on every early fill.
    "PendingCouldBePosition(",
    "EarlyActivatedCopy(",
    "g_unpaired_pos",
    "early_blocked[m]",
    # Creating an order is not the same as adjusting one that already exists,
    # so it waits on its own delay.
    "ConfirmProblem(create_key,InpMissingPendingConfirmSeconds)",
    # A closed market is a wait, not a failure: one notice, spaced retries
    # and the correction as soon as the session opens.
    "SymbolSessionOpen(",
    "MarketClosedNotice(",
    "MarketWaitDue(",
    "ClearMarketWait(",
    "AlertOnce(",
)


def check_automatic_corrections(
    name: str,
    slave: str,
    platform_tokens: tuple[str, ...],
    forbidden_actions: tuple[str, ...],
    failures: list[str],
) -> None:
    for token in SHARED_CORRECTION_TOKENS + platform_tokens:
        require(token in slave, f"{name}: automatic correction missing: {token}", failures)

    for forbidden in forbidden_actions:
        require(forbidden not in slave, f"{name}: forbidden position action: {forbidden}", failures)

    # Correction notices are mandatory; the old opt-out switches are gone.
    for dead in ("InpNotifyDeleteSuccess", "InpNotifyDeleteFailure"):
        require(dead not in slave, f"{name}: removed input still referenced: {dead}", failures)


# Every problem the user is told about owns a key, and every key is closed
# with ResolveAlert so the RESUELTO really goes out. A grouped per-channel key
# could only be cleared once every problem under it had gone, so the common
# case -- the Master opens first and the copy lands seconds later -- alerted
# and never resolved.
ALERT_KEY_FAMILIES = (
    '"POSMISS|"',
    '"POSAMB|"',
    '"POSEXTRA|"',
    '"ORDMISS|"',
    '"PEARLY|"',
)


def check_alert_lifecycle(name: str, slave: str, failures: list[str]) -> None:
    vanished = function_body(slave, "void ResolveVanishedAlerts(")
    require(vanished is not None, f"{name}: ResolveVanishedAlerts missing", failures)

    for family in ALERT_KEY_FAMILIES:
        prefix = family.strip('"').rstrip("|")
        require(family in slave, f"{name}: alert key family missing: {family}", failures)
        require(
            vanished is not None and f'f[0]=="{prefix}"' in vanished,
            f"{name}: {family} is never closed when its ticket vanishes",
            failures,
        )

    # The grouped alert is gone: it could only be cleared once every problem
    # under it had disappeared, and it was cleared without a RESUELTO.
    require(
        'PersistAlert(key,msg)' not in slave,
        f"{name}: the grouped OPEN alert is still raised",
        failures,
    )
    for retired in ('ClearAlert("OPEN|"+o.channel)', 'ClearAlert("PMISS|"+o.channel)'):
        require(retired in slave, f"{name}: legacy key not retired: {retired}", failures)

    # A snapshot that comes back, and a schema that becomes readable again,
    # both close their CRITICO.
    for recovered in ('ResolveAlert("SCHEMA|"+o.channel', 'ResolveAlert("STALE|"+o.channel'):
        require(recovered in slave, f"{name}: recovery is silent: {recovered}", failures)

    # A count that does not add up has no per-operation alert behind it, so it
    # needs one of its own: the EA drops filtered and foreign operations in
    # silence while building its lists.
    for counted in (
        "void CheckCounts(",
        "CheckCounts(o,s);",
        "ClassifyHidden(",
        "AnyOwnerMatches(",
        "MasterReachable(",
        'ResolveAlert(key,',
        # The count moves, so the notice has to move with it: one message per
        # distinct picture, never one per cycle.
        "void AlertOnChange(",
        "AlertOnChange(key,signature,",
    ):
        require(counted in slave, f"{name}: count reconciliation missing: {counted}", failures)


def check_tunables(source: dict[str, str], failures: list[str]) -> None:
    """Every timer is an input carrying the value the EA used when it was fixed."""
    expected = {
        "slave": {
            "InpStateTTLSeconds": "3600",
            "InpSnapshotReadAttempts": "3",
            "InpSnapshotReadRetryMs": "15",
            "InpMarketClosedRetrySeconds": "60",
            "InpMissingPendingConfirmSeconds": "5",
            "InpTelegramChunkChars": "3000",
            "InpTelegramQueueMax": "40",
            "InpTelegramSendsPerCycle": "2",
        },
        "master": {"InpPublishFailLogSeconds": "10"},
    }

    for name, inputs in expected.items():
        for input_name, default in inputs.items():
            declared = re.search(
                rf"^input\s+int\s+{input_name}\s*=\s*{default}\s*;",
                source[name],
                re.MULTILINE,
            )
            require(
                bool(declared),
                f"{name}: {input_name} must be an input defaulting to {default}",
                failures,
            )
            # An input nobody reads is a knob that does nothing.
            require(
                source[name].count(input_name) > 1,
                f"{name}: {input_name} is declared but never used",
                failures,
            )
        # Every input needs a bound, or a typo in the dialog breaks the EA.
        for input_name in inputs:
            require(
                input_name in source[name].split("bool Validate()")[-1]
                or input_name in source[name].split("int OnInit()")[-1],
                f"{name}: {input_name} is not validated at init",
                failures,
            )

    for dead in (
        "CM_STATE_TTL_SECONDS",
        "CM_READ_ATTEMPTS",
        "CM_TG_CHUNK_CHARS",
        "CM_TG_QUEUE_MAX",
        "CM_TG_FLUSH_PER_CYCLE",
    ):
        require(
            dead not in source["slave"],
            f"slave: hardcoded timer still present: {dead}",
            failures,
        )

    # The channel length is part of the shared contract, not a tunable.
    require(
        all("#define CM_CHANNEL_MAX_LEN" in text for text in source.values()),
        "channel length must stay a shared constant",
        failures,
    )


def check_mt4_protocol(master: str, slave: str, failures: list[str]) -> None:
    """The MT4 pair writes and reads the very same snapshot as the MQL5 pair."""
    for token in ('"META|"', '"POS|"', '"ORD|"', '"END\\r\\n"'):
        require(token in master, f"master mt4: protocol token missing: {token}", failures)

    require(
        "#define CM_SNAPSHOT_SCHEMA   3" in master,
        "master mt4: published schema must be 3",
        failures,
    )
    require(
        '"META|"+IntegerToString(CM_SNAPSHOT_SCHEMA)' in master,
        "master mt4: META must declare the schema constant",
        failures,
    )
    require(
        "ACCOUNT_COMPANY" in master,
        "master mt4: schema 2 must publish the Master broker",
        failures,
    )
    # MT4 has no stop-limit order, but the ORD record keeps a fixed field count
    # so an MQL5 reader still parses it.
    require(
        'DoubleToString(0.0,10)+"\\r\\n"' in master,
        "master mt4: the schema 3 stop-limit field must still be published as zero",
        failures,
    )

    for token in ('p[0]=="META"', 'p[0]=="POS"', 'p[0]=="ORD"', 'p[0]=="END"'):
        require(token in slave, f"slave mt4: protocol reader missing: {token}", failures)

    for token in ('if(token=="1") return 1;', 'if(token=="2") return 2;', 'if(token=="3") return 3;'):
        require(token in slave, f"slave mt4: schema reader missing: {token}", failures)
    require(
        "SnapshotSchema(p[1])" in slave,
        "slave mt4: the META schema field must be validated",
        failures,
    )
    require(
        "x.stoplimit=(n>=9)?StringToDouble(p[8]):0.0;" in slave,
        "slave mt4: schema 3 stop-limit price is not read back",
        failures,
    )
    require(
        "CM_SNAP_SCHEMA" in slave and 'PersistAlert("SCHEMA|"' in slave,
        "slave mt4: an unreadable schema must raise a non-optional alert",
        failures,
    )
    require(
        "s.open_total!=ArraySize(s.pos)" in slave
        and "s.pending_total!=ArraySize(s.ord)" in slave,
        "slave mt4: snapshot count integrity check missing",
        failures,
    )

    # The Master only publishes and the Slave never closes a position.
    for forbidden in ("OrderSend(", "OrderModify(", "OrderDelete(", "OrderClose("):
        require(
            forbidden not in master,
            f"master mt4: trading action detected: {forbidden}",
            failures,
        )
    require("OrderClose(" not in slave, "slave mt4: automatic position close detected", failures)


def check_mt4_specifics(master: str, slave: str, failures: list[str]) -> None:
    """What MQL4 forces the port to do differently must stay in place."""
    # OrderSelect by ticket also finds closed trades: without OrderCloseTime an
    # alert about a deleted pending would never be resolved.
    require(
        "bool SelectLiveOrder(" in slave and "OrderCloseTime()==0" in slave,
        "slave mt4: a history order must not count as a live one",
        failures,
    )
    for token in (
        # Trade retcodes become MT4 error codes.
        "CM_ERR_TRADE_DISABLED",
        "CM_ERR_OFF_QUOTES",
        # An OrderModify that changes nothing is a success, not a failure.
        "CM_ERR_NO_RESULT",
        # MT4 refuses to touch a pending inside the freeze distance.
        "PendingNotFrozen(",
        "MODE_FREEZELEVEL",
        # One trade context per terminal: busy is a wait, not an alert.
        "IsTradeContextBusy(",
        # A comment longer than MT4 allows could never match a real order.
        "CM_MT4_COMMENT_MAX_LEN",
    ):
        require(token in slave, f"slave mt4: missing contract: {token}", failures)

    # MT4 has no OnTradeTransaction: OnTick carries the immediate reaction.
    require(
        "void OnTick()" in master and "Cycle(false)" in master,
        "master mt4: OnTick must replace OnTradeTransaction",
        failures,
    )
    require(
        "void OnTick()" in slave and "SlaveStateSignature(" in slave,
        "slave mt4: OnTick must replace OnTradeTransaction",
        failures,
    )

    # MT4 cannot place a stop-limit order, so it must never try.
    creatable = function_body(slave, "bool CreatablePendingType(")
    require(creatable is not None, "slave mt4: CreatablePendingType missing", failures)
    require(
        creatable is not None and "STOP_LIMIT" not in creatable,
        "slave mt4: a stop-limit copy must stay blocked, not attempted",
        failures,
    )


def check_watchdog(failures: list[str]) -> None:
    """The MT4 watchdog only reports: it must never touch the account."""
    require(WATCHDOG.is_file(), f"missing source: {WATCHDOG.name}", failures)
    if not WATCHDOG.is_file():
        return

    source = WATCHDOG.read_text(encoding="utf-8")
    version = property_version(source)
    file_version = re.search(r"_v(\d+)_(\d+)\.mq4$", WATCHDOG.name)
    expected = f"{file_version.group(1)}.{file_version.group(2)}" if file_version else None

    require(version == expected, "watchdog: filename/property version mismatch", failures)
    require(
        bool(version and f'#define CM_WD_VERSION        "{version}"' in source),
        "watchdog: visible version label is stale",
        failures,
    )
    require(
        bool(version and f"Watchdog MT4 v{version}" in source),
        "watchdog: description label is stale",
        failures,
    )
    require(source.count("{") == source.count("}"), "watchdog: unbalanced braces", failures)
    require("#property strict" in source, "watchdog: strict mode missing", failures)

    required = (
        # Without a connection no ticks arrive: the timer is the only engine
        # that still runs when the alert has to go out.
        "EventSetTimer(InpCheckSeconds)",
        "void OnTimer()",
        "IsConnected()",
        # TimeCurrent() freezes on the last quote and would mis-measure the
        # outage, so every instant comes from the local clock.
        "TimeLocal()",
        # A brief drop is not an outage, and the outage is repeated until it
        # clears.
        "InpOfflineConfirmSeconds",
        "InpOfflineRepeatMinutes",
        '"Estado: TERMINAL OFFLINE\\n"',
        '"Estado: TERMINAL ONLINE\\n"',
        '"PORTAFOLIO ALIAS: "',
        '"ID TERMINAL: "',
        '"BROKER TERMINAL: "',
        "🔴 COPYMONITOR — CRÍTICO",
        "🟢 COPYMONITOR — RESUELTO",
        # A notice that could not be delivered waits in a bounded queue.
        "TgSplit(",
        "TgEnqueue(",
        "TgFlush(",
        "InpTelegramChunkChars",
    )
    for token in required:
        require(token in source, f"watchdog: missing contract: {token}", failures)

    # The watchdog observes and notifies. Any order call is a contract break.
    for forbidden in ("OrderSend(", "OrderClose(", "OrderDelete(", "OrderModify("):
        require(forbidden not in source, f"watchdog: trading action detected: {forbidden}", failures)

    # Telegram enabled without credentials would leave the user unaware and
    # unwarned, so the EA must refuse to start.
    require(
        "bool Validate()" in source and "return INIT_FAILED" in source,
        "watchdog: inputs are not validated at init",
        failures,
    )
    for input_name in (
        "InpPortfolioAlias",
        "InpCheckSeconds",
        "InpOfflineConfirmSeconds",
        "InpOfflineRepeatMinutes",
        "InpTelegramQueueMax",
        "InpTelegramSendsPerCycle",
    ):
        require(
            input_name in source.split("bool Validate()")[-1].split("int OnInit()")[0],
            f"watchdog: {input_name} is not validated at init",
            failures,
        )

    expected_defaults = {
        "InpCheckSeconds": "5",
        "InpOfflineConfirmSeconds": "60",
        "InpOfflineRepeatMinutes": "5",
    }
    for input_name, default in expected_defaults.items():
        require(
            bool(re.search(rf"^input\s+int\s+{input_name}\s*=\s*{default}\s*;", source, re.MULTILINE)),
            f"watchdog: {input_name} must be an input defaulting to {default}",
            failures,
        )


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
        "terminal_watchdog.md",
        "mt4_port.md",
        "alert_lifecycle.md",
    ):
        require(note in index, f"ai_context index missing {note}", failures)
        require((ROOT / "ai_context" / note).is_file(), f"missing ai_context/{note}", failures)


def check_documentation(failures: list[str]) -> None:
    """Docs must name the sources that actually exist."""
    expected = {path.name for path in SOURCES.values()}
    expected |= {path.name for path in MT4_SOURCES.values()}
    for relative in ("README.md", "ai_context/architecture.md"):
        text = (ROOT / relative).read_text(encoding="utf-8")
        for name in expected:
            require(name in text, f"{relative}: does not reference {name}", failures)

    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    require(
        WATCHDOG.name in readme,
        f"README.md: does not reference {WATCHDOG.name}",
        failures,
    )


def main() -> int:
    failures: list[str] = []
    source = {name: check_source(name, path, failures) for name, path in SOURCES.items()}
    mt4 = {
        name: check_source(f"{name} mt4", path, failures)
        for name, path in MT4_SOURCES.items()
    }

    check_protocol(source["master"], source["slave"], failures)
    check_publication(source["master"], failures)
    check_telegram_contract(source["slave"], failures)
    check_automatic_corrections(
        "slave",
        source["slave"],
        ("g_trade.OrderDelete(", "TradeRetcodeIsMarketClosed(", "TRADE_RETCODE_MARKET_CLOSED"),
        ("g_trade.PositionOpen(", "g_trade.PositionClose("),
        failures,
    )
    check_alert_lifecycle("slave", source["slave"], failures)
    check_tunables(source, failures)

    check_mt4_protocol(mt4["master"], mt4["slave"], failures)
    check_mt4_specifics(mt4["master"], mt4["slave"], failures)
    check_publication(mt4["master"], failures)
    check_telegram_contract(mt4["slave"], failures)
    check_automatic_corrections(
        "slave mt4",
        mt4["slave"],
        ("OrderDelete((int)", "TradeErrorIsMarketClosed(", "CM_ERR_MARKET_CLOSED"),
        ("OrderClose(",),
        failures,
    )
    check_alert_lifecycle("slave mt4", mt4["slave"], failures)
    check_tunables(mt4, failures)

    # The channel rule is shared by every EA that names the snapshot file,
    # whatever platform it runs on.
    check_shared_contract(
        {
            "master": source["master"],
            "slave": source["slave"],
            "master mt4": mt4["master"],
            "slave mt4": mt4["slave"],
        },
        failures,
    )

    check_watchdog(failures)
    check_context(failures)
    check_documentation(failures)

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1

    print(
        f"OK: {len(SOURCES)} MQL5 sources, {len(MT4_SOURCES)} MQL4 sources, "
        "shared protocol and the MT4 watchdog verified"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
