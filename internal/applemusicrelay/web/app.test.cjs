// Protocol/UI fixtures; no network and no real Apple account authorization.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(__dirname + '/app.js', 'utf8');
const opaque = c => c.repeat(43);
async function page({mode='connect',authorize=async()=> 'fixture-MUT',responseError,fragment}={}) {
  const elements = new Map();
  const element = id => {
    if (!elements.has(id)) elements.set(id,{textContent:'',hidden:id==='return',disabled:true,handlers:{},addEventListener(event,fn){this.handlers[event]=fn;}});
    return elements.get(id);
  };
  const calls=[],navigations=[]; let authorized=0,revoked=0;
  const callback='com.guohuiyuan.musicdl.apple-login://callback?id='+opaque('f')+'&state='+opaque('s')+'&code='+opaque('c');
  const context={URL,Error,TypeError,Promise,
    setTimeout:(fn,ms)=>{const t=setTimeout(fn,ms);t.unref();return t;},
    document:{getElementById:element,addEventListener(){throw Error('SDK should already be available in fixture');}},
    location:{pathname:'/'+mode,origin:'https://relay.example.com',hash:fragment??'#'+opaque('f')+'.'+opaque('b'),assign(url){navigations.push(url);}},
    history:{replaceState(_a,_b,path){calls.push({history:path});}},
    fetch:async(path,options)=>{
      calls.push({path,options});
      if (responseError && path==='/v1/browser/complete') return {ok:false,json:async()=>({error:responseError,debug:'MUT-secret-must-not-display'})};
      if(path==='/v1/web-config')return {ok:true,json:async()=>({developerToken:'fixture-developer-JWT'})};
      if(path==='/v1/browser/complete')return {ok:true,json:async()=>({callback})};
      if(path==='/v1/browser/cancel')return {ok:true,json:async()=>({callback:callback.replace('&code='+opaque('c'),'&error=cancelled')})};
      return {ok:true,json:async()=>({ready:true})};
    },
    MusicKit:{configure:async()=>{},getInstance:()=>({authorize:()=>{authorized++;return authorize();},unauthorize:async()=>{revoked++;}})}
  };
  context.window={MusicKit:context.MusicKit};
  vm.runInNewContext(source,context);
  for(let i=0;i<5;i++)await new Promise(resolve=>setImmediate(resolve));
  return {elements,calls,navigations,authorized:()=>authorized,revoked:()=>revoked};
}
test('v3 authorization starts only on explicit user click and MUT never enters return URL',async()=>{
  const p=await page();assert.equal(p.authorized(),0);
  assert.equal(p.elements.get('connect').disabled,false);
  const clicked=p.elements.get('connect').handlers.click();
  assert.equal(p.authorized(),1);await clicked;
  const post=p.calls.find(x=>x.path==='/v1/browser/complete');
  assert.equal(JSON.parse(post.options.body).token,'fixture-MUT');
  assert.equal(post.options.credentials,'same-origin');
  assert.equal(p.navigations.length,1);
  assert.ok(!p.navigations[0].includes('fixture'));
  assert.equal(p.elements.get('return').hidden,false);
});
test('real upstream error code yields actionable sanitized message',async()=>{
  const p=await page({responseError:'apple_rate_limited'});
  await p.elements.get('connect').handlers.click();
  assert.match(p.elements.get('status').textContent,/稍后重试/);
  assert.ok(!p.elements.get('status').textContent.includes('MUT-secret'));
  assert.equal(p.navigations.length,0);
});
test('raw MusicKit error details never appear in the page',async()=>{
  const p=await page({authorize:async()=>{throw Error('sensitive-token-should-never-appear');}});
  await p.elements.get('connect').handlers.click();
  assert.ok(!p.elements.get('status').textContent.includes('sensitive-token'));
  assert.equal(p.navigations.length,0);
});
test('browser cancellation removes server flow and returns a state-bound cancellation',async()=>{
  const p=await page();await p.elements.get('cancel').handlers.click();
  assert.ok(p.calls.some(x=>x.path==='/v1/browser/cancel'));
  assert.match(p.elements.get('return').href,/error=cancelled/);
  assert.equal(p.elements.get('connect').disabled,true);
  assert.equal(p.authorized(),0);
});
test('website revoke uses official unauthorize without collecting any credentials',async()=>{
  const p=await page({mode:'disconnect'});await p.elements.get('connect').handlers.click();
  assert.equal(p.revoked(),1);assert.equal(p.authorized(),0);
  assert.ok(!p.calls.some(x=>x.path==='/v1/browser/complete'));
});
test('invalid or replayed fragment never starts Apple authorization',async()=>{
  const p=await page({fragment:'#invalid'});assert.equal(p.authorized(),0);
  assert.equal(p.elements.get('connect').disabled,true);
  assert.match(p.elements.get('status').textContent,/过期或已取消/);
});
