import * as dgram from 'dgram';
import { describe, expect, it } from 'bun:test';
import { Blocklist } from '../src/blocklist';
import { parseArgs } from '../src/config';
import { DnsFilterProxy } from '../src/proxy';
import { allocBuffer } from '../src/buffer';
import { healthName, healthResponse } from '../src/probe';
import { parseDnsQuery } from '../src/dns';

function query(name: string): Buffer {
  const b=allocBuffer(12+name.length+6); b.writeUInt16BE(42,0); b.writeUInt16BE(0x100,2);b.writeUInt16BE(1,4);
  let o=12;for(const label of name.split('.')) {b[o++]=label.length;b.write(label,o,label.length,'ascii');o+=label.length;}
  b[o++]=0;b.writeUInt16BE(16,o);b.writeUInt16BE(1,o+2);return b;
}
function start(proxy: DnsFilterProxy): Promise<void> {return new Promise((resolve,reject)=>proxy.start(e=>e?reject(e):resolve()));}
function stop(proxy: DnsFilterProxy): Promise<void> {return new Promise(resolve=>proxy.close(resolve));}
function proxy(): DnsFilterProxy {
 return new DnsFilterProxy({listenAddress:'127.0.0.1',listenPort:0,upstream:{host:'192.0.2.1',port:53},blocklistPath:'unused',blocklistFormat:'domains',timeoutMs:100,logBlocked:false,localClientsOnly:true},new Blocklist([],{generation:'access-test',declaredRuleCount:0}));
}

describe('TV-local listener restriction and path probe',()=>{
 it('requires an explicit restriction for non-loopback CLI listeners',()=>{
  expect(()=>parseArgs(['--listen-address','192.0.2.20','--upstream','192.0.2.1','--blocklist','unused'])).toThrow();
  expect(parseArgs(['--local-clients-only','--listen-address','192.0.2.20','--upstream','192.0.2.1','--blocklist','unused']).config!.localClientsOnly).toBe(true);
 });
 it('responds to an exact health generation and refuses a stale generation',()=>{
  const q=query(healthName('access-test')),p=parseDnsQuery(q)!;
  const response=healthResponse(q,p,'access-test')!;
  expect(response.readUInt16BE(6)).toBe(1);
  expect(response.slice(-11).toString('ascii')).toBe('access-test');
  expect(healthResponse(q,p,'new-generation')).toBe(null);
 });
 it('allows an assigned local UDP source and ignores a non-assigned source',async()=>{
  const p=proxy(); const allowed=dgram.createSocket('udp4'), denied=dgram.createSocket('udp4');
  try {
   await start(p);
   const q=query(healthName('access-test'));
   const received=await new Promise<Buffer>((resolve,reject)=>{
    const timer=setTimeout(()=>reject(new Error('local response timeout')),1000);
    allowed.once('message',b=>{clearTimeout(timer);resolve(b);});
    allowed.send(q,0,q.length,p.getListenPort(),'127.0.0.1');
   });
   expect(received.readUInt16BE(6)).toBe(1);
   await new Promise<void>(resolve=>denied.bind(0,'127.0.0.2',resolve));
   let replied=false;denied.once('message',()=>{replied=true;});
   denied.send(q,0,q.length,p.getListenPort(),'127.0.0.1');
   await new Promise(resolve=>setTimeout(resolve,150));expect(replied).toBe(false);
  } finally {allowed.close();denied.close();await stop(p);}
 });
 // Bun 1.3.14 ignores net.connect localAddress. The Node runtime smoke
 // suite tests real rejected TCP connections; this checks the handler policy.
 it('destroys a TCP socket whose peer is not assigned locally',async()=>{
  const p=proxy();await start(p);
  try {
   let destroyed=false;
   (p as any).handleTcpConnection({remoteAddress:'203.0.113.7',destroy:()=>{destroyed=true;}});
   expect(destroyed).toBe(true);
  } finally {await stop(p);}
 });
});
