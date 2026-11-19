(async()=>{
 const results=[];
 const note=x=>{results.push(x);document.getElementById('state').textContent=JSON.stringify(results);};
 const ask=message=>new Promise((resolve,reject)=>{
   const timer=setTimeout(()=>reject(new Error('native runtime response deadline')),15000);
   chrome.runtime.sendMessage({fixture:'binary',...message},reply=>{
     clearTimeout(timer);
     if(chrome.runtime.lastError)reject(new Error(chrome.runtime.lastError.message));
     else if(reply?.error)reject(new Error(reply.error));else resolve(reply);
   });
 });
 try{
   let t=performance.now();const echo=await ask({op:'echo'});note({stage:'echo',boot:echo.boot,ms:performance.now()-t,dynamic:document.documentElement.dataset.binaryDynamicShim});
   for(const size of [0,5,1048597,8388621]){
     t=performance.now();const value=await ask({op:'make',size});
     const response=await fetch(value.url);const bytes=new Uint8Array(await response.arrayBuffer());
     if(bytes.length!==size||!bytes.every((b,i)=>b===i%256))throw new Error('binary integrity');
     note({stage:'body',size,ms:performance.now()-t,status:response.status,ok:true});
     if(size===5)document.documentElement.dataset.binaryURL=value.url;
     else await ask({op:'revoke',url:value.url});
   }
   note({stage:'done'});
 }catch(error){note({stage:'error',error:String(error)});}
})();
