const owned = new Set();
chrome.runtime.onMessage.addListener((m,sender,respond)=>{
  if(m?.fixture!=='binary-offscreen')return;
  if(m.op==='revoke'){if(owned.delete(m.url))URL.revokeObjectURL(m.url);respond({ok:true});return;}
  const url=URL.createObjectURL(new Blob([Uint8Array.from({length:m.size},(_,i)=>i%256)],{type:'application/octet-stream'}));
  owned.add(url);respond({url,size:m.size});
});
