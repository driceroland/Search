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

 // No other page is open and the worker answers nothing: main settles at once.
 const alone=fixture(false);
 alone.root.BroadcastChannel=class { constructor(){} postMessage(){} };
 vm.runInNewContext(script,alone.root);
 let aloneSettled=false;
 const aloneAnswer=alone.runtime.sendMessage({only:'worker'}).then(r=>{aloneSettled=true;return r;});
 await drain();
 assert.equal(aloneSettled,true,'an unanswered message with no other page must not wait out the relay countdown');
 assert.equal(await aloneAnswer,undefined);

 // An empty reply counts down. It must not settle over a page that is holding the answer.
 const bus2=new Map();
 const from=fixture(false), quiet=fixture(false), holder=fixture(false);
 for(const state of [from,quiet,holder]) {
  state.root.BroadcastChannel=class {
   constructor(name){this.name=name;if(!bus2.has(name))bus2.set(name,[]);bus2.get(name).push(this);}
   postMessage(data){for(const peer of bus2.get(this.name))if(peer!==this)queueMicrotask(()=>peer.onmessage?.({data:structuredClone(data)}));}
  };
  vm.runInNewContext(script,state.root);
 }
 const fireRelay=state=>{for(const timer of state.timers.splice(0))if(timer.delay===50)timer.callback();};
 quiet.runtime.onMessage.addListener((message,sender,respond)=>{respond(undefined);});
 let held;
 holder.runtime.onMessage.addListener((message,sender,respond)=>{held=respond;return true;});
 let blocked=false;
 const raced=from.runtime.sendMessage({held:'answer'}).then(r=>{blocked=true;return r;});
 await drain();fireRelay(quiet);fireRelay(holder);await drain();
 assert.equal(blocked,false,'an empty relay reply must not settle while another page holds the answer');
 held({kept:true});await drain();
 assert.deepEqual(await raced,{kept:true});

 // Every open page replies empty and none is holding an answer: settle at
 // once, the way Chrome does, instead of waiting out the countdown.
 const bus3=new Map();
 const asker=fixture(false), left=fixture(false), right=fixture(false);
 for(const state of [asker,left,right]) {
  state.root.BroadcastChannel=class {
   constructor(name){this.name=name;if(!bus3.has(name))bus3.set(name,[]);bus3.get(name).push(this);}
   postMessage(data){for(const peer of bus3.get(this.name))if(peer!==this)queueMicrotask(()=>peer.onmessage?.({data:structuredClone(data)}));}
  };
  vm.runInNewContext(script,state.root);
 }
 const fireEmpty=state=>{for(const timer of state.timers.splice(0))if(timer.delay===50)timer.callback();};
 left.runtime.onMessage.addListener((message,sender,respond)=>{respond(undefined);});
 right.runtime.onMessage.addListener((message,sender,respond)=>{respond(undefined);});
 let quietSettled=false;
 const quietAnswer=asker.runtime.sendMessage({nobody:'listening'}).then(r=>{quietSettled=true;return r;});
 await drain();fireEmpty(left);fireEmpty(right);await drain();
 assert.equal(quietSettled,true,'empty replies from every open page must not wait out the countdown');
 assert.equal(await quietAnswer,undefined);
 const waitingOut=asker.timers.some(timer=>timer.delay===10000);
 assert.equal(waitingOut,true,'a page that never replies still has the countdown behind it');
 for(const timer of asker.timers)if(timer.delay===10000)assert.equal(quietSettled,true,'the countdown must not be what settled every empty reply');
 console.log('PASS whole-shim relay-first async response survives empty native result and reordered late native duplicate');
})().catch(e=>{console.error(e);process.exitCode=1;});
