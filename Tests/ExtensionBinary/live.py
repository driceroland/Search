#!/usr/bin/env python3
"""Real WKWebExtension binary reads and idle wake in a disposable test world.
Build Search.app first. No Tampermonkey, VOT, accounts or remote HTTP needed.
"""
import json,sys,time,threading,signal
from pathlib import Path
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import split_view as sv
HERE=Path(__file__).resolve().parent
sv.use('extension-binary')
class Site(BaseHTTPRequestHandler):
 def do_GET(self):
  body=b'<!doctype html><title>Local binary regression</title><pre id="state">waiting</pre>'
  self.send_response(200);self.send_header('Content-Type','text/html');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
 def log_message(self,*args):pass
server=ThreadingHTTPServer(('127.0.0.1',0),Site)
threading.Thread(target=server.serve_forever,daemon=True).start()
base='http://127.0.0.1:'+str(server.server_port)
def cmd(req):
 result=sv.cmd(req)
 if result.get('onScreen'):raise RuntimeError('foreground guard tripped: invalid run')
 return result
def until(fn,seconds=25):
 end=time.monotonic()+seconds
 while time.monotonic()<end:
  value=fn()
  if value:return value
  time.sleep(.2)
 raise RuntimeError('condition deadline')
def install(folder,name):
 cmd({'do':'ext-folder','path':str(folder),'yes':True})
 return until(lambda:next((e for e in cmd({'do':'extensions'}).get('extensions',[]) if e['name']==name and e.get('loaded')),None))['id']
def run(route):
 tab=cmd({'do':'open','url':base+'/'+route})['id']
 def result():
  value=cmd({'do':'eval','id':tab,'js':'document.getElementById("state")?.textContent'})['value']
  try:rows=json.loads(value)
  except (ValueError,TypeError):return None
  if any(x.get('stage')=='error' for x in rows):raise RuntimeError(str(rows))
  return rows if any(x.get('stage')=='done' for x in rows) else None
 rows=until(result,45)
 if route.startswith('dynamic'):assert rows[0].get('dynamic')=='true',rows
 print(route,json.dumps(rows),flush=True)
 return tab,rows

def main():
 signal.alarm(240)
 tabs=[]
 try:
  sv.setup();sv.launch()
  until(lambda:cmd({'do':'extensions'}).get('started'))
  extension=install(HERE/'extension','Search Binary Transport Fixture')
  tab,first=run('static');tabs.append(tab)
  blob=cmd({'do':'eval','id':tab,'js':'document.documentElement.dataset.binaryURL'})['value']
  outsider=install(HERE/'outsider','Search Binary Outsider Fixture')
  page=cmd({'do':'ext-page','id':outsider,'path':'page.html'})['id'];tabs.append(page)
  until(lambda:cmd({'do':'eval','id':page,'js':'document.readyState === "complete" && !!globalThis.chrome?.runtime?.id'})['value'])
  probe='globalThis.isolation=null;fetch('+json.dumps(blob)+').then(r=>r.arrayBuffer()).then(b=>globalThis.isolation={leaked:true},e=>globalThis.isolation={leaked:false,error:e.name});"sent"'
  cmd({'do':'eval','id':page,'js':probe})
  answer=until(lambda:cmd({'do':'eval','id':page,'js':'globalThis.isolation'})['value'])
  assert not answer['leaked'],answer
  print('cross-extension fetch isolation',json.dumps(answer),flush=True)
  cmd({'do':'eval','id':tab,'js':probe})
  answer=until(lambda:cmd({'do':'eval','id':tab,'js':'globalThis.isolation'})['value'])
  assert not answer['leaked'],answer
  print('website main-world fetch isolation',json.dumps(answer),flush=True)
  for t in tabs:cmd({'do':'close','id':t})
  tabs=[]
  print('idle 80 seconds',flush=True)
  end=time.monotonic()+80
  while time.monotonic()<end:time.sleep(1)
  tab,last=run('static-after-idle');tabs.append(tab)
  print('worker replaced during idle',first[0]['boot']!=last[0]['boot'],flush=True)
  print('PASS real WebKit static binary reads, large body, response relay, other-extension isolation and idle requests',flush=True)
 finally:
  sv.finish();server.shutdown();sv.srv.shutdown();signal.alarm(0)
if __name__=='__main__':main()
