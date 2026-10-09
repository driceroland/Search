#!/usr/bin/env python3
"""Bounded live WebKit worker-port checks, using a disposable hidden Search.

Build Search.app first (on Intel, copy build/intel/Search.app to build/Search.app)
then run: python3 Tests/ExtensionWorkerRecovery/live.py

Uses split_view's isolated SEARCH_PROBE lifecycle and the existing bench
ext-folder, ext-page and eval commands. No accounts, model calls, Web Inspector,
private process-killing hooks or production test APIs are required. All fixture
traffic is local. Exit 0 means the assertions ran and passed, not just that the
app built. Exit 2 means a precondition was unavailable.

The explicit revive cases deliberately withhold APPLICATION replies, leaving
Search's ping responder healthy. They prove native unload/reload delivery to real
ports; they do not prove dead-worker detection or background.wake's failed-start
recovery branch. A separate short real event-loop stall checks delayed responses
without changing Search's timeouts. Truly hung workers and delayed startup remain
manual coverage; the final report says so explicitly.
"""

import argparse
import json
import re
import platform
import signal
import subprocess
import sys
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
APP = ROOT / 'build' / 'Search.app'
ATTRIBUTE = 'data-search-port-fixture'
TOTAL_TIMEOUT = 504
# Reserve time for delayed OS crash reports (20s), other diagnostics, and the
# existing isolated lifecycle cleanup. The normal suite takes about 5 minutes.
WORK_TIMEOUT = TOTAL_TIMEOUT - 74
MAX_REPORT_BYTES = 8 * 1024 * 1024


class Failure(Exception):
    pass


class Deadline(Exception):
    pass


def expired(signum, frame):
    # A helper may catch Exception internally; keep the bound alive until the
    # outer lifecycle handler takes over and installs its cleanup deadline.
    signal.alarm(1)
    raise Deadline('live fixture exceeded its bounded deadline')


def command_output(*command):
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=5)
        return result.stdout.strip() or result.stderr.strip()
    except (OSError, subprocess.TimeoutExpired) as error:
        return str(error)


def environment():
    webkit = Path('/System/Library/Frameworks/WebKit.framework/Resources/Info.plist')
    return {
        'macOS': platform.mac_ver()[0], 'machine': platform.machine(),
        'osBuild': command_output('sw_vers', '-buildVersion'),
        'WebKit': command_output('/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleVersion', str(webkit)),
        'commit': command_output('git', '-C', str(ROOT), 'rev-parse', 'HEAD'),
        'workingTree': command_output('git', '-C', str(ROOT), 'status', '--short'),
        'app': str(APP),
        'appVersion': command_output('/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleShortVersionString', str(APP / 'Contents/Info.plist')),
    }


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--admission-only', action='store_true',
                        help='install the fixture and verify its initial real ports, then clean up')
    parser.add_argument('--self-test', action='store_true',
                        help='run pure-Python diagnostic selection checks; no app or macOS required')
    return parser.parse_args(argv)


def parse_report(text):
    """Apple .ips is usually one metadata JSON object plus a report object."""
    decoder = json.JSONDecoder()
    documents = []
    remaining = text.lstrip()
    while remaining:
        try:
            document, end = decoder.raw_decode(remaining)
        except ValueError:
            break
        if isinstance(document, dict):
            documents.append(document)
        remaining = remaining[end:].lstrip()
    return next((item for item in reversed(documents) if 'pid' in item), None)


def owned_report(text, *, pids, launched_at, modified_at, app):
    """Never select by filename alone: both launch time and owned PID match."""
    if modified_at < launched_at or not pids:
        return None
    report = parse_report(text)
    if report is not None:
        pid, name, path = report.get('pid'), report.get('procName'), report.get('procPath')
    else:
        process = re.search(r'^Process:\s+Search\s+\[(\d+)\]', text, re.MULTILINE)
        path_match = re.search(r'^Path:\s+(.+)$', text, re.MULTILINE)
        if not process or not path_match:
            return None
        pid, name, path = process.group(1), 'Search', path_match.group(1).strip()
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return None
    if pid not in pids or name != 'Search':
        return None
    # Some .ips versions omit procPath; PID + process name + launch time still
    # identify our captured process. A supplied path must match our app exactly.
    if path and Path(path).resolve() != (Path(app) / 'Contents/MacOS/Search').resolve():
        # macOS may redact home-directory components even in local reports.
        # Keep PID + timestamp + process-name scoping when that exact app
        # suffix is intact; never accept a different explicit executable.
        redacted = ('*' in path or '/USER/' in path) and path.endswith('/Search.app/Contents/MacOS/Search')
        if not redacted:
            return None
    return report if report is not None else {'pid': pid, 'procName': name, 'legacy': text[:24000]}


def summarize_report(report):
    if 'legacy' in report:
        return report
    result = {key: report[key] for key in (
        'pid', 'procName', 'procPath', 'captureTime', 'procLaunch', 'osVersion',
        'exception', 'termination', 'asi', 'asiSignatures', 'lastExceptionBacktrace',
        'faultingThread', 'vmSummary') if key in report}
    threads = report.get('threads') or []
    index = report.get('faultingThread')
    if not isinstance(index, int) or not 0 <= index < len(threads):
        index = next((i for i, thread in enumerate(threads) if thread.get('triggered')), None)
    frames = []
    if index is not None:
        thread = threads[index]
        frames = thread.get('frames', [])[:48]
        result['faultingThreadDetails'] = {key: thread[key] for key in ('name', 'queue', 'triggered', 'threadState') if key in thread}
        result['faultingThreadDetails']['frames'] = frames
    images = report.get('usedImages') or []
    wanted = {frame.get('imageIndex') for frame in frames}
    result['relevantImages'] = [dict(imageIndex=i, **image) for i, image in enumerate(images)
                                if i in wanted or image.get('name') == 'Search']
    return result


def search_addresses(report):
    """Only the owned process's Search executable, never framework frames."""
    summary = summarize_report(report)
    frames = summary.get('faultingThreadDetails', {}).get('frames', [])
    for index, image in enumerate(report.get('usedImages') or []):
        if image.get('name') != 'Search' or not image.get('path', '').endswith('/Search.app/Contents/MacOS/Search'):
            continue
        base = image.get('base')
        try:
            base = int(base, 0) if isinstance(base, str) else int(base)
            addresses = []
            for frame in frames:
                if frame.get('imageIndex') != index:
                    continue
                offset = frame.get('imageOffset')
                offset = int(offset, 0) if isinstance(offset, str) else int(offset)
                addresses.append(base + offset)
                if len(addresses) == 16:
                    break
        except (TypeError, ValueError):
            continue
        if addresses:
            return image, base, addresses
    return None


def symbolicate_report(report, app):
    selected = search_addresses(report)
    if selected is None:
        print('SEARCH_SYMBOLICATION unavailable: no owned Search frames with image offsets', flush=True)
        return
    image, base, addresses = selected
    build = Path(app).parent
    relative = Path('Search.app.dSYM/Contents/Resources/DWARF/Search')
    candidates = [build / relative, build / 'intel' / relative]
    if platform.machine() == 'x86_64':
        candidates.reverse()
    dwarf = next((path for path in candidates if path.is_file()), None)
    if dwarf is None:
        print('SEARCH_SYMBOLICATION unavailable: release Search dSYM missing', flush=True)
        return
    command = ['/usr/bin/atos', '-arch', platform.machine(), '-o', str(dwarf), '-l', hex(base)]
    command.extend(hex(address) for address in addresses)
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=5)
        print('SEARCH_SYMBOLICATION', json.dumps({'dSYM': str(dwarf), 'imageUUID': image.get('uuid'),
              'base': hex(base), 'addresses': [hex(address) for address in addresses],
              'exit': result.returncode, 'symbols': result.stdout[:24000], 'stderr': result.stderr[:3000]}, sort_keys=True), flush=True)
    except (OSError, subprocess.TimeoutExpired) as error:
        print('SEARCH_SYMBOLICATION unavailable:', str(error), flush=True)


def capture_os_reports(*, pids, launched_at, app, wait=20):
    if not pids or launched_at is None:
        print('OS_CRASH_REPORT unavailable: no saved owned process identity', flush=True)
        return
    directories = [Path.home() / 'Library/Logs/DiagnosticReports', Path('/Library/Logs/DiagnosticReports')]
    until = time.monotonic() + min(20, max(0, wait))
    while True:
        candidates = []
        for directory in directories:
            for pattern in ('Search*.ips', 'Search*.crash'):
                try:
                    for path in directory.glob(pattern):
                        stat = path.stat()
                        if stat.st_mtime >= launched_at:
                            candidates.append((stat.st_mtime, path))
                except OSError:
                    pass
        found = []
        for modified_at, path in sorted(candidates, reverse=True)[:30]:
            try:
                with path.open('rb') as stream:
                    raw = stream.read(MAX_REPORT_BYTES + 1)
                if len(raw) > MAX_REPORT_BYTES:
                    continue
                report = owned_report(raw.decode('utf-8', errors='replace'), pids=pids,
                                      launched_at=launched_at, modified_at=modified_at, app=app)
            except OSError:
                continue
            if report is not None:
                found.append((path, report))
        if found:
            for path, report in found[:3]:
                print('OS_CRASH_REPORT', str(path), json.dumps(summarize_report(report), sort_keys=True)[:48000], flush=True)
            # At most one five-second atos call, keeping diagnostics bounded.
            symbolicate_report(found[0][1], app)
            return
        if time.monotonic() >= until:
            print('OS_CRASH_REPORT absent for saved owned PIDs', sorted(pids),
                  'since launch', launched_at, 'after bounded wait', flush=True)
            return
        time.sleep(min(1, max(0, until - time.monotonic())))


def self_test():
    app = Path('/tmp/search-live-self-test/Search.app')
    report = {'pid': 123, 'procName': 'Search', 'procPath': str(app / 'Contents/MacOS/Search'),
              'exception': {'type': 'EXC_BAD_ACCESS'}, 'faultingThread': 0,
              'threads': [{'triggered': True, 'frames': [{'imageIndex': 0, 'symbol': 'testFrame'}]}],
              'usedImages': [{'name': 'Search', 'path': str(app / 'Contents/MacOS/Search')}]}
    text = json.dumps({'app_name': 'Search'}) + '\n' + json.dumps(report)
    arguments = dict(pids={123}, launched_at=100.0, modified_at=101.0, app=app)
    assert owned_report(text, **arguments) == report
    assert owned_report(text, **dict(arguments, pids={456})) is None
    assert owned_report(text, **dict(arguments, pids=set())) is None
    assert owned_report(text, **dict(arguments, modified_at=99.9)) is None
    assert owned_report(text, **dict(arguments, app=Path('/tmp/other/Search.app'))) is None
    assert owned_report(json.dumps(dict(report, procName='Other')), **arguments) is None
    redacted = dict(report, procPath='/Users/USER/*/Search.app/Contents/MacOS/Search')
    assert owned_report(json.dumps(redacted), **arguments) == redacted
    legacy = f'Process: Search [123]\nPath: {app}/Contents/MacOS/Search\nException Type: EXC_CRASH'
    assert owned_report(legacy, **arguments)['pid'] == 123
    assert owned_report('not a report', **arguments) is None
    summary = summarize_report(report)
    assert summary['faultingThreadDetails']['frames'][0]['symbol'] == 'testFrame'
    assert summary['relevantImages'][0]['imageIndex'] == 0
    symbol_report = dict(report, usedImages=[dict(report['usedImages'][0], base=4096)],
                         threads=[{'frames': [{'imageIndex': 0, 'imageOffset': 32}]}])
    assert search_addresses(symbol_report)[1:] == (4096, [4128])
    symbol_report['threads'][0]['frames'] *= 20
    assert len(search_addresses(symbol_report)[2]) == 16
    symbol_report['usedImages'][0]['name'] = 'WebKit'
    assert search_addresses(symbol_report) is None
    assert parse_args(['--admission-only']).admission_only
    assert not parse_args([]).admission_only
    assert parse_args(['--self-test']).self_test
    print('PASS 17 pure-Python diagnostic selection, symbolication, summary and argument checks', flush=True)
    return 0


class Site(BaseHTTPRequestHandler):
    def do_GET(self):
        # Serve only this fixture, never the checkout or arbitrary disk paths.
        if self.path.split('?', 1)[0] != '/site.html':
            self.send_error(404)
            return
        body = (HERE / 'site.html').read_bytes()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class Live:
    def __init__(self, sv):
        self.sv = sv
        self.passed = self.failed = self.skipped = 0
        self.tabs = {}
        self.instances = {}
        self.extension = None
        self.serial = 0
        self.last = {}
        self.owned_pids = set()
        self.launched_at = None

    def check(self, name, condition, detail=None, fatal=False):
        if condition:
            self.passed += 1
            print('PASS', name, flush=True)
        else:
            self.failed += 1
            print('FAIL', name, json.dumps(detail, sort_keys=True), flush=True)
            if fatal:
                raise Failure(name)
        return bool(condition)

    def skip(self, name, reason):
        self.skipped += 1
        print('NOT COVERED', name + ':', reason, flush=True)

    def poll(self, name, read, predicate, timeout=15):
        until = time.monotonic() + timeout
        last = None
        last_error = None
        while time.monotonic() < until:
            try:
                last = read()
                if predicate(last):
                    return last
            except (RuntimeError, OSError, ValueError) as error:
                last_error = str(error)
            time.sleep(0.15)
        raise Failure(f'{name}: timed out after {timeout}s; last={last!r}; error={last_error!r}')

    def eval(self, label, javascript):
        return self.sv.ev(self.tabs[label], javascript)

    def state(self, label):
        value = self.eval(label, f'document.documentElement.getAttribute({json.dumps(ATTRIBUTE)})')
        state = json.loads(value) if value else None
        if state:
            self.last[label] = state
        return state

    def states(self):
        return {label: self.state(label) for label in self.tabs}

    def snapshot(self, label):
        print('SNAPSHOT', label, json.dumps(self.states(), sort_keys=True), flush=True)

    def click(self, label, button):
        self.serial += 1
        token = f'{label}-{button}-{self.serial}'
        javascript = ('(() => { const button = document.getElementById(' + json.dumps(button) + '); '
                      'if (!button) throw new Error("fixture button missing"); '
                      'button.dataset.token = ' + json.dumps(token) + '; button.click(); return true; })()')
        if self.eval(label, javascript) is not True:
            raise Failure(f'{label}: could not click {button}')
        return token

    def extension_state(self):
        status = self.sv.cmd({'do': 'extensions'})
        if 'extensions' not in status:
            raise Failure('extensions command returned no result; the app may have stopped: ' + repr(status))
        if self.extension:
            return next((item for item in status['extensions'] if item['id'] == self.extension), None)
        return status

    def restart_notes(self):
        return [message for message in self.extension_state().get('reported', [])
                if 'restarted the extension:' in message]

    def native(self, action, expected=None, timeout=30):
        token = self.click('requester', action)
        record = self.poll('background.' + action, lambda: next(
            (item for item in self.state('requester')['native'] if item['token'] == token), None),
            lambda item: item and item['status'] != 'pending', timeout)
        self.check('background.' + action + ' completed', record['status'] == 'fulfilled', record, fatal=True)
        if expected is not None:
            self.check('background.' + action + ' returned ' + str(expected).lower(),
                       record.get('value') is expected, record, fatal=True)
        print('NATIVE', json.dumps(record, sort_keys=True), flush=True)
        return record

    @staticmethod
    def echo(state, token):
        return next((message for port in state['ports'] for message in port['messages']
                     if message.get('echo', {}).get('token') == token), None)

    @staticmethod
    def control(state, token, control):
        return next((message for port in state['ports'] for message in port['messages']
                     if message.get('token') == token and message.get('control') == control), None)

    def send_echo(self, label, fresh=False):
        button = ('connect-content' if fresh else 'send-content') if label == 'content' else ('connect' if fresh else 'send')
        token = self.click(label, button)
        state = self.poll(label + ' echo', lambda: self.state(label), lambda value: value and self.echo(value, token))
        self.check(f'{label}: {"explicit fresh connection" if fresh else "existing connection"} echoes',
                   self.echo(state, token) is not None, state)
        return self.echo(state, token)['worker']

    def assert_ports(self, name, generations, retired, states=None):
        states = states or self.states()
        for label, state in states.items():
            expected = [1 if index < retired else 0 for index in range(generations)]
            actual = [port['disconnected'] for port in state['ports']]
            self.check(f'{name}: {label} exact per-port disconnect counts {expected}',
                       state['opened'] == generations and actual == expected and state['disconnected'] == retired,
                       state)
            self.check(f'{name}: {label} original document retained', state['instance'] == self.instances[label], state)
            self.check(f'{name}: {label} no fixture errors', not state['errors'], state['errors'])

    def stable_for(self, seconds, generations, retired, name, keepalive=False):
        # Check every snapshot, not merely the final one: counters cannot hide
        # a transient false disconnect. Keep-alive traffic is application echo
        # traffic, not a recovery request or a shim bypass.
        until = time.monotonic() + max(0, seconds)
        heartbeat = time.monotonic() + 10
        while time.monotonic() < until:
            states = self.states()
            expected = [1 if index < retired else 0 for index in range(generations)]
            for label, state in states.items():
                if (state['instance'] != self.instances[label] or state['opened'] != generations
                        or [port['disconnected'] for port in state['ports']] != expected or state['errors']):
                    self.check(f'{name}: {label} remained stable', False, state, fatal=True)
            if keepalive and time.monotonic() >= heartbeat:
                for label in self.tabs:
                    self.send_echo(label)
                heartbeat = time.monotonic() + 10
            time.sleep(min(0.4, max(0, until - time.monotonic())))
        self.assert_ports(name, generations, retired)

    def setup_pages(self, base):
        self.sv.cmd({'do': 'ext-folder', 'path': str(HERE / 'extension'), 'yes': True})
        status = self.poll('local fixture installation', self.extension_state,
                           lambda data: any(item['name'] == 'Search Worker Recovery Fixture' and item['loaded']
                                            for item in data['extensions']), timeout=30)
        installed = [item for item in status['extensions'] if item['name'] == 'Search Worker Recovery Fixture']
        self.check('only the local fixture is installed in isolated profile', len(status['extensions']) == 1 and len(installed) == 1,
                   status, fatal=True)
        self.extension = installed[0]['id']
        self.tabs['content'] = self.sv.cmd({'do': 'open', 'url': base + '/site.html'})['id']
        for label in ['page', 'requester']:
            self.tabs[label] = self.sv.cmd({'do': 'ext-page', 'id': self.extension, 'path': 'page.html'})['id']
        workers = []
        for label in self.tabs:
            state = self.poll(label + ' initial real port echo', lambda: self.state(label),
                              lambda data: data and data['opened'] == 1 and bool(data['ports'][0]['messages']), timeout=20)
            self.instances[label] = state['instance']
            self.check(label + ': initial real WebKit port echoes',
                       any('echo' in message for message in state['ports'][0]['messages']), state, fatal=True)
            workers.append(state['ports'][0]['messages'][0].get('worker'))
        self.check('site and both extension pages share one worker', len(set(workers)) == 1 and bool(workers[0]), workers, fatal=True)
        self.check('website main world has no recovery handler', self.eval('content',
                   "typeof window.webkit?.messageHandlers?.searchWorkerRecovery === 'undefined'") is True)
        print('USER_AGENT', self.eval('content', 'navigator.userAgent'), flush=True)
        self.assert_ports('initial', 1, 0)
        return workers[0]

    def healthy_wake(self):
        before = self.restart_notes()
        self.native('wake')
        self.stable_for(2, 1, 0, 'healthy wake does not disconnect')
        for label in self.tabs:
            self.send_echo(label)
        after = self.restart_notes()
        self.check('healthy wake did not record a native restart', after == before, after)

    def brief_busy(self):
        # Ensure the requester's next runtime message is eligible for Search's
        # five-second worker check, then queue that message DURING a real stall.
        self.stable_for(5.3, 1, 0, 'idle before brief busy worker')
        before = self.restart_notes()
        token = self.click('page', 'busy')
        state = self.poll('worker armed bounded stall', lambda: self.state('page'),
                          lambda value: value and self.control(value, token, 'busy-armed'))
        armed = self.control(state, token, 'busy-armed')
        time.sleep(max(0, (armed['scheduledAt'] + 200 - time.time() * 1000) / 1000))
        request = self.click('requester', 'roundtrip')
        state = self.poll('runtime reply after bounded real worker stall', lambda: self.state('requester'),
                          lambda value: any(item['token'] == request and item['status'] != 'pending'
                                            for item in value['roundtrips']), timeout=12)
        roundtrip = next(item for item in state['roundtrips'] if item['token'] == request)
        state = self.poll('worker completed bounded stall', lambda: self.state('page'),
                          lambda value: self.control(value, token, 'busy-done'), timeout=8)
        done = self.control(state, token, 'busy-done')
        self.check('brief busy worker delivered runtime echo', roundtrip['status'] == 'fulfilled'
                   and (roundtrip.get('value') or {}).get('echo', {}).get('token') == request, roundtrip)
        # Scheduling contention can make eval arrive after the worker finishes.
        # Report this as uncovered rather than claiming the ping was delayed.
        overlap = done['startedAt'] <= roundtrip['startedAt'] < done['finishedAt']
        latency = roundtrip['finishedAt'] - roundtrip['startedAt']
        if overlap and latency >= 250:
            self.check('real worker event-loop stall delayed a page message', True)
        else:
            self.skip('overlapping worker stall', f'eval did not establish a delayed request: roundtrip={roundtrip}, busy={done}')
        print('BUSY', json.dumps({'armed': armed, 'done': done, 'roundtrip': roundtrip, 'latencyMs': latency}, sort_keys=True), flush=True)
        # Longer than the ping's 15-second deadline plus retry spacing, so a
        # stale timeout cannot falsely pass just because we immediately revive.
        self.stable_for(18, 1, 0, 'brief busy worker does not disconnect')
        self.check('brief busy worker did not record native recovery',
                   self.restart_notes() == before, self.extension_state())

    def recover(self, generation, previous_worker):
        token = self.click('page', 'withhold')
        state = self.poll('withholding acknowledged', lambda: self.state('page'),
                          lambda value: self.control(value, token, 'withhold'))
        self.check(f'recovery {generation}: application withholding acknowledged',
                   self.control(state, token, 'withhold')['answering'] is False)
        withheld = {}
        for label in self.tabs:
            withheld[label] = self.click(label, 'send-content' if label == 'content' else 'send')
        self.stable_for(1.5, generation, generation - 1, f'recovery {generation}: application silence alone')
        for label, token in withheld.items():
            self.check(f'recovery {generation}: {label} application reply withheld', not self.echo(self.state(label), token))
        self.snapshot(f'before-revive-{generation}')
        before = self.restart_notes()
        requested_at = time.monotonic()
        self.native('revive', expected=True)
        self.poll('extension reloaded', self.extension_state, lambda item: item and item['loaded'], timeout=20)
        # Failure is recorded for every context, even if one context never
        # receives the notification; fresh connections are still attempted.
        for label in self.tabs:
            try:
                self.poll(label + ' old port disconnect', lambda: self.state(label),
                          lambda state: state['ports'][-1]['disconnected'] >= 1, timeout=12)
            except Failure as error:
                self.check(f'recovery {generation}: {label} received disconnect', False, str(error))
        self.assert_ports(f'recovery {generation}: old ports retired once', generation, generation)
        reported = self.restart_notes()
        self.check(f'recovery {generation}: native restart diagnostic recorded',
                   len(reported) > len(before) and any('restarted the extension:' in item for item in reported), reported)
        self.native('wake')
        workers = [self.send_echo(label, fresh=True) for label in self.tabs]
        self.check(f'recovery {generation}: fresh ports reach a new shared worker',
                   len(set(workers)) == 1 and workers[0] != previous_worker, workers)
        self.stable_for(2, generation + 1, generation, f'recovery {generation}: fresh ports stay open')
        for label, token in withheld.items():
            self.check(f'recovery {generation}: {label} withheld messages were not replayed', not self.echo(self.state(label), token))
        self.snapshot(f'after-revive-{generation}')
        return workers[0], requested_at

    def idle_wake(self, previous_worker):
        # WebKit can discard an idle background without unloading its extension
        # context. Leave ports completely silent beyond the 120s inactivity
        # threshold and a 30s timer interval. DOM-only observations do not send
        # worker messages. Whether this WebKit actually idled it is verified
        # from the fixture's per-start nonce, never inferred from elapsed time.
        before = self.restart_notes()
        print('WAIT idle worker: 160s without port/runtime traffic', flush=True)
        self.snapshot('before-idle-worker')
        until = time.monotonic() + 160
        while time.monotonic() < until:
            for label, state in self.states().items():
                counts = [port['disconnected'] for port in state['ports']]
                valid = (state['instance'] == self.instances[label] and state['opened'] == 3
                         and counts[:2] == [1, 1] and counts[2:] in ([0], [1]) and not state['errors'])
                if not valid:
                    self.check('idle worker: ' + label + ' has no duplicate event or new connection', False, state, fatal=True)
            time.sleep(min(2, max(0, until - time.monotonic())))
        self.snapshot('after-idle-before-wake')
        self.native('wake')
        token = self.click('requester', 'roundtrip')
        state = self.poll('worker identity after idle wake', lambda: self.state('requester'),
                          lambda value: any(item['token'] == token and item['status'] != 'pending'
                                            for item in value['roundtrips']), timeout=20)
        result = next(item for item in state['roundtrips'] if item['token'] == token)
        value = result.get('value') or {}
        self.check('idle wake: runtime reply identifies real worker',
                   result['status'] == 'fulfilled' and value.get('echo', {}).get('token') == token
                   and bool(value.get('worker')), result, fatal=True)
        reported = self.restart_notes()
        self.check('idle wake: no controller-reload recovery was recorded', reported == before, reported)
        if value['worker'] == previous_worker:
            self.skip('same-context idle worker replacement',
                      'WebKit retained the same worker for the 160-second silent window; wake did not replace it')
            self.assert_ports('idle window kept the same worker', 3, 2)
            return
        self.check('idle wake: a new worker started in the existing extension context', reported == before,
                   {'previousWorker': previous_worker, 'newWorker': value['worker'], 'reported': reported})
        for label in self.tabs:
            try:
                self.poll('idle wake: ' + label + ' old port disconnect', lambda: self.state(label),
                          lambda current: current['ports'][-1]['disconnected'] >= 1, timeout=12)
            except Failure as error:
                self.check('idle wake: ' + label + ' received disconnect', False, str(error))
        self.assert_ports('idle wake: old ports retired exactly once', 3, 3)
        workers = [self.send_echo(label, fresh=True) for label in self.tabs]
        self.check('idle wake: explicit fresh connections reach the newly started worker',
                   all(worker == value['worker'] for worker in workers), workers)
        self.stable_for(3, 4, 3, 'idle wake: fresh ports stay open')
        self.snapshot('after-idle-wake')

    def run(self, base):
        worker = self.setup_pages(base)
        self.healthy_wake()
        self.brief_busy()
        worker, recovered_at = self.recover(1, worker)
        self.check('cooldown test is inside native 60-second window', time.monotonic() - recovered_at < 55,
                   time.monotonic() - recovered_at, fatal=True)
        before = self.restart_notes()
        self.native('revive', expected=False)
        self.stable_for(3, 2, 1, 'cooldown refusal does not disconnect fresh ports')
        self.check('cooldown refusal did not record another restart', self.restart_notes() == before)
        for label in self.tabs:
            self.send_echo(label)
        # Exercise another real native generation after the actual cooldown.
        # Never alter app settings or production cooldowns to accelerate it.
        remaining = recovered_at + 61.5 - time.monotonic()
        print(f'WAIT native revive cooldown: {max(0, remaining):.1f}s with live echo keep-alives', flush=True)
        self.stable_for(remaining, 2, 1, 'waiting through native cooldown', keepalive=True)
        worker, _ = self.recover(2, worker)
        self.assert_ports('two retired generations and a live fresh port', 3, 2)
        self.idle_wake(worker)
        self.skip('dead-worker detection and failed-start wake recovery',
                  'application withholding leaves the shim ping healthy; no native startup fault was injected')
        self.skip('delayed worker startup and cross-origin frame coverage',
                  'the bounded event-loop stall covers an already-running worker; this runner uses top-level fixture documents')

    def diagnostics(self):
        # Capture the app's own exception report before isolated cleanup erases
        # it. A broken bench connection must not hide the original native fault.
        crash = Path(self.sv.SUPPORT) / 'crash.log'
        if crash.is_file():
            print('NATIVE_CRASH_REPORT', crash.read_text(errors='replace')[-20000:], flush=True)
        else:
            print('NATIVE_CRASH_REPORT absent in isolated profile', flush=True)
        alive = self.sv.pids()
        print('OWNED_PROBE_PIDS', alive, 'SAVED_OWNED_PIDS', sorted(self.owned_pids), flush=True)
        if self.failed or not alive:
            capture_os_reports(pids=self.owned_pids, launched_at=self.launched_at, app=APP, wait=20)
        for label in self.tabs:
            try:
                print('FINAL_STATE', label, json.dumps(self.state(label), sort_keys=True), flush=True)
            except Deadline:
                raise
            except Exception as error:
                print('FINAL_STATE_UNAVAILABLE', label, str(error), 'LAST', json.dumps(self.last.get(label)), flush=True)
        print('EXTENSIONS', json.dumps(self.extension_state(), sort_keys=True), flush=True)


def main(argv=None):
    options = parse_args(argv)
    if options.self_test:
        return self_test()
    if sys.platform != 'darwin':
        print('NOT RUN: live WebKit fixture requires macOS 15.4 or newer.', flush=True)
        return 2
    if tuple(int(part) for part in platform.mac_ver()[0].split('.')[:2]) < (15, 4):
        print('NOT RUN: WKWebExtension requires macOS 15.4 or newer.', flush=True)
        return 2
    if not (APP / 'Contents/MacOS/Search').is_file():
        print(f'NOT RUN: built app missing at {APP}; build first (copy build/intel/Search.app here on Intel).', flush=True)
        return 2
    signal.signal(signal.SIGALRM, expired)
    signal.alarm(WORK_TIMEOUT)
    print('ENVIRONMENT', json.dumps(environment(), sort_keys=True), flush=True)
    sys.path.insert(0, str(ROOT / 'Tests'))
    import split_view as sv
    sv.use('extension-worker-recovery')
    # split_view starts its own unrelated HTTP server on import. The suite
    # serves only its fixture and shuts both servers down when it is done.
    sv.srv.shutdown()
    sv.srv.server_close()
    server = ThreadingHTTPServer(('127.0.0.1', 0), Site)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    live = Live(sv)
    try:
        sv.setup()
        live.launched_at = time.time()
        sv.launch()
        live.owned_pids = {int(pid) for pid in sv.started}
        print('PROBE_LAUNCH', json.dumps({'at': live.launched_at, 'pids': sorted(live.owned_pids)}), flush=True)
        live.check('isolated hidden Search bench is available', Path(sv.SOCK).exists(), sv.SOCK, fatal=True)
        base = f'http://127.0.0.1:{server.server_port}'
        if options.admission_only:
            live.setup_pages(base)
            print('ADMISSION_ONLY: initial real ports verified; recovery cases were not run', flush=True)
        else:
            live.run(base)
    except (Exception, KeyboardInterrupt) as error:
        live.check('live fixture completed', False, str(error))
        traceback.print_exc()
    finally:
        # Failure diagnostics and teardown are also bounded. finish() can only
        # stop/wipe this checkout's named probe, never the user's main profile.
        signal.alarm(30)
        try:
            live.diagnostics()
        except Exception as error:
            print('DIAGNOSTICS_UNAVAILABLE', str(error), flush=True)
        signal.alarm(25)
        try:
            sv.finish()
            live.check('isolated probe cleaned up', not Path(sv.SUPPORT).exists() and not sv.pids())
        except Exception as error:
            live.check('isolated probe cleaned up', False, str(error))
        signal.alarm(5)
        try:
            server.shutdown()
            server.server_close()
        except Exception as error:
            live.check('fixture HTTP server stopped', False, str(error))
        signal.alarm(0)
    print(f'LIVE RESULT: {live.passed} passed, {live.failed} failed, {live.skipped} not covered', flush=True)
    return 1 if live.failed else 0


if __name__ == '__main__':
    sys.exit(main())
