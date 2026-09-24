#!/usr/bin/env python3
"""Increasing blur must preserve solid page colors at fixed transparency."""
import argparse
import json
from pathlib import Path
import runpy
import subprocess
import threading
import time
import uuid
from http.server import ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]
HELPERS = runpy.run_path(str(ROOT / 'tests/chrome_support.py'))
server = ThreadingHTTPServer(('127.0.0.1', 0), HELPERS['PageHandler'])
threading.Thread(target=server.serve_forever, daemon=True).start()
run = HELPERS['Run'](argparse.Namespace(binary=str(ROOT / '.build/debug/Search'),
                                      world='alpha-' + uuid.uuid4().hex[:7]),
                     f'http://127.0.0.1:{server.server_port}')


def control(label):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        found = [n for n in run.ask('native', action='nodes')['nodes']
                 if n['role'] == 'AXSlider' and n['label'] == label]
        if found:
            return found[0]
        time.sleep(.1)
    raise AssertionError('slider missing: ' + label)


def blur(value):
    run.ask('ui', settings=True)
    time.sleep(.5)
    run.ask('native', action='press', label='Appearance')
    for _ in range(25):
        node = control('Blur strength')
        current = float(node['value'])
        if abs(current - value) < .001:
            break
        run.ask('native', action='increment' if current < value else 'decrement', index=node['index'])
        time.sleep(.1)
    else:
        raise AssertionError('blur did not update')
    run.check(abs(float(control('Transparency')['value']) - .8) < .001, 'transparency stays at 80%')
    run.ask('ui', settings=False)
    time.sleep(.5)


def capture(name, rects):
    path = run.directory / (name + '.png')
    run.ask('native', action='composited-shot', path=str(path), contrastRects=rects)
    status = Path(str(path) + '.json')
    deadline = time.monotonic() + 10
    while not status.exists() and time.monotonic() < deadline:
        time.sleep(.1)
    result = json.loads(status.read_text())
    if 'error' in result:
        raise AssertionError(result)
    return result['colorMeans']


try:
    run.prepare()
    for key, value in [('chrome.transparency', .8), ('chrome.blur', .1), ('bars.height', 30)]:
        subprocess.run(['defaults', 'write', run.suite, key, '-float', str(value)], check=True)
    run.launch()
    tab = run.open('/blur-opacity')
    run.ask('resize', width=1180, height=780)
    run.js(tab, "document.documentElement.style.background='#2255cc'; document.body.style.background='#2255cc'; document.body.style.minHeight='2000px'; true")
    time.sleep(.5)
    results = {}
    for sidebar in (False, True):
        run.ask('ui', sidebar=sidebar)
        time.sleep(.4)
        rects = [[850, 12, 100, 6]] if not sidebar else [[4, 450, 6, 40], [110, 450, 6, 40]]
        colors = []
        for strength in (.1, .5, 1):
            blur(strength)
            colors.append(capture(f'opacity-{sidebar}-{strength}', rects))
        drift = max(abs(a - b) for sample in colors[1:]
                    for original, current in zip(colors[0], sample)
                    for a, b in zip(original, current))
        results[str(sidebar)] = {'colors': colors, 'maximumChannelDrift': drift}
    run.report['samples'] = results
    for layout, result in results.items():
        run.check(all(c[2] > c[0] + 50 for c in result['colors'][0]),
                  f'page color is visible through the chrome: sidebar={layout}')
        run.check(result['maximumChannelDrift'] < 3,
                  f'10–100% blur preserves rendered opacity: sidebar={layout}')
    run.report['ok'] = True
except BaseException as error:
    run.report.update(ok=False, error=str(error))
    raise
finally:
    run.stop()
    server.shutdown()
    server.server_close()
    report = run.directory / 'blur-opacity.json'
    report.write_text(json.dumps(run.report, indent=2))
    print(f'Report: {report}', flush=True)
