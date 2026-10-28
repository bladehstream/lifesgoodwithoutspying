'use strict';
const fs = require('fs'), vm = require('vm'), assert = require('assert');
const source = fs.readFileSync('app/app.js', 'utf8');
function section(a,b) { return source.slice(source.indexOf('    function '+a),source.indexOf('    function '+b)); }
const state = {on:false}, detail = {textContent:''};
const purge = {disabled:true,classList:{toggle(k,v){state[k]=v;},contains(k){return !!state[k];}},
 getAttribute(k){return {'data-key':'purge.boot','data-unavailable':'true'}[k] || null;},
 setAttribute(k,v){this[k]=v;},querySelector(){return detail;}};
const now = {disabled:true,classList:{contains(){return false;}},getAttribute(k){return k === 'data-unavailable' ? 'true' : null;}};
const ui = {toggleButtons:()=>[purge],allButtons:()=>[purge,now],uiBusy:false,
 document:{getElementById:()=>null,activeElement:null},restoreFocus:null,HTMLButtonElement:function(){},
 stopStatusPolling(){},scheduleStatusPolling(){},invalidateNavigation(){}};
vm.createContext(ui);
vm.runInContext(section('renderToggles','updateMainButton') + section('busy','run'),ui);
ui.renderToggles({'purge.boot':'on'}); assert.equal(purge.disabled,false); ui.busy(false);
assert.equal(purge['aria-checked'],'true'); assert.match(detail.textContent,/turn off/); assert.equal(now.disabled,true);
ui.busy(true); assert.equal(purge.disabled,true);
ui.renderToggles({'purge.boot':'off'}); ui.busy(false);
assert.equal(purge.disabled,true); assert.equal(purge['aria-checked'],'false');
console.log('Legacy purge selection UI check passed');
