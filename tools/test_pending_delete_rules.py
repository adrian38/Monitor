"""Behaviour tests of the MT5 pending delete rules, without launching MetaTrader.

MQL5 only runs inside MetaTrader, so the two decision rules that authorise the
deletion of an extra Slave pending -- `UniquePendingDeletePair` and
`PendingDeleteBlock` -- are transliterated here and exercised against the cases
that matter, including the real AUDUSD pair of 2026-11-11.

`test_model_matches_the_ea_source` compares the transliteration against the
function bodies of the EA with comments removed. Any change to those bodies
fails the test, so the model cannot drift away from the code in silence, and
`test_mt4_port_decides_with_the_same_rules` holds the MQL4 port to the very
same bodies: the destructive action is decided identically on both platforms.
"""

from __future__ import annotations

from dataclasses import dataclass, field
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from verify_project import MT4_SOURCES, SOURCES

# ENUM_ORDER_TYPE of MT5, as published in the snapshot.
BUY_LIMIT = 2
SELL_LIMIT = 3

BLOCK_MASTER_ALIVE = "El ticket Master vinculado sigue pendiente."
BLOCK_ALTERNATIVE = (
    "Otra pendiente Master podría corresponder a esta copia y no se ha "
    "identificado una copia distinta para ella."
)
LEGACY_BLOCK_ALTERNATIVE = (
    "Otra pendiente Master del mismo símbolo equivalente y tipo podría "
    "corresponder a esta copia."
)

# Bodies of the EA, normalised without comments. Regenerate them deliberately,
# never to make the test pass again without reviewing the new rule.
EA_BODIES = {
    "bool OrdCompatible(const Owner &o,const OrdRec &m,const OrdRec &s)": (
        "{ if(!SymbolEq(o.channel,m.symbol,s.symbol))return false;"
        " if(m.type!=s.type)return false;"
        " if(!VolEq(s.symbol,s.vol,m.vol*o.mult))return false; return true; }"
    ),
    "bool OrdCompatibleIgnoringVolume(": (
        "{ if(!SymbolEq(o.channel,m.symbol,s.symbol))return false;"
        " if(m.type!=s.type)return false; return true; }"
    ),
    "bool OrdValuesAgree(": (
        "{ double stop_tol=StopTolPrice(s.symbol);"
        " double price_tol=PendingTolPrice(s.symbol);"
        " if(!PriceEq(m.price,s.price,price_tol)) return false;"
        " if(InpCheckStopLoss && !StopEq(m.sl,s.sl,stop_tol)) return false;"
        " if(InpCheckTakeProfit && !StopEq(m.tp,s.tp,stop_tol)) return false;"
        " if(IsStopLimitType(m.type) && m.stoplimit>0 &&"
        " !PriceEq(m.stoplimit,s.stoplimit,price_tol)) return false; return true; }"
    ),
    "bool UniquePendingDeletePair(": (
        "{ if(!OrdCompatible(o,master[m],slave[s])) return false;"
        " bool agrees=OrdValuesAgree(master[m],slave[s]);"
        " for(int i=0;i<ArraySize(master);i++)"
        " if(i!=m && OrdCompatibleIgnoringVolume(o,master[i],slave[s]) &&"
        " (!agrees || OrdValuesAgree(master[i],slave[s]))) return false;"
        " for(int i=0;i<ArraySize(slave);i++)"
        " if(i!=s && OrdCompatibleIgnoringVolume(o,master[m],slave[i]) &&"
        " (!agrees || OrdValuesAgree(master[m],slave[i]))) return false; return true; }"
    ),
    "string PendingDeleteBlock(": (
        "{ if(PendingOrderIndex(snap.ord,master_ticket)>=0)"
        ' return "' + BLOCK_MASTER_ALIVE + '";'
        " for(int m=0;m<ArraySize(snap.ord);m++)"
        " { if(!OrdCompatibleIgnoringVolume(o,snap.ord[m],slave[s])) continue;"
        " bool has_own_copy=false; for(int i=0;i<ArraySize(slave);i++)"
        " { if(i==s || !UniquePendingDeletePair(o,snap.ord,m,slave,i)) continue;"
        " has_own_copy=true; break; }"
        ' if(!has_own_copy) return "' + BLOCK_ALTERNATIVE + '"; } return ""; }'
    ),
}


def function_body(source: str, signature: str) -> str | None:
    """The body of a function, without comments and with collapsed blanks."""
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
                body = re.sub(r"//[^\n]*", "", source[open_brace : index + 1])
                return re.sub(r"\s+", " ", body).strip()
    return None


# ---------------------------------------------------------------- EA model ---
@dataclass(frozen=True)
class Symbol:
    """The symbol properties the rules read from the Slave terminal."""

    name: str
    point: float = 0.00001
    volume_step: float = 0.01
    volume_min: float = 0.01
    volume_max: float = 100.0


@dataclass(frozen=True)
class Ord:
    """An OrdRec: a pending order of either side."""

    ticket: int
    symbol: str
    type: int
    vol: float
    price: float
    sl: float = 0.0
    tp: float = 0.0
    stoplimit: float = 0.0


@dataclass
class Rules:
    """The inputs of the EA that the two rules depend on."""

    symbols: dict[str, Symbol] = field(default_factory=dict)
    # InpLotMultiplier or the positional InpVolumeMultipliers of the channel.
    mult: float = 1.0
    # InpPendingPriceTolerancePoints and InpSLTPTolerancePoints.
    pending_tolerance_points: int = 100
    sltp_tolerance_points: int = 10
    volume_tolerance_steps: int = 1
    check_stop_loss: bool = True
    check_take_profit: bool = True
    # InpSymbolMaps of this channel, as (master_symbol, slave_symbol).
    symbol_maps: tuple[tuple[str, str], ...] = ()

    def spec(self, symbol: str) -> Symbol:
        return self.symbols.get(symbol, Symbol(symbol))

    def symbol_eq(self, master_symbol: str, slave_symbol: str) -> bool:
        if master_symbol == slave_symbol:
            return True
        return (master_symbol, slave_symbol) in self.symbol_maps

    def expected_slave_volume(self, slave_symbol: str, master_volume: float) -> float:
        spec = self.spec(slave_symbol)
        raw = master_volume * self.mult
        if spec.volume_step <= 0:
            return raw
        normalized = round(raw / spec.volume_step) * spec.volume_step
        if spec.volume_min > 0:
            normalized = max(spec.volume_min, normalized)
        if spec.volume_max > 0:
            normalized = min(spec.volume_max, normalized)
        return normalized

    def vol_eq(self, slave_symbol: str, actual: float, master_volume: float) -> bool:
        spec = self.spec(slave_symbol)
        step = spec.volume_step if spec.volume_step > 0 else 0.01
        normalized = self.expected_slave_volume(slave_symbol, master_volume)
        tolerance = max(0, self.volume_tolerance_steps) * step
        return abs(actual - normalized) <= tolerance + 1e-9

    def pending_tolerance(self, slave_symbol: str) -> float:
        return self.pending_tolerance_points * self.spec(slave_symbol).point

    def stop_tolerance(self, slave_symbol: str) -> float:
        return self.sltp_tolerance_points * self.spec(slave_symbol).point


def price_eq(a: float, b: float, tolerance: float) -> bool:
    return abs(a - b) <= tolerance + 1e-9


def stop_eq(a: float, b: float, tolerance: float) -> bool:
    a_zero, b_zero = abs(a) < 1e-12, abs(b) < 1e-12
    if a_zero and b_zero:
        return True
    if a_zero != b_zero:
        return False
    return abs(a - b) <= tolerance + 1e-9


def is_stop_limit_type(order_type: int) -> bool:
    # ORDER_TYPE_BUY_STOP_LIMIT and ORDER_TYPE_SELL_STOP_LIMIT.
    return order_type in (6, 7)


def ord_compatible(rules: Rules, master: Ord, slave: Ord) -> bool:
    if not rules.symbol_eq(master.symbol, slave.symbol):
        return False
    if master.type != slave.type:
        return False
    return rules.vol_eq(slave.symbol, slave.vol, master.vol)


def ord_compatible_ignoring_volume(rules: Rules, master: Ord, slave: Ord) -> bool:
    if not rules.symbol_eq(master.symbol, slave.symbol):
        return False
    return master.type == slave.type


def ord_values_agree(rules: Rules, master: Ord, slave: Ord) -> bool:
    stop_tol = rules.stop_tolerance(slave.symbol)
    price_tol = rules.pending_tolerance(slave.symbol)

    if not price_eq(master.price, slave.price, price_tol):
        return False
    if rules.check_stop_loss and not stop_eq(master.sl, slave.sl, stop_tol):
        return False
    if rules.check_take_profit and not stop_eq(master.tp, slave.tp, stop_tol):
        return False
    if (
        is_stop_limit_type(master.type)
        and master.stoplimit > 0
        and not price_eq(master.stoplimit, slave.stoplimit, price_tol)
    ):
        return False
    return True


def unique_pending_delete_pair(
    rules: Rules, master: list[Ord], m: int, slave: list[Ord], s: int
) -> bool:
    """v1.34 rule: values may tell apart orders of the same symbol and type."""
    if not ord_compatible(rules, master[m], slave[s]):
        return False
    agrees = ord_values_agree(rules, master[m], slave[s])
    for i in range(len(master)):
        if (
            i != m
            and ord_compatible_ignoring_volume(rules, master[i], slave[s])
            and (not agrees or ord_values_agree(rules, master[i], slave[s]))
        ):
            return False
    for i in range(len(slave)):
        if (
            i != s
            and ord_compatible_ignoring_volume(rules, master[m], slave[i])
            and (not agrees or ord_values_agree(rules, master[m], slave[i]))
        ):
            return False
    return True


def legacy_unique_pending_delete_pair(
    rules: Rules, master: list[Ord], m: int, slave: list[Ord], s: int
) -> bool:
    """v1.31 to v1.33 rule, kept to prove what it rejected."""
    if not ord_compatible(rules, master[m], slave[s]):
        return False
    for i in range(len(master)):
        if i != m and ord_compatible_ignoring_volume(rules, master[i], slave[s]):
            return False
    for i in range(len(slave)):
        if i != s and ord_compatible_ignoring_volume(rules, master[m], slave[i]):
            return False
    return True


def pending_delete_block(
    rules: Rules, master: list[Ord], master_ticket: int, slave: list[Ord], s: int
) -> str:
    """v1.34 rule. An empty string authorises the confirmation window."""
    if any(order.ticket == master_ticket for order in master):
        return BLOCK_MASTER_ALIVE

    for m in range(len(master)):
        if not ord_compatible_ignoring_volume(rules, master[m], slave[s]):
            continue

        has_own_copy = False
        for i in range(len(slave)):
            if i == s or not unique_pending_delete_pair(rules, master, m, slave, i):
                continue
            has_own_copy = True
            break
        if not has_own_copy:
            return BLOCK_ALTERNATIVE
    return ""


def legacy_pending_delete_block(
    rules: Rules, master: list[Ord], master_ticket: int, slave: Ord
) -> str:
    """v1.31 to v1.33 rule, for comparison."""
    if any(order.ticket == master_ticket for order in master):
        return BLOCK_MASTER_ALIVE
    for order in master:
        if ord_compatible_ignoring_volume(rules, order, slave):
            return LEGACY_BLOCK_ALTERNATIVE
    return ""


# ------------------------------------------------------------------ fixtures --
AUDUSD = Symbol("AUDUSD", point=0.00001)
AUDUSD_RULES = Rules(symbols={"AUDUSD": AUDUSD})

# Real case of 2026-11-11 in the Slave journal 20261111.log: two sell limits of
# 0.01 lots, 294 points apart, far beyond the 100 points of
# InpPendingPriceTolerancePoints. The Master tickets are placeholders; only the
# published values take part in the rules.
SLAVE_HIGH = Ord(783684081, "AUDUSD", SELL_LIMIT, 0.01, 0.69256)
SLAVE_LOW = Ord(783684178, "AUDUSD", SELL_LIMIT, 0.01, 0.68962)
MASTER_HIGH = Ord(900001, "AUDUSD", SELL_LIMIT, 0.01, 0.69256)
MASTER_LOW = Ord(900002, "AUDUSD", SELL_LIMIT, 0.01, 0.68962)


class EaSourceTests(unittest.TestCase):
    def test_model_matches_the_ea_source(self):
        source = SOURCES["slave"].read_text(encoding="utf-8")
        for signature, expected in EA_BODIES.items():
            with self.subTest(signature=signature):
                self.assertEqual(function_body(source, signature), expected)

    def test_mt4_port_decides_with_the_same_rules(self):
        """The two platforms must not drift apart on the destructive action."""
        source = MT4_SOURCES["slave"].read_text(encoding="utf-8")
        for signature, expected in EA_BODIES.items():
            with self.subTest(signature=signature):
                self.assertEqual(function_body(source, signature), expected)


class AudUsdCaseTests(unittest.TestCase):
    """The pair that v1.33 could not link."""

    def test_the_two_copies_are_distinguishable_by_value(self):
        self.assertFalse(ord_values_agree(AUDUSD_RULES, MASTER_HIGH, SLAVE_LOW))
        self.assertFalse(ord_values_agree(AUDUSD_RULES, MASTER_LOW, SLAVE_HIGH))
        self.assertTrue(ord_values_agree(AUDUSD_RULES, MASTER_HIGH, SLAVE_HIGH))
        self.assertTrue(ord_values_agree(AUDUSD_RULES, MASTER_LOW, SLAVE_LOW))

    def test_v133_rejected_both_pairs(self):
        master = [MASTER_HIGH, MASTER_LOW]
        slave = [SLAVE_HIGH, SLAVE_LOW]
        for m in range(2):
            for s in range(2):
                with self.subTest(master=m, slave=s):
                    self.assertFalse(
                        legacy_unique_pending_delete_pair(
                            AUDUSD_RULES, master, m, slave, s
                        )
                    )

    def test_v133_rejected_the_pair_even_with_a_single_master_order(self):
        """Two copies of the same symbol and type were enough to lose the link."""
        self.assertFalse(
            legacy_unique_pending_delete_pair(
                AUDUSD_RULES, [MASTER_HIGH], 0, [SLAVE_HIGH, SLAVE_LOW], 0
            )
        )

    def test_v134_links_each_copy_to_its_own_master_order(self):
        master = [MASTER_HIGH, MASTER_LOW]
        slave = [SLAVE_HIGH, SLAVE_LOW]
        self.assertTrue(unique_pending_delete_pair(AUDUSD_RULES, master, 0, slave, 0))
        self.assertTrue(unique_pending_delete_pair(AUDUSD_RULES, master, 1, slave, 1))
        self.assertFalse(unique_pending_delete_pair(AUDUSD_RULES, master, 0, slave, 1))
        self.assertFalse(unique_pending_delete_pair(AUDUSD_RULES, master, 1, slave, 0))

    def test_v134_authorises_the_copy_whose_master_order_vanished(self):
        """The Master cancels its 0.69256 order; only that copy is extra."""
        master = [MASTER_LOW]
        slave = [SLAVE_HIGH, SLAVE_LOW]
        self.assertEqual(
            pending_delete_block(AUDUSD_RULES, master, MASTER_HIGH.ticket, slave, 0),
            "",
        )
        self.assertEqual(
            pending_delete_block(AUDUSD_RULES, master, MASTER_LOW.ticket, slave, 1),
            BLOCK_MASTER_ALIVE,
        )

    def test_v133_blocked_that_same_deletion(self):
        self.assertEqual(
            legacy_pending_delete_block(
                AUDUSD_RULES, [MASTER_LOW], MASTER_HIGH.ticket, SLAVE_HIGH
            ),
            LEGACY_BLOCK_ALTERNATIVE,
        )


class TwinPendingTests(unittest.TestCase):
    """Indistinguishable orders must keep blocking the deletion."""

    def test_identical_copies_cannot_be_linked(self):
        master = [
            Ord(900001, "AUDUSD", SELL_LIMIT, 0.01, 0.69256),
            Ord(900002, "AUDUSD", SELL_LIMIT, 0.01, 0.69256),
        ]
        slave = [
            Ord(783684081, "AUDUSD", SELL_LIMIT, 0.01, 0.69256),
            Ord(783684178, "AUDUSD", SELL_LIMIT, 0.01, 0.69256),
        ]
        for m in range(2):
            for s in range(2):
                with self.subTest(master=m, slave=s):
                    self.assertFalse(
                        unique_pending_delete_pair(AUDUSD_RULES, master, m, slave, s)
                    )

    def test_identical_copies_block_the_deletion(self):
        master = [Ord(900002, "AUDUSD", SELL_LIMIT, 0.01, 0.69256)]
        slave = [
            Ord(783684081, "AUDUSD", SELL_LIMIT, 0.01, 0.69256),
            Ord(783684178, "AUDUSD", SELL_LIMIT, 0.01, 0.69256),
        ]
        self.assertEqual(
            pending_delete_block(AUDUSD_RULES, master, 900001, slave, 0),
            BLOCK_ALTERNATIVE,
        )

    def test_prices_inside_the_tolerance_are_not_distinguishable(self):
        """50 points apart, under InpPendingPriceTolerancePoints = 100."""
        master = [
            Ord(900001, "AUDUSD", SELL_LIMIT, 0.01, 0.69256),
            Ord(900002, "AUDUSD", SELL_LIMIT, 0.01, 0.69206),
        ]
        slave = [
            Ord(783684081, "AUDUSD", SELL_LIMIT, 0.01, 0.69256),
            Ord(783684178, "AUDUSD", SELL_LIMIT, 0.01, 0.69206),
        ]
        self.assertFalse(unique_pending_delete_pair(AUDUSD_RULES, master, 0, slave, 0))
        self.assertEqual(
            pending_delete_block(AUDUSD_RULES, [master[1]], 900001, slave, 0),
            BLOCK_ALTERNATIVE,
        )

    def test_a_different_stop_loss_tells_two_twin_prices_apart(self):
        master = [
            Ord(900001, "AUDUSD", SELL_LIMIT, 0.01, 0.69256, sl=0.69500),
            Ord(900002, "AUDUSD", SELL_LIMIT, 0.01, 0.69256, sl=0.70000),
        ]
        slave = [
            Ord(783684081, "AUDUSD", SELL_LIMIT, 0.01, 0.69256, sl=0.69500),
            Ord(783684178, "AUDUSD", SELL_LIMIT, 0.01, 0.69256, sl=0.70000),
        ]
        self.assertTrue(unique_pending_delete_pair(AUDUSD_RULES, master, 0, slave, 0))
        self.assertEqual(
            pending_delete_block(AUDUSD_RULES, [master[1]], 900001, slave, 0), ""
        )


class AlternativeMasterTests(unittest.TestCase):
    def test_an_alternative_without_its_own_copy_blocks(self):
        """A live Master order with no identified copy may own this one."""
        master = [Ord(900003, "AUDUSD", SELL_LIMIT, 0.01, 0.70500)]
        slave = [SLAVE_HIGH]
        self.assertEqual(
            pending_delete_block(AUDUSD_RULES, master, MASTER_HIGH.ticket, slave, 0),
            BLOCK_ALTERNATIVE,
        )

    def test_another_symbol_never_blocks(self):
        master = [Ord(900004, "XAUUSD", SELL_LIMIT, 0.01, 4695.97)]
        slave = [SLAVE_HIGH]
        self.assertEqual(
            pending_delete_block(AUDUSD_RULES, master, MASTER_HIGH.ticket, slave, 0),
            "",
        )

    def test_another_type_never_blocks(self):
        master = [Ord(900005, "AUDUSD", BUY_LIMIT, 0.01, 0.69256)]
        slave = [SLAVE_HIGH]
        self.assertEqual(
            pending_delete_block(AUDUSD_RULES, master, MASTER_HIGH.ticket, slave, 0),
            "",
        )

    def test_an_empty_master_side_authorises_every_copy(self):
        slave = [SLAVE_HIGH, SLAVE_LOW]
        self.assertEqual(
            pending_delete_block(AUDUSD_RULES, [], MASTER_HIGH.ticket, slave, 0), ""
        )
        self.assertEqual(
            pending_delete_block(AUDUSD_RULES, [], MASTER_LOW.ticket, slave, 1), ""
        )

    def test_a_mapped_symbol_is_the_same_symbol(self):
        rules = Rules(
            symbols={"GER40": Symbol("GER40", point=0.01)},
            symbol_maps=(("DE40", "GER40"),),
        )
        master = [Ord(900006, "DE40", SELL_LIMIT, 0.01, 23500.0)]
        slave = [Ord(783684300, "GER40", SELL_LIMIT, 0.01, 23500.0)]
        self.assertEqual(
            pending_delete_block(rules, master, 900007, slave, 0), BLOCK_ALTERNATIVE
        )


if __name__ == "__main__":
    unittest.main()
