#!/usr/bin/env python3
"""T3 / AC-3 check from two exported relay test logs (BLE_MESH_TEST_PROTOCOL.md).

Usage:
  t3_check.py SENDER.jsonl RECEIVER.jsonl [--middle DEVICE_ID] [--records position]

SENDER is P1's exported log, RECEIVER is P3's. By default it checks the latest T3 beacon run in
the sender log; with --records TYPE it checks the sender's published GhostCore records of that
type instead. Delivery is counted against what the sender actually sent, so beacons lost after
the receiver's last arrival count as lost. Identity means the received copy has the message ID
the sender logged for that sequence, from the sender's device ID. Prints the AC-3 verdict and
exits 0 on pass, 1 on fail, 2 on unusable input.
"""
import argparse
import json
import re
import statistics
import sys

SENT_BEACON = re.compile(r'^sent (?P<id>[0-9A-Fa-f-]{36}) t3\.beacon (?P<body>\{.*?\}) to ')
RECEIVED_BEACON = re.compile(
    r'^received (?P<id>[0-9A-Fa-f-]{36}) (?P<body>\{.*?\}) from (?P<origin>\S+) '
    r'path \[(?P<path>[^\]]*)\] ageMs (?P<age>\d+) via ')
PUBLISHED_RECORD = re.compile(
    r'^published (?P<type>\w+) (?P<id>\S+) epoch (?P<epoch>\S+) seq (?P<seq>\d+) ')
RECEIVED_RECORD = re.compile(
    r'^received (?P<type>\w+) (?P<id>\S+) from (?P<origin>\S+) epoch (?P<epoch>\S+) seq (?P<seq>\d+) '
    r'path \[(?P<path>[^\]]*)\] ageAtHandoff (?P<age>[0-9.]+) via ')

DELIVERY_MIN = 0.95
MEDIAN_AGE_MAX_S = 3.0


def load(path):
    header, events = None, []
    with open(path, encoding='utf-8') as handle:
        for number, line in enumerate(handle, 1):
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                sys.exit(f'{path}:{number}: not JSON')
            if entry.get('type') == 'header':
                header = entry
            else:
                events.append(entry)
    if header is None:
        sys.exit(f'{path}: no header line; export the log from the relay test screen')
    return header, events


def beacon_runs(events):
    """Sender side: {run: {seq: message id}} in log order."""
    runs = {}
    for event in events:
        if event.get('cat') != 't3':
            continue
        match = SENT_BEACON.match(event.get('event', ''))
        if match:
            body = json.loads(match['body'])
            runs.setdefault(body['run'], {})[body['seq']] = match['id'].upper()
    return runs


def percentile(values, share):
    ordered = sorted(values)
    rank = max(1, -(-len(ordered) * share // 100))
    return ordered[int(rank) - 1]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('sender')
    parser.add_argument('receiver')
    parser.add_argument('--middle', help='device ID of the middle phone; the expected path is exactly [MIDDLE]')
    parser.add_argument('--records', metavar='TYPE', help='check GhostCore records of TYPE (e.g. position) instead of beacons')
    args = parser.parse_args()

    sender_header, sender_events = load(args.sender)
    receiver_header, receiver_events = load(args.receiver)
    origin = sender_header['deviceId']

    if args.records:
        sent = {}
        epoch = None
        for event in sender_events:
            match = PUBLISHED_RECORD.match(event.get('event', '')) if event.get('cat') == 'record' else None
            if match and match['type'] == args.records:
                if epoch != match['epoch']:
                    epoch, sent = match['epoch'], {}
                sent[int(match['seq'])] = match['id'].upper()
        label = f'{args.records} records, epoch {epoch}'
        arrivals = []
        for event in receiver_events:
            match = RECEIVED_RECORD.match(event.get('event', '')) if event.get('cat') == 'record' else None
            if match and match['type'] == args.records and match['epoch'] == epoch:
                arrivals.append((int(match['seq']), match['id'].upper(), match['origin'],
                                 [p for p in match['path'].split(',') if p], float(match['age'])))
    else:
        runs = beacon_runs(sender_events)
        if not runs:
            print('No T3 beacon run in the sender log.')
            return 2
        run = list(runs)[-1]
        sent = runs[run]
        label = f'beacon run {run}'
        arrivals = []
        for event in receiver_events:
            match = RECEIVED_BEACON.match(event.get('event', '')) if event.get('cat') == 't3' else None
            if not match:
                continue
            body = json.loads(match['body'])
            if body.get('run') == run:
                arrivals.append((body['seq'], match['id'].upper(), match['origin'],
                                 [p for p in match['path'].split(',') if p], int(match['age']) / 1000))

    if not sent:
        print(f'Nothing sent for {label}.')
        return 2

    first = {}
    duplicates = 0
    for arrival in arrivals:
        if arrival[0] in first:
            duplicates += 1
        else:
            first[arrival[0]] = arrival
    delivered = [first[seq] for seq in sent if seq in first]
    identity_ok = [a for a in delivered if a[1] == sent[a[0]] and a[2] == origin]
    unexpected = [seq for seq in first if seq not in sent]
    ages = [a[4] for a in delivered]
    routes = {}
    for arrival in delivered:
        key = ' > '.join(arrival[3]) or 'direct'
        routes[key] = routes.get(key, 0) + 1

    ratio = len(delivered) / len(sent)
    identity = len(identity_ok) / len(delivered) if delivered else 0
    median_age = statistics.median(ages) if ages else None
    expected_route = args.middle
    route_ok = expected_route is None or (set(routes) == {expected_route} if routes else False)

    print(f'Sender {sender_header.get("label")} ({origin}) build {sender_header.get("build")}; '
          f'receiver {receiver_header.get("label")} ({receiver_header.get("deviceId")}) build {receiver_header.get("build")}')
    print(f'{label}: sent {len(sent)}, delivered {len(delivered)} ({ratio:.1%}), '
          f'duplicates {duplicates}, unknown sequences {len(unexpected)}')
    print(f'identity preserved: {len(identity_ok)}/{len(delivered)} ({identity:.0%})')
    print('routes: ' + ', '.join(f'{k}: {v}' for k, v in sorted(routes.items())))
    if ages:
        print(f'age at receiver (lower bound): median {median_age:.2f} s, p95 {percentile(ages, 95):.2f} s, max {max(ages):.2f} s')
    if len(sent) < 120:
        print(f'note: AC-3 asks for a 2-minute run; only {len(sent)} sent')

    checks = {
        f'delivery >= {DELIVERY_MIN:.0%}': ratio >= DELIVERY_MIN,
        'identity 100 %': bool(delivered) and identity == 1,
        f'median age <= {MEDIAN_AGE_MAX_S:.0f} s': median_age is not None and median_age <= MEDIAN_AGE_MAX_S,
        'no duplicate deliveries': duplicates == 0,
        'route = [middle phone] only' if expected_route else 'route (not checked: pass --middle)': route_ok,
    }
    for name, ok in checks.items():
        print(f'  {"PASS" if ok else "FAIL"}  {name}')
    passed = all(checks.values())
    print('AC-3: ' + ('PASS' if passed else 'FAIL'))
    return 0 if passed else 1


if __name__ == '__main__':
    sys.exit(main())
