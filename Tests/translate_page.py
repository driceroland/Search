#!/usr/bin/env python3
"""Translate Page, page side, in a hidden probe with the stand-in translator.

Build first (`./build.sh`), then `python3 Tests/translate_page.py`. The app
starts hidden in a world of its own (bld-tr-<checkout>, see split_view.use)
with SEARCH_TRANSLATE_FAKE=1: each string comes back as "[fr→en] string"
instead of being translated, so no language has to be downloaded and the
framework is never called. Everything else is the real path: the script
in Search's world, the slices, the marks between a sentence's parts, the
cache, per-block languages, frames, the observer, Show Original, the tab's
mark and Always Translate. Driven through ./bench's socket; local pages
only; nothing shows a window or a popover. The world is removed after.

Pages on http://127.0.0.1:PORT are "the site"; a frame on
http://localhost:PORT is another site's.
"""
import json
import os
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bld-tr")
PORT = sv.srv.server_port
SITE = f"http://127.0.0.1:{PORT}"
OTHER = f"http://localhost:{PORT}"
TAG = "[fr→en] "

FR = "Bonjour à tous, voici une longue phrase en français pour que la page soit bien reconnue."
EN = "This whole paragraph is written in plain English, and it should be left exactly as it is by the translator."
DE = "Dieser ganze Absatz ist auf Deutsch geschrieben und sollte aus dem Deutschen übersetzt werden, bitte sehr."

# A frame answers its parent with its own words, so the page can say what
# a frame of another site shows.
TELL = """<script>addEventListener('message', function (e) {
  if (e.data === 'tell') e.source.postMessage({ said: document.body.innerText, from: location.host }, '*');
});</script>"""

PAGES = {
    "/skip": f"""<html lang="fr"><title>Bonjour le monde</title>
<p id="p1">{FR}</p>
<pre id="pre">Ceci est du code préformaté</pre>
<p id="p2">Utilisez la commande <code>ls</code> pour lister les fichiers.</p>
<input id="in" value="valeur du champ" placeholder="Votre nom ici">
<textarea id="ta">texte de la zone</textarea>
<div contenteditable id="ce">texte modifiable</div>
<p translate="no" id="tn">ne pas traduire</p>
<p class="notranslate" id="nt">pas de traduction</p>
<p id="p3">Visitez <a href="#x">le musée du Louvre</a> aujourd'hui.</p>
<img id="img" alt="Une photo du musée" src="data:image/gif;base64,R0lGODlhAQABAAAAACw=">
<button id="btn" title="Envoyer le formulaire" aria-label="Envoyer maintenant">Envoyer</button>
<ul id="menu"><li>Accueil</li><li>Accueil</li><li>Accueil</li><li>Accueil</li></ul>
<p id="num">2026 · 42</p>
<shadow-host id="host"></shadow-host>
<script>
  var root = document.getElementById('host').attachShadow({{ mode: 'open' }});
  root.innerHTML = '<p id="deep">Texte caché dans une racine fantôme</p>';
</script>""",
    "/frames": f"""<html lang="fr"><title>Cadres</title>
<p id="p1">{FR}</p>
<iframe id="same" src="{SITE}/frame-fr?same"></iframe>
<iframe id="other" src="{OTHER}/frame-fr?other"></iframe>
<script>
  window.__said = {{}};
  addEventListener('message', function (e) {{ if (e.data && e.data.said) window.__said[e.data.from] = e.data.said; }});
  function ask() {{ window.__said = {{}}; for (const f of document.querySelectorAll('iframe')) f.contentWindow.postMessage('tell', '*'); }}
</script>""",
    "/frame-fr": f"<html lang='fr'><p>Le texte du cadre est en français, comme le reste de cette page.</p>{TELL}",
    "/dynamic": f"""<html lang="fr"><title>Vivante</title>
<p id="p1">{FR}</p><div id="more"></div><p id="live">Première version du texte</p>""",
    "/ticker": f"""<html lang="fr"><title>Défilement</title><p>{FR}</p><div id="feed"></div>
<script>var n = 0; setInterval(function () {{ var p = document.createElement('p');
p.textContent = 'Nouvelle ligne numéro ' + (++n); document.getElementById('feed').appendChild(p); }}, 200);</script>""",
    "/plain": f"""<html lang="fr"><title>Simple</title><p id="p1">{FR}</p><p>Encore une phrase, toujours en français.</p>""",
    "/mixed": f"""<html lang="fr"><title>Mélange</title>
<p id="f1">{FR}</p><p id="f2">La deuxième phrase reste aussi en français, avec quelques mots de plus.</p>
<blockquote id="en">{EN}</blockquote><blockquote id="de">{DE}</blockquote>""",
    "/react": f"""<html lang="fr"><title>Compteur</title>
<div id="app"></div>
<script>
  window.__errors = 0; addEventListener('error', function () {{ window.__errors++; }});
  // A tiny renderer that keeps its own nodes and only ever sets their
  // values, as React does with text it rendered.
  var app = document.getElementById('app');
  var h = document.createElement('h1'), label = document.createTextNode('Clics : 0');
  h.appendChild(label); app.appendChild(h);
  var b = document.createElement('button'); b.id = 'b'; b.textContent = 'Ajouter un clic'; app.appendChild(b);
  var ul = document.createElement('ul'); app.appendChild(ul);
  var items = [];
  function render(n) {{
    label.nodeValue = 'Clics : ' + n;
    while (items.length < n) {{ var li = document.createElement('li'); var t = document.createTextNode(''); li.appendChild(t); ul.appendChild(li); items.push(t); }}
    items.forEach(function (t, i) {{ t.nodeValue = 'Élément numéro ' + (i + 1); }});
  }}
  var count = 0; b.addEventListener('click', function () {{ render(++count); }});
  window.__check = function () {{
    return label.parentNode === h && h.parentNode === app && items.every(function (t) {{ return t.parentNode && t.parentNode.parentNode === ul; }});
  }};
  render(0);
</script>""",
    "/numbers": "<title>1234</title><p>1234 5678</p><p>9 · 10</p>",
    "/secret": f"<html lang='fr'><title>Carnet confidentiel</title><p id='p1'>{FR}</p><p>Le mot Zanzibarique n'apparaît que dans cet onglet privé.</p>",
}


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = PAGES.get(urlparse(self.path).path, f"<p>plain {self.path}</p>")
        data = ("<!doctype html><meta charset=utf-8>" + body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


sv.srv.RequestHandlerClass = H


def launch():
    """sv.launch, with the stand-in translator."""
    if os.path.exists(sv.SOCK):
        os.remove(sv.SOCK)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_TRANSLATE_FAKE=1", sv.APP])
    for _ in range(150):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update((sv.running() - before) & sv.holding())


def visit(path, private=False):
    tab = sv.cmd({"do": "open", "url": f"{SITE}{path}", "private": private})["id"]
    time.sleep(1.5)
    return tab


def tr(tab, *args):
    req = {"do": "translate", "id": tab}
    if args:
        if args[0] in ("original", "state", "toggle", "always", "never"):
            req["action"] = args[0]
        else:
            req["lang"] = args[0]
    if len(args) > 1:
        req["lang"] = args[1]
    return sv.cmd(req)


def ev(tab, js):
    return sv.ev(tab, js)


def text(tab, sel):
    return ev(tab, f"(function(){{ var e = document.querySelector({json.dumps(sel)}); return e ? e.textContent : null; }})()")


def menu(tab):
    """The Translate item the page's right-click menu gets, built as it is
    for the menu but never shown ("" when there's none): a real NSMenu in a
    hidden probe would come up on the screen."""
    return tr(tab, "state")["menu"]


SNAP = """(function(){ var out = [document.title, document.body.innerHTML, document.querySelectorAll('*').length];
var r = document.getElementById('host'); if (r && r.shadowRoot) out.push(r.shadowRoot.innerHTML); return JSON.stringify(out); })()"""


def main():
    t = sv.T()
    try:
        # 1: always there since 24 Oct 2026, an old "off" on disk included:
        # the menu offers it, and nothing is translated until it's chosen.
        sv.setup(**{"translate.pages": False})
        launch()
        page = visit("/plain")
        st = tr(page, "state")
        t.ok("always on, an old off notwithstanding", st["enabled"] is True and st["available"] is True, st)
        items = menu(page)
        t.ok("Translate Page in the page's menu", items == "Translate Page to English", items)
        t.ok("and the page is untouched until it's chosen", text(page, "#p1") == FR)
        sv.quit()
        launch()

        # 2: what is translated and what isn't; marks; attributes; title;
        # repeated strings; shadow DOM; the context menu; exact restore.
        page = visit("/skip")
        before = ev(page, SNAP)
        items = menu(page)
        t.ok("the menu offers Translate Page to English", items == "Translate Page to English", items)
        st = tr(page, "toggle")
        t.ok("the menu item translates the page", st["mark"].get("phase") == "done" and st["mark"].get("from") == "fr", st)
        t.ok("text is translated", (text(page, "#p1") or "").startswith(TAG + "Bonjour"), text(page, "#p1"))
        t.ok("the title too", ev(page, "document.title").startswith(TAG), ev(page, "document.title"))
        t.ok("pre is left alone", text(page, "#pre") == "Ceci est du code préformaté")
        t.ok("a field's value is left alone", ev(page, "document.getElementById('in').value") == "valeur du champ")
        t.ok("a textarea is left alone", ev(page, "document.getElementById('ta').value") == "texte de la zone")
        t.ok("contenteditable is left alone", text(page, "#ce") == "texte modifiable")
        t.ok("translate=no is left alone", text(page, "#tn") == "ne pas traduire")
        t.ok(".notranslate is left alone", text(page, "#nt") == "pas de traduction")
        t.ok("numbers alone are left alone", text(page, "#num") == "2026 · 42")
        p2 = text(page, "#p2")
        t.ok("a sentence with code goes whole, the code kept", p2 == TAG + "Utilisez la commande ls pour lister les fichiers.", p2)
        p3 = text(page, "#p3")
        t.ok("a sentence isn't split at its link", p3 == TAG + "Visitez le musée du Louvre aujourd'hui." and text(page, "#p3 a") == "le musée du Louvre", p3)
        t.ok("placeholder translated", ev(page, "document.getElementById('in').placeholder").startswith(TAG))
        t.ok("alt translated", ev(page, "document.getElementById('img').alt").startswith(TAG))
        t.ok("title attribute translated", ev(page, "document.getElementById('btn').title").startswith(TAG))
        t.ok("aria-label translated", ev(page, "document.getElementById('btn').getAttribute('aria-label')").startswith(TAG))
        t.ok("a shadow root's text translated",
             (ev(page, "document.getElementById('host').shadowRoot.getElementById('deep').textContent") or "").startswith(TAG))
        rep = st["report"]
        t.ok("a repeated string is sent once", rep.get("cached", 0) >= 3 and rep.get("sent", 0) < rep.get("parts", 0), rep)
        t.ok("no element added or removed", json.loads(ev(page, SNAP))[2] == json.loads(before)[2])
        items = menu(page)
        t.ok("the menu then offers Show Original", items == "Show Original", items)
        tr(page, "toggle")
        time.sleep(0.6)
        t.ok("Show Original puts back exactly what was there", ev(page, SNAP) == before)
        st = tr(page, "state")
        t.ok("and the sign goes", st["mark"] == {} and st["running"] is False, st)

        # 3: frames, the page's own and another site's, and one added later.
        page = visit("/frames")
        st = tr(page)
        t.ok("two frames reached", st["report"].get("frames") == 2, st["report"])
        ev(page, "ask()")
        time.sleep(0.6)
        said = ev(page, "JSON.stringify(window.__said)")
        said = json.loads(said or "{}")
        t.ok("the same site's frame translated", any(v.startswith(TAG) for k, v in said.items() if k.startswith("127.0.0.1")), said)
        t.ok("another site's frame translated", any(v.startswith(TAG) for k, v in said.items() if k.startswith("localhost")), said)
        ev(page, f"var f = document.createElement('iframe'); f.src = '{OTHER}/frame-fr?late'; document.body.appendChild(f); 1")
        time.sleep(2)
        ev(page, "ask()")
        time.sleep(0.6)
        said = json.loads(ev(page, "JSON.stringify(window.__said)") or "{}")
        t.ok("a frame added later is translated", sum(1 for v in said.values() if v.startswith(TAG)) >= 2 and tr(page, "state")["report"].get("frames") == 3,
             (said, tr(page, "state")["report"].get("frames")))
        tr(page, "original")
        time.sleep(0.8)
        ev(page, "ask()")
        time.sleep(0.6)
        said = json.loads(ev(page, "JSON.stringify(window.__said)") or "{}")
        t.ok("Show Original reaches the frames", said and not any(v.startswith(TAG) for v in said.values()), said)

        # 4: what the page adds or changes later.
        page = visit("/dynamic")
        tr(page)
        ev(page, "var p = document.createElement('p'); p.id = 'late'; p.textContent = 'Un paragraphe ajouté plus tard'; document.getElementById('more').appendChild(p); 1")
        ev(page, "document.getElementById('live').firstChild.nodeValue = 'Deuxième version du texte'; 1")
        time.sleep(1.5)
        t.ok("text added later is translated", text(page, "#late") == TAG + "Un paragraphe ajouté plus tard", text(page, "#late"))
        t.ok("text the page changes is translated again", text(page, "#live") == TAG + "Deuxième version du texte", text(page, "#live"))
        tr(page, "original")
        time.sleep(0.6)
        t.ok("Show Original gives the page's latest words", text(page, "#live") == "Deuxième version du texte" and text(page, "#late") == "Un paragraphe ajouté plus tard")

        # 5: mixed languages.
        page = visit("/mixed")
        st = tr(page)
        t.ok("the page's French is translated", text(page, "#f1").startswith(TAG))
        t.ok("an English block is left as it is", text(page, "#en") == EN, text(page, "#en"))
        t.ok("a German block is translated from German", text(page, "#de") == "[de→en] " + DE, text(page, "#de"))
        langs = st["report"].get("languages", {})
        t.ok("each block's language counted", langs.get("en", 0) >= 1 and langs.get("de", 0) >= 1 and langs.get("fr", 0) >= 2, langs)

        # 6: navigation ends it; the next page isn't translated.
        page = visit("/ticker")
        tr(page)
        time.sleep(1)
        lines = ev(page, "Array.from(document.querySelectorAll('#feed p')).map(p => p.textContent)")
        t.ok("a page adding lines has them translated as they come", len(lines) >= 3 and sum(1 for l in lines[:-2] if l.startswith(TAG)) >= len(lines) - 3, lines)
        sv.cmd({"do": "go", "id": page, "url": f"{SITE}/plain"})
        time.sleep(1.5)
        st = tr(page, "state")
        t.ok("navigating ends the translation", st["running"] is False and st["mark"] == {}, st)
        t.ok("the next page stays as it is", text(page, "#p1") == FR)

        # 7: a page that keeps its own text nodes.
        page = visit("/react")
        tr(page)
        for _ in range(3):
            ev(page, "document.getElementById('b').click(); 1")
        time.sleep(1.2)
        t.ok("the page's script still runs, with no errors", ev(page, "window.__errors") == 0)
        t.ok("its nodes are still its own", ev(page, "window.__check()") is True)
        t.ok("what it renders is translated", text(page, "h1") == TAG + "Clics : 3" and (text(page, "li") or "").startswith(TAG), (text(page, "h1"), text(page, "li")))
        tr(page, "original")
        time.sleep(0.5)
        ev(page, "document.getElementById('b').click(); 1")
        t.ok("and after Show Original it renders its own words", text(page, "h1") == "Clics : 4" and ev(page, "window.__check()") is True)

        # 8: errors are said quietly.
        page = visit("/numbers")
        st = tr(page)
        t.ok("a page with no words says so", st["mark"].get("phase") == "failed" and "language" in st["mark"].get("message", ""), st["mark"])
        page = visit("/plain")
        st = tr(page, "fr")
        t.ok("a page already in the language says so", st["mark"].get("phase") == "failed" and "already" in st["mark"].get("message", ""), st["mark"])

        # 9: Always Translate, and sleep.
        page = visit("/plain")
        tr(page)
        st = tr(page, "always", "fr")
        t.ok("Always Translate French is kept", st["always"] == ["fr"], st)
        other = visit("/dynamic")
        time.sleep(1)
        t.ok("the next French page translates as it opens", text(other, "#p1").startswith(TAG), text(other, "#p1"))
        st = tr(other, "never", "fr")
        t.ok("and stops when taken back", st["always"] == [], st)
        # A tab of the window's own (a bench tab never sleeps), behind another.
        page = sv.cmd({"do": "split", "action": "open", "url": f"{SITE}/plain"})["resultID"]
        time.sleep(1.5)
        tr(page)
        sv.cmd({"do": "split", "action": "open", "url": f"{SITE}/numbers"})
        time.sleep(1.5)
        slept = sv.cmd({"do": "split", "action": "sleep", "id": page})
        time.sleep(0.5)
        t.ok("the tab sleeps", "asleep" in json.dumps(slept), slept)
        t.ok("a translated tab put to sleep remembers it", tr(page, "state")["wake"] == "en")
        sv.cmd({"do": "select", "id": page})
        time.sleep(2.5)
        t.ok("and is translated again when it wakes", (text(page, "#p1") or "").startswith(TAG), text(page, "#p1"))

        # 10: a private tab remembers nothing.
        page = visit("/secret", private=True)
        st = tr(page)
        t.ok("a private tab translates", st["shy"] is True and text(page, "#p1").startswith(TAG), st["mark"])
        st = tr(page, "always", "fr")
        t.ok("its Always Translate is the tab's alone", st["tabAlways"] == ["fr"] and st["always"] == [], st)
        saved = subprocess.run(["defaults", "read", sv.SUITE, "translate.always"], capture_output=True, text=True).stdout
        t.ok("nothing written to the settings", "fr" not in saved, saved)
        sv.cmd({"do": "go", "id": page, "url": f"{SITE}/dynamic"})
        time.sleep(2)
        t.ok("the private tab translates its next French page", (text(page, "#p1") or "").startswith(TAG))
        sv.quit()
        time.sleep(0.5)
        found = subprocess.run(["grep", "-rlE", "Zanzibarique|confidentiel", sv.SUPPORT], capture_output=True, text=True).stdout.strip()
        t.ok("nothing of the private page, translated or not, in the world's files", found == "", found)

        # 11: a target chosen independently of the system language is used
        # by the menu, manual translation and automatic translation alike.
        sv.setup()
        subprocess.run(["defaults", "write", sv.SUITE, "translate.target", "-string", "ja"], check=True)
        launch()
        page = visit("/plain")
        t.ok("the menu names the chosen language", menu(page) == "Translate Page to Japanese", menu(page))
        st = tr(page, "toggle")
        t.ok("manual translation uses the chosen language", st["mark"].get("to") == "ja" and text(page, "#p1").startswith("[fr→ja] "), st)
        tr(page, "always", "fr")
        other = visit("/dynamic")
        time.sleep(1)
        t.ok("automatic translation uses the chosen language", (text(other, "#p1") or "").startswith("[fr→ja] "), text(other, "#p1"))
        sv.quit()
        launch()
        page = visit("/plain")
        time.sleep(1)
        t.ok("the choice and automatic translation survive restart", tr(page, "state")["mark"].get("to") == "ja", tr(page, "state"))
    finally:
        t.done()
        sv.finish()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())
