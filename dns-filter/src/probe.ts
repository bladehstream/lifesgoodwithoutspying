import * as dgram from 'dgram';
import * as net from 'net';
import { randomBytes } from 'crypto';
import { allocBuffer, copyBuffer } from './buffer';
import { DnsQuery, parseDnsQuery } from './dns';
import { parseEndpoint } from './config';

export function healthName(generation: string): string {
  return '_nospy-health.' + generation + '.invalid';
}

// A generation-specific, TTL-zero TXT response verifies that a query reached
// this helper through ConnMan/NAT. It never contacts an upstream resolver.
export function healthResponse(query: Buffer, parsed: DnsQuery, generation: string): Buffer | null {
  if (parsed.name !== healthName(generation) || parsed.questionCount !== 1 ||
      query.readUInt16BE(parsed.questionEnd - 4) !== 16 ||
      query.readUInt16BE(parsed.questionEnd - 2) !== 1 || generation.length > 63) return null;
  const out = allocBuffer(parsed.questionEnd + 13 + generation.length);
  query.copy(out, 0, 0, parsed.questionEnd);
  out.writeUInt16BE(0x8180, 2); out.writeUInt16BE(1, 6);
  out.writeUInt16BE(0, 8); out.writeUInt16BE(0, 10);
  let offset = parsed.questionEnd;
  out.writeUInt16BE(0xc00c, offset); offset += 2;
  out.writeUInt16BE(16, offset); offset += 2;
  out.writeUInt16BE(1, offset); offset += 2;
  out.writeUInt32BE(0, offset); offset += 4;
  out.writeUInt16BE(generation.length + 1, offset); offset += 2;
  out[offset++] = generation.length;
  out.write(generation, offset, generation.length, 'ascii');
  return out;
}

function healthQuery(generation: string): Buffer {
  if (!/^[A-Za-z0-9._-]{1,63}$/.test(generation)) throw new Error('invalid probe generation');
  const name = healthName(generation);
  const out = allocBuffer(12 + name.length + 2 + 4);
  out.writeUInt16BE(randomBytes(2).readUInt16BE(0), 0);
  out.writeUInt16BE(0x0100, 2); out.writeUInt16BE(1, 4);
  let offset=12;
  for (const label of name.split('.')) {
    if (label.length > 63) throw new Error('probe label too long');
    out[offset++] = label.length;
    out.write(label, offset, label.length, 'ascii'); offset += label.length;
  }
  out[offset++] = 0;
  out.writeUInt16BE(16, offset); out.writeUInt16BE(1, offset+2);
  return out;
}

export function mainProbe(args: string[]): void {
  try {
    if (args.length !== 2) throw new Error('usage: --probe ADDRESS:PORT GENERATION');
    const target = parseEndpoint(args[0]);
    if (net.isIP(target.host) !== 4) throw new Error('probe requires an IPv4 literal');
    const generation=args[1], query=healthQuery(generation);
    const valid = (response: Buffer) => {
      if (response.length < 12 || response.readUInt16BE(0) !== query.readUInt16BE(0) ||
          (response.readUInt16BE(2) & 0x800f) !== 0x8000 || response.readUInt16BE(6) !== 1) return false;
      const normalized=copyBuffer(response);
      normalized.writeUInt16BE(response.readUInt16BE(2) & 0x7fff, 2);
      const parsed=parseDnsQuery(normalized);
      return parsed !== null && parsed.name === healthName(generation) &&
        response.slice(-generation.length).toString('ascii') === generation;
    };
    const udp=dgram.createSocket('udp4');
    let finished=false;
    const fail=(message: string) => {
      if (finished) return; finished=true; clearTimeout(timer);
      try { udp.close(); } catch (_) { /* closed already */ }
      console.error('probe: '+message); process.exitCode=1;
    };
    const timer=setTimeout(() => fail('UDP path did not acknowledge generation'),2500);
    udp.on('error',(error: Error) => fail(error.message));
    udp.on('message',(response: Buffer, remote: any) => {
      if (remote.address !== target.host || remote.port !== target.port || !valid(response) || finished) return;
      finished=true; clearTimeout(timer); udp.close();
      const tcp=net.createConnection({host:target.host,port:target.port});
      let buffer=allocBuffer(0), tcpDone=false;
      const finish=(error?: string) => {
        if (tcpDone) return; tcpDone=true; tcp.destroy();
        if (error) { console.error('probe: '+error); process.exitCode=1; }
        else console.log('probe passed: UDP/TCP generation='+generation);
      };
      tcp.setTimeout(2500,() => finish('TCP path timed out'));
      tcp.on('error',(error: Error) => finish(error.message));
      tcp.on('close',() => { if (!tcpDone) finish('TCP path closed without acknowledgement'); });
      tcp.on('connect',() => {
        const frame=allocBuffer(query.length+2); frame.writeUInt16BE(query.length,0); query.copy(frame,2); tcp.write(frame);
      });
      tcp.on('data',(chunk: Buffer) => {
        buffer=Buffer.concat([buffer,chunk]);
        if (buffer.length > 65537) { finish('oversized TCP probe response'); return; }
        if (buffer.length < 2 || buffer.length < buffer.readUInt16BE(0)+2) return;
        finish(valid(buffer.slice(2,buffer.readUInt16BE(0)+2)) ? undefined : 'TCP generation mismatch');
      });
    });
    udp.send(query,0,query.length,target.port,target.host);
  } catch (error) {
    console.error('probe: '+(error instanceof Error ? error.message : String(error)));
    process.exitCode=1;
  }
}
