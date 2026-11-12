const fs=require('node:fs'), vm=require('node:vm'), path=require('node:path'), assert=require('node:assert/strict');
const source=fs.readFileSync(process.argv[2]||path.join(__dirname,'../../Sources/Search/ExtensionShims.swift'),'utf8');
const script=source.split('nonisolated static let script = #"""\n')[1].split('\n    """#')[0];
const harness=fs.readFileSync(path.join(__dirname,'../ExtensionWorkerRecovery/shim-harness.js'),'utf8');
const fixture=vm.runInNewContext(harness+'\nrecoveryFixture',{console});
const bus=new Map();
const sender=fixture(false), receiver=fixture(false);
for(const state of [sender,receiver]) {
 state.root.BroadcastChannel=class {
  constructor(name){this.name=name;if(!bus.has(name))bus.set(name,[]);bus.get(name).push(this);}
  postMessage(data){for(const peer of bus.get(this.name))if(peer!==this)queueMicrotask(()=>peer.onmessage?.({data:structuredClone(data)}));}
 };
 vm.runInNewContext(script,state.root);
}
const drain=async()=>{for(let i=0;i<50;i++)await Promise.resolve();};
const relayTimers=()=>{for(const timer of receiver.timers.splice(0))if(timer.delay===50)timer.callback();};
(async()=>{
 let calls=0, reply;
 receiver.runtime.onMessage.addListener((message,from,respond)=>{calls++;reply=respond;return true;});
 let settled=false;
 const answer=sender.runtime.sendMessage({target:'offscreen',request:{action:'port',details:{id:'not-secret',message:{value:1}}}}).then(r=>{settled=true;return r;});
 await drain();relayTimers();await drain();
 assert.equal(calls,1);assert.equal(settled,false,'an empty native result must not beat a held relay response');
 receiver.runtime.onMessage.fire({request:{details:{message:{value:1},id:'not-secret'},action:'port'},target:'offscreen'},
  {id:'fixture',url:sender.root.location.href},()=>{});
 assert.equal(calls,1,'a late native copy must not run the listener again');
 reply({result:{ok:true,bytes:65536}});await drain();
 const result=await answer;
 assert.equal(result.result.bytes,65536);
 assert.equal(result.result.ok,true);
 console.log('PASS whole-shim relay-first async response survives empty native result and reordered late native duplicate');
})().catch(e=>{console.error(e);process.exitCode=1;});
