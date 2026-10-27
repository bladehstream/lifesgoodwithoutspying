'use strict';
const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
const source = fs.readFileSync('app/app.js', 'utf8');
function section(first, next) { return source.slice(source.indexOf('    function ' + first), source.indexOf('    function ' + next)); }
const elements = {};
function element(id) { return elements[id] || (elements[id] = {textContent:'', className:'', classList:{add(){},remove(){}}}); }
const context = {document:{getElementById:element},appEl:element('app'),enabled:false,dirty:false,invalidateNavigation(){},Number};
vm.createContext(context);
vm.runInContext(section('updateMainButton','setTag') + section('setTag','appIsActive'),context);
const valid = {autostart:'on',last_apply:'passed',target_maintenance:'running',hosts:'ours',blocklist:'1','dns.filter':'off','ads.stop':'on','ads.stop.targets':'1','ads.stop.blocked':'1',ads:'stopped','voice.stop':'off','domains.thinq':'off'};
let count = 0;
for (const [patch,expected] of [
 [{},'Selected checks passed'],
 [{target_maintenance:'inactive'},'Target maintenance needs attention'],
 [{target_maintenance:'failed'},'Target maintenance needs attention'],
 [{last_apply:'applying',target_maintenance:'inactive'},'Applying protection'],
 [{'dns.filter':'on',dns_filter:'no',target_maintenance:'inactive',last_apply:'failed'},'DNS filter needs attention'],
 [{'ads.stop.targets':'0'},'Protection needs attention'],
 [{hosts:'open'},'Protection needs attention'],
 [{hosts:'failed'},'SDP update needs attention'],
 [{last_apply:'failed'},'Protection needs attention'],
 [{'dns.filter':'on',dns_filter:'no'},'DNS filter needs attention'],
 [{'dns.filter':'on',dns_filter:'yes',dns_filter_mode:'connman'},'TV resolver filtering active'],
]) {
 context.renderState(Object.assign({},valid,patch),true);
 assert.equal(elements.verdict.textContent,expected);count++;
}
context.getFolder = () => Promise.resolve('/fake');
context.shq = s => "'" + s + "'";
vm.runInContext(section('ctl','parseStatus'),context);
(async () => {
 for (const [stdout,ok] of [['status=on\nNOSPY_EXIT=0\n',true],['NOSPY_EXIT=1\n',false],['status=on\n',false]]) {
  context.exec = command => { assert(command.indexOf('LD_PRELOAD= sh ') === 0); return Promise.resolve({stdoutString:stdout}); };
  let success = true;
  try { await context.ctl('status'); } catch (_) { success = false; }
  assert.equal(success,ok);count++;
 }
 console.log(count + ' frontend checks passed');
})().catch(e => {console.error(e);process.exitCode=1;});
