"""Regression tests for the conservative Copiix log correlation."""

from datetime import date
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from copiix_log_matches import ORDER, collect, correlate, events, publish


class CopiixLogMatchesTests(unittest.TestCase):
    def test_events_reads_utf16_and_ignores_partial_last_record(self):
        day = date(2026, 11, 11)
        complete = (
            "AB\t0\t12:34:56.789\tTrades\t"
            "'123': order #456 buy stop EURUSD at 1.2 done in 1 ms\r\n"
        )
        partial = (
            "AB\t0\t12:34:57.000\tTrades\t"
            "'123': order #999 sell limit EURUSD at 1.3 done in 1 ms"
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "journal.log"
            path.write_text(complete + partial, encoding="utf-16")

            parsed = list(events(path, "Trades", ORDER, day))

        self.assertEqual(
            parsed,
            [
                (
                    ((day.toordinal() * 24 + 12) * 3600 + 34 * 60 + 56) * 1000
                    + 789,
                    ("123", "456", "buy", "stop"),
                )
            ],
        )

    def test_correlate_accepts_exact_pending_type_among_lifecycle_records(self):
        orders = [(1_000, 101, "buy", "stop")]
        sends = {"copy-1": 1_050}
        copies = {
            "copy-1": {
                (201, frozenset({("buy", "stop"), ("buy", None)})),
            }
        }

        self.assertEqual(correlate(orders, sends, copies), [(101, 201)])

    def test_collect_preserves_all_order_types_for_a_slave_ticket(self):
        parsed_logs = [
            [(1_000, ("111", "101", "buy", "stop"))],
            [
                (2_000, ("222", "201", "buy", "stop")),
                (3_000, ("222", "201", "buy", None)),
            ],
            [(1_050, ("copy-1",))],
            [(3_050, ("201", "copy-1"))],
        ]
        with mock.patch("copiix_log_matches.events", side_effect=parsed_logs):
            orders, sends, copies, failed = collect(
                Path("master"), Path("slave"), "111", "222", [date(2026, 11, 11)]
            )

        self.assertEqual(failed, [])
        self.assertEqual(
            copies,
            {"copy-1": {(201, frozenset({("buy", "stop"), ("buy", None)}))}},
        )
        self.assertEqual(correlate(orders, sends, copies), [(101, 201)])

    def test_correlate_rejects_wrong_type_and_market_orders(self):
        copies = {"copy-1": {(201, frozenset({("buy", "limit")}))}}
        self.assertEqual(
            correlate([(1_000, 101, "buy", "stop")], {"copy-1": 1_050}, copies),
            [],
        )
        self.assertEqual(
            correlate([(1_000, 101, "buy", None)], {"copy-1": 1_050}, copies),
            [],
        )

    def test_correlate_rejects_non_unique_master_or_slave_claims(self):
        order_types = frozenset({("buy", "stop")})
        self.assertEqual(
            correlate(
                [(1_000, 101, "buy", "stop"), (1_010, 102, "buy", "stop")],
                {"copy-1": 1_050},
                {"copy-1": {(201, order_types)}},
            ),
            [],
        )
        self.assertEqual(
            correlate(
                [(1_000, 101, "buy", "stop")],
                {"copy-1": 1_050, "copy-2": 1_050},
                {"copy-1": {(201, order_types)}, "copy-2": {(201, order_types)}},
            ),
            [],
        )

    def test_publish_writes_canonical_sorted_index(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "CM_COPIIX_CH_222.txt"
            publish(path, "CH", "111", "222", [(101, 201), (102, 202)])
            lines = path.read_text(encoding="ascii").splitlines()

        self.assertRegex(lines[0], r"^META\|1\|CH\|111\|222\|[0-9]+$")
        self.assertEqual(lines[1:], ["POS|101|201", "POS|102|202", "END"])


if __name__ == "__main__":
    unittest.main()
