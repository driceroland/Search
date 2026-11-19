const boot = Date.now() + '-' + Math.random().toString(36).slice(2);
const ready = chrome.scripting.registerContentScripts([{id:'dynamic-binary',matches:['http://127.0.0.1/dynamic*'],js:['dynamic.js','content.js'],runAt:'document_idle',persistAcrossSessions:false}]).catch(e=>{if(!/duplicate/i.test(String(e)))throw e;});
chrome.runtime.onMessage.addListener((m,sender,respond)=>{
  if(m?.fixture!=='binary')return;
  (async()=>{
    await ready;
    if(m.op==='echo')return {boot,ok:true};
    if(m.op==='close'){if(await chrome.offscreen.hasDocument())await chrome.offscreen.closeDocument();return {ok:true};}
    if(!await chrome.offscreen.hasDocument())await chrome.offscreen.createDocument({url:'offscreen.html',reasons:['BLOBS'],justification:'Local binary transport regression'});
    return await chrome.runtime.sendMessage({...m,fixture:'binary-offscreen'});
  })().then(respond,error=>respond({error:String(error)}));
  return true;
});
chrome.runtime.onMessageExternal.addListener((m,sender,respond)=>{if(m?.ping)respond({ok:true});});
