'use strict';
// Exercise the real frontend verdict with the actual domain buttons and synthetic status.
const fs = require('fs'), path = require('path'), vm = require('vm'), assert = require('assert');
const source = fs.readFileSync(process.argv[2] || path.join(__dirname, '..', 'app', 'app.js'), 'utf8');
const html = fs.readFileSync(path.join(__dirname, '..', 'app', 'index.html'), 'utf8');
const keys = Array.from(html.matchAll(/data-key="(domains\.[a-zA-Z0-9_.-]+)"/g), m => m[1]);
assert(keys.length > 0);
function section(a,b) {
  const start=source.indexOf('    function '+a), end=source.indexOf('    function '+b,start);
  if(start<0||end<0) throw Error('function not found: '+a);
  return source.slice(start,end);
}
const els={};
function el(id) { return els[id] || (els[id]={textContent:'',className:'',classList:{add(){},remove(){}}}); }
const ctx={document:{getElementById:el},appEl:el('app'),enabled:false,dirty:false,Number,
  setText(e,key){e.textContent=key;},updateMainButton(){},invalidateNavigation(){},
  toggleButtons(){return keys.map(key=>({getAttribute(){return key;}}));}};
vm.createContext(ctx);
let functions=section('parseStatus','toArray');
if(source.indexOf('    function domainListsMatch(')>=0) functions+=section('domainListsMatch','updateMainButton');
functions+=section('setTag','appIsActive');
vm.runInContext(functions,ctx);
if (process.argv[3] === '--stdin') {
  const status = fs.readFileSync(0,'utf8');
  const preamble='autostart=on\nchanges=none\nhosts=ours\nblocklist=2\ndns.filter=off\n'+
    'voice.stop=on\nads.stop=on\nvoice=stopped\nads=stopped\n';
  ctx.renderState(ctx.parseStatus(preamble+status),true);
  assert.strictEqual(el('verdict').textContent,process.argv[4]);
  process.exit(0);
}
const settings=keys.map(k=>k+'='+(k==='domains.acr'?'on':'off')).join('\n');
const base='autostart=on\nchanges=none\nhosts=ours\nblocklist=2\ndns.filter=off\n'+
  'voice.stop=on\nads.stop=on\nvoice=stopped\nads=stopped\n'+settings+'\n';
function verdict(domainState) {
  ctx.renderState(ctx.parseStatus(base+'domain_lists='+domainState+'\n'),true);
  return el('verdict').textContent;
}
assert.strictEqual(verdict('ok:domains.acr'),'verdict.protected');
assert.strictEqual(verdict('unavailable'),'verdict.domainAttention');
assert.strictEqual(verdict('none'),'verdict.domainAttention');
assert.strictEqual(verdict('ok:domains.smartad'),'verdict.domainAttention');
console.log('PASS: real domain buttons and selected-list warning');
