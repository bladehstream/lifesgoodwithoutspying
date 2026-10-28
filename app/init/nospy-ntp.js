// lifesgoodwithoutspying - one-shot SNTP query.
//
// Prints the current Unix time in seconds and exits 0, or exits 1 if no server
// gave a usable answer. Written for every Node the TVs ship (0.12 on webOS 3.x),
// so ES5 only.
//
// Usage: node nospy-ntp.js [server ...]
'use strict';

var dgram = require('dgram');
var crypto = require('crypto');

var NTP_EPOCH_OFFSET = 2208988800; // seconds from 1900-01-01 to 1970-01-01
var TIMEOUT_MS = 3000;
// An answer older than this is a broken server, not the real time.
var MIN_SANE = 1767225600; // 2026-01-01

var servers = process.argv.slice(2);
if (servers.length === 0)
    servers = ['0.pool.ntp.org', '1.pool.ntp.org', '2.pool.ntp.org'];

function allocBuffer(size) {
    if (typeof Buffer.alloc === 'function')
        return Buffer.alloc(size);
    var b = new Buffer(size);
    b.fill(0);
    return b;
}

function query(server, done) {
    var socket = dgram.createSocket('udp4');
    var request = allocBuffer(48);
    // LI 0, version 4, mode 3 (client).
    request[0] = 0x23;
    // A random transmit timestamp; the server must echo it back as the
    // originate timestamp, so a stray or spoofed packet is ignored.
    var token = crypto.randomBytes(8);
    token.copy(request, 40);
    var finished = false;
    function finish(seconds) {
        if (finished)
            return;
        finished = true;
        clearTimeout(timer);
        try { socket.close(); } catch (e) { }
        done(seconds);
    }
    var timer = setTimeout(function () { finish(null); }, TIMEOUT_MS);
    socket.on('error', function () { finish(null); });
    socket.on('message', function (msg) {
        if (msg.length < 48)
            return;
        var leap = msg[0] >> 6;
        var mode = msg[0] & 0x07;
        var stratum = msg[1];
        if (mode !== 4 || leap === 3 || stratum < 1 || stratum > 15)
            return;
        for (var i = 0; i < 8; i++) {
            if (msg[24 + i] !== token[i])
                return;
        }
        var ntpSeconds = msg.readUInt32BE(40);
        if (ntpSeconds === 0)
            return;
        var unix = ntpSeconds - NTP_EPOCH_OFFSET;
        // The 32-bit NTP seconds counter wraps in February 2036.
        if (unix < 0)
            unix += 4294967296;
        if (unix < MIN_SANE)
            return;
        finish(unix);
    });
    socket.send(request, 0, request.length, 123, server, function (err) {
        if (err)
            finish(null);
    });
}

function next(index) {
    if (index >= servers.length) {
        process.exit(1);
        return;
    }
    query(servers[index], function (seconds) {
        if (seconds === null) {
            next(index + 1);
            return;
        }
        process.stdout.write(seconds + '\n');
        process.exit(0);
    });
}

next(0);
