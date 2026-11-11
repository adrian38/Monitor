"""Publish optional diagnostic ticket links from MT5 journals and Copiix logs."""

import argparse
from bisect import bisect_left, bisect_right
from collections import Counter
from datetime import date, timedelta
from pathlib import Path
import re
import sys
import tempfile
import time


ORDER = re.compile(
    r"'(?P<account>[0-9]+)': order #(?P<ticket>[0-9]+) "
    r"(buy|sell)(?: (stop(?: limit)?|limit))? .+ done in "
)
MASTER_OPEN = re.compile(r"I send the command 'open'.*with the ticket '([^']+)'$")
SLAVE_OPEN = re.compile(r"The order was opened successfully: ([0-9]+) / Copiix Ticket : (\S+)$")
WINDOW_MS = 100
MAX_LINKS = 4096


def events(path, source, pattern, day):
    with path.open("rb") as stream:
        raw = stream.read()
    if raw.startswith(b"\xff\xfe"):
        raw = raw[:len(raw) - len(raw) % 2].decode("utf-16")
    else:
        raw = raw.decode("utf-8-sig")
    # MT5 may still be appending the last record.
    lines = raw.splitlines()
    if lines and not raw.endswith("\n"):
        lines.pop()
    for line in lines:
        fields = line.split("\t", 4)
        if len(fields) != 5 or not fields[3].startswith(source):
            continue
        match = pattern.search(fields[4].strip())
        if match and re.fullmatch(r"\d\d:\d\d:\d\d\.\d{3}", fields[2]):
            hours, minutes, seconds, ms = (int(part) for part in re.split("[:.]", fields[2]))
            timestamp = ((day.toordinal() * 24 + hours) * 3600 + minutes * 60 + seconds) * 1000 + ms
            yield timestamp, match.groups()


def collect(master, slave, master_account, slave_account, days):
    orders, sends, copies = [], {}, {}
    failed = []
    for day in sorted(set(days)):
        name = day.strftime("%Y%m%d.log")
        try:
            journal = list(events(master / "logs" / name, "Trades", ORDER, day))
            slave_journal = list(events(slave / "logs" / name, "Trades", ORDER, day))
            outbound = list(events(master / "MQL5" / "logs" / name, "Copiix (", MASTER_OPEN, day))
            inbound = list(events(slave / "MQL5" / "logs" / name, "Copiix (", SLAVE_OPEN, day))
        except (OSError, UnicodeError) as error:
            failed.append((name, type(error).__name__))
            continue
        orders.extend((stamp, int(ticket), side, kind)
                      for stamp, (account, ticket, side, kind) in journal
                      if account == master_account)
        # A pending keeps its ticket when it is activated, so the Journal can
        # contain both its original pending type and a later market entry.  A
        # dict comprehension used to retain only the last record and could
        # erase the exact type evidence needed by the correlation.
        slave_orders = {}
        for _, (account, ticket, side, kind) in slave_journal:
            if account == slave_account:
                slave_orders.setdefault(ticket, set()).add((side, kind))
        for stamp, (copy_id,) in outbound:
            sends.setdefault(copy_id, stamp)
        for _, (ticket, copy_id) in inbound:
            order_types = frozenset(slave_orders.get(ticket, ()))
            copies.setdefault(copy_id, set()).add((int(ticket), order_types))
    return orders, sends, copies, failed


def correlate(orders, sends, copies):
    # Index by the same PC clock on the Master. A Copiix ID identifies the
    # Slave ticket directly, but association with the Master ticket is inferred.
    orders = sorted(set(orders), key=lambda event: event[0])
    times = [event[0] for event in orders]
    candidates = {}
    for copy_id, sent in sends.items():
        start = bisect_left(times, sent - WINDOW_MS)
        end = bisect_right(times, sent)
        candidates[copy_id] = {(ticket, side, kind) for _, ticket, side, kind in orders[start:end]}
    claims = Counter(ticket for group in candidates.values() for ticket, _, _ in group)
    slave_claims = Counter(ticket for group in copies.values() for ticket, _ in group)
    links = []
    for copy_id, group in candidates.items():
        slave_group = copies.get(copy_id, set())
        if len(group) == len(slave_group) == 1:
            (master_ticket, side, kind), = group
            (slave_ticket, slave_order_types), = slave_group
            if (kind and (side, kind) in slave_order_types
                    and claims[master_ticket] == slave_claims[slave_ticket] == 1):
                links.append((master_ticket, slave_ticket))
    return sorted(links)[-MAX_LINKS:]


def publish(path, channel, master_account, slave_account, links):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="ascii", newline="\r\n", dir=path.parent, delete=False
    ) as stream:
        temporary = Path(stream.name)
        try:
            stream.write(f"META|1|{channel}|{master_account}|{slave_account}|{int(time.time())}\n")
            for master, slave in links:
                stream.write(f"POS|{master}|{slave}\n")
            stream.write("END\n")
            stream.close()
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--master-data", type=Path, required=True)
    parser.add_argument("--slave-data", type=Path, required=True)
    parser.add_argument("--master-account", required=True)
    parser.add_argument("--slave-account", required=True)
    parser.add_argument("--channel", required=True)
    parser.add_argument("--common-files", type=Path, required=True)
    parser.add_argument("--date", type=date.fromisoformat, action="append")
    parser.add_argument("--interval", type=int, default=0,
                        help="Refresh every N seconds (5–60). Default: run once.")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_.-]{1,32}", args.channel):
        parser.error("invalid channel")
    if any(not re.fullmatch(r"[1-9][0-9]{0,18}", a)
           for a in (args.master_account, args.slave_account)):
        parser.error("invalid account")
    if args.interval and not 5 <= args.interval <= 60:
        parser.error("--interval must be 0 or between 5 and 60")
    if args.master_data.resolve() == args.slave_data.resolve():
        parser.error("Master and Slave data directories must differ")
    output = (args.common_files / "CopyMonitorMulti" /
              f"CM_COPIIX_{args.channel}_{args.slave_account}.txt")
    previous = None
    while True:
        today = date.today()
        days = args.date or [today - timedelta(days=1), today]
        orders, sends, copies, failed = collect(
            args.master_data, args.slave_data, args.master_account, args.slave_account, days
        )
        links = correlate(orders, sends, copies)
        try:
            if not args.dry_run:
                publish(output, args.channel, args.master_account, args.slave_account, links)
            status = (len(links), failed)
            if status != previous:
                print(f"Copiix: {len(links)} pares; días omitidos: {failed}", flush=True)
            previous = status
            if args.dry_run and not args.interval:
                for master, slave in links:
                    print(f"{master} -> {slave}")
        except OSError as error:
            print(f"No se pudo publicar el índice Copiix ({type(error).__name__}).",
                  file=sys.stderr, flush=True)
            if not args.interval:
                return 1
        if not args.interval:
            return 0
        time.sleep(args.interval)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(0)
