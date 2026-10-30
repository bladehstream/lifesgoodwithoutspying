'use strict';
// Exercise the actual frontend parser and verdict with synthetic status only.
const fs = require('fs'), vm = require('vm'), assert = require('assert');
const source = fs.readFileSync(process.argv[2] || require('path').join(__dirname, '..', 'app', 'app.js'), 'utf8');
function section(a, b) {
  const begin = source.indexOf('    function ' + a), end = source.indexOf('    function ' + b, begin);
  if (begin < 0 || end < 0) throw Error('frontend functions not found');
  return source.slice(begin, end);
}
const elements = {};
function el(id) { return elements[id] || (elements[id] = {textContent: '', className: '', classList: {add(){},remove(){}}}); }
const ctx = {document:{getElementById:el}, appEl:el('app'), enabled:false, dirty:false,
  setText(element, key){element.textContent=key;}, updateMainButton(){}, invalidateNavigation(){}, Number};
vm.createContext(ctx);
vm.runInContext(section('parseStatus', 'toArray') + section('setTag', 'appIsActive'), ctx);
const base = 'autostart=on\nchanges=none\nhosts=ours\nblocklist=2\ndns.filter=off\n' +
  'voice.stop=on\nads.stop=on\nvoice=stopped\nads=stopped\n';
function verdict(text) { ctx.dirty = false; ctx.renderState(ctx.parseStatus(text), true); return el('verdict').textContent; }
if (process.argv[3] === '--stdin') {
  const processStatus = fs.readFileSync(0, 'utf8');
  const preamble = base.replace('voice=stopped\n', '').replace('ads=stopped\n', '');
  assert.strictEqual(verdict(preamble + processStatus), process.argv[4]);
  process.exit(0);
}
assert.strictEqual(verdict(base), 'verdict.protected');
for (const text of [base.replace('voice=stopped', 'voice=running'),
                    base.replace('ads=stopped', 'ads=running'),
                    base.replace('voice=stopped', 'voice=unknown'),
                    base.replace('ads=stopped\n', ''),
                    base.replace('hosts=ours', 'hosts=open'),
                    base.replace('blocklist=2', 'blocklist=invalid'),
                    base.replace('changes=none\n', ''),
                    base + 'voice=running\n',
                    base.replace('voice=stopped\n', 'voice=running\nvoice=stopped\n')]) {
  assert.strictEqual(verdict(text), 'verdict.statusAttention');
}
assert.strictEqual(verdict(base + 'voice=running\nvoice=stopped\n_invalidStatus=\n'), 'verdict.statusAttention');
assert.strictEqual(el('r-voice').textContent, 'value.stopped');
assert.strictEqual(verdict(base.replace('voice=stopped', 'voice=unknown')), 'verdict.statusAttention');
assert.strictEqual(el('r-voice').textContent, 'value.unavailable');
assert.strictEqual(verdict(base.replace('hosts=ours', 'hosts=waiting')), 'verdict.sdpGrace');
assert.strictEqual(verdict(base.replace('voice.stop=on', 'voice.stop=off').replace('voice=stopped', 'voice=running')), 'verdict.protected');
if (process.argv[3] === '--pr18') {
  assert.strictEqual(verdict(base + 'job=running\n'), 'verdict.applying');
  ctx.renderState(ctx.parseStatus(base), null);
  assert.strictEqual(el('verdict').textContent, 'verdict.noAnswer');
}
console.log('PASS: synthetic process, scan-failure, duplicate and host-state verdicts');
