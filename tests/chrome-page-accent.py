#!/usr/bin/env python3
"""Exercise Match page through Settings and real WebKit color metadata."""
import argparse
import json
from pathlib import Path
import runpy
import threading
import time
import uuid
from http.server import ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]
helpers = runpy.run_path(str(ROOT / 'tests/chrome_support.py'))
server = ThreadingHTTPServer(('127.0.0.1', 0), helpers['PageHandler'])
threading.Thread(target=server.serve_forever, daemon=True).start()
run = helpers['Run'](argparse.Namespace(binary=str(ROOT / '.build/debug/Search'),
                                      world='accent-' + uuid.uuid4().hex[:7]),
                     f'http://127.0.0.1:{server.server_port}')


def expect(rgb, message):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        state = run.ask('native', action='accent')
        if all(abs(a - b) < .015 for a, b in zip(state['rgb'], rgb)):
            run.check(True, message)
            return
        time.sleep(.1)
    raise AssertionError(f'{message}: {state}')


try:
    run.prepare()
    run.launch()
    first = run.open('/page-accent')
    run.ask('ui', settings=True)
    time.sleep(.4)
    run.ask('native', action='press', label='Appearance')
    time.sleep(.4)
    run.check(run.ask('native', action='press', label='Accent: Match page')['pressed'],
              'Match page can be selected in Appearance')
    run.ask('ui', settings=False)
    run.js(first, "document.head.insertAdjacentHTML('beforeend', '<meta name=theme-color content=\"#2255cc\">'); true")
    expect([34/255, 85/255, 204/255], 'accent follows the page theme color')
    run.js(first, "document.querySelector('meta[name=theme-color]').content='#cc5522'; true")
    expect([204/255, 85/255, 34/255], 'accent follows live theme-color updates')
    second = run.open('/page-background')
    run.js(second, "document.documentElement.style.background='#22aa66'; document.body.style.background='#22aa66'; true")
    expect([34/255, 170/255, 102/255], 'without metadata the accent follows the page background')
    run.ask('select', id=first)
    expect([204/255, 85/255, 34/255], 'switching tabs restores that page accent')
    run.ask('ui', sidebar=True)
    expect([204/255, 85/255, 34/255], 'sidebar uses the same matching accent')
    run.ask('ui', settings=True)
    time.sleep(.4)
    run.ask('native', action='press', label='Accent: Purple')
    run.check(run.ask('native', action='accent')['mode'] == 'purple', 'fixed accents remain available')
    run.ask('native', action='press', label='Accent: Match page')
    run.ask('ui', settings=False)
    run.organize('save')
    run.stop()
    run.launch()
    first = run.restored('/page-accent')
    run.page(first, '/page-accent')
    run.check(run.ask('native', action='accent')['mode'] == 'page', 'Match page persists after restart')
    run.js(first, "document.head.insertAdjacentHTML('beforeend', '<meta name=theme-color content=\"#2255cc\">'); true")
    expect([34/255, 85/255, 204/255], 'page colors are observed again after restart')
    run.report['ok'] = True
finally:
    run.stop()
    server.shutdown()
    server.server_close()
    report = run.directory / 'page-accent.json'
    report.write_text(json.dumps(run.report, indent=2))
    print(f'Report: {report}', flush=True)
