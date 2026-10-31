// Talking to the TV: Luna calls, the Homebrew Channel's exec, nospy-ctl.sh
// and its background jobs. No DOM here; app.js passes in where log lines go
// and whether the app is showing.
'use strict';

window.nospyTv = function (log, isActive) {
    var APP_ID = 'ooo.lew.lifesgoodwithoutspying';
    var HBC = 'luna://org.webosbrew.hbchannel.service';
    // Older webOS engines (Chromium 53 and earlier) let an unreferenced
    // PalmServiceBridge be collected while its call is in flight, and the reply
    // is then never delivered. Hold each bridge until it answers.
    var pendingBridges = {};
    var nextBridgeId = 0;
    // Default limit for one Luna call. Past it the UI unlocks instead of
    // waiting forever.
    var LUNA_TIMEOUT_MS = 90000;
    // A failed call carries the service's reply as .data, so callers can tell
    // an answer of returnValue:false apart from no answer at all (.timedOut).
    function lunaError(message, data) {
        var e = new Error(message);
        e.data = data;
        return e;
    }
    // luna call, returns a promise that resolves to the parsed JSON result
    function luna(url, params, timeoutMs) {
        var limit = timeoutMs || LUNA_TIMEOUT_MS;
        var bridge = null;
        var bridgeId = null;
        var call = new Promise(function (resolve, reject) {
            var Bridge = window.PalmServiceBridge;
            if (typeof Bridge === 'function') {
                bridge = new Bridge();
                bridgeId = nextBridgeId++;
                pendingBridges[bridgeId] = bridge;
                bridge.onservicecallback = function (msg) {
                    delete pendingBridges[bridgeId];
                    var data;
                    try {
                        data = JSON.parse(msg);
                    }
                    catch (e) {
                        data = { raw: msg };
                    }
                    if (data && data.returnValue === false) {
                        reject(lunaError(data.errorText || 'Luna call failed', data));
                    }
                    else {
                        resolve(data);
                    }
                };
                try {
                    bridge.call(url, JSON.stringify(params || {}));
                }
                catch (e) {
                    delete pendingBridges[bridgeId];
                    reject(e);
                }
                return;
            }
            var runtime = window.webOS;
            if (runtime && runtime.service && runtime.service.request) {
                var m = url.match(/^luna:\/\/([^/]+)\/(.+)$/);
                if (!m) {
                    reject(new Error('bad luna url'));
                    return;
                }
                runtime.service.request('luna://' + m[1], {
                    method: m[2],
                    parameters: params || {},
                    onSuccess: function (r) { resolve(r); },
                    onFailure: function (e) {
                        reject(lunaError(e.errorText || 'Luna call failed', e));
                    }
                });
                return;
            }
            reject(new Error('No Luna bridge available (not running on webOS?)'));
        });
        var timer = null;
        var timeout = new Promise(function (_resolve, reject) {
            timer = setTimeout(function () {
                if (bridgeId !== null) {
                    delete pendingBridges[bridgeId];
                    try {
                        if (bridge.cancel)
                            bridge.cancel();
                    }
                    catch (_error) { }
                }
                var e = new Error('No reply from ' + url + ' after ' + (limit / 1000) + 's');
                e.timedOut = true;
                reject(e);
            }, limit);
        });
        return Promise.race([call, timeout]).then(function (res) {
            clearTimeout(timer);
            return res;
        }, function (e) {
            clearTimeout(timer);
            throw e;
        });
    }
    function delay(ms) {
        return new Promise(function (resolve) { setTimeout(resolve, ms); });
    }
    // The Homebrew Channel service quits after 30s without requests. A call
    // that reaches it while it is quitting is never answered, and the next one
    // fails with "Message status unknown" until the hub starts it again (seen
    // on webOS 4.4). Retry those; a fresh call relaunches the service.
    var HBC_ATTEMPT_MS = 20000;
    var HBC_ATTEMPTS = 4;
    // A call that never reached the service is always safe to send again. One
    // that timed out may still have run, so it is retried only when the caller
    // says running it twice is harmless.
    function callLost(e, repeatable) {
        if (!e)
            return false;
        if (/^(Message status unknown|Service does not exist)/.test(e.message))
            return true;
        return !!repeatable && e.timedOut === true;
    }
    function hbc(method, params, timeoutMs, repeatable) {
        var attempt = 0;
        function once() {
            attempt++;
            return luna(HBC + '/' + method, params, timeoutMs || HBC_ATTEMPT_MS).catch(function (e) {
                if (attempt < HBC_ATTEMPTS && callLost(e, repeatable))
                    return delay(1000).then(once);
                throw e;
            });
        }
        return once();
    }
    // Keep the service from idling out while the app is open, so a click does
    // not land in the window where it is quitting.
    var KEEPALIVE_MS = 20000;
    setInterval(function () {
        if (isActive())
            luna(HBC + '/checkRoot', {}, HBC_ATTEMPT_MS).catch(function () { });
    }, KEEPALIVE_MS);
    function shq(s) {
        return "'" + String(s).replace(/'/g, "'\\''") + "'";
    }
    function exec(command, quiet, timeoutMs, repeatable) {
        return hbc('exec', { command: command }, timeoutMs, repeatable).then(function (res) {
            if (!quiet) {
                var text = (res.stdoutString || '').trim();
                if (text)
                    log(text);
                var err = (res.stderrString || '').trim();
                if (err)
                    log('stderr: ' + err);
            }
            return res;
        });
    }
    // The installed app's appinfo, which holds its folder and version; it
    // doesn't change while the app runs.
    var appInfoCall = null;
    function appInfo() {
        if (!appInfoCall) {
            appInfoCall = hbc('getAppInfo', { id: APP_ID }, null, true).then(function (res) {
                if (!res.appInfo || !res.appInfo.folderPath)
                    throw new Error('Could not resolve app folder path');
                return res.appInfo;
            });
            // A failed lookup is retried on the next call.
            appInfoCall.catch(function () { appInfoCall = null; });
        }
        return appInfoCall;
    }
    // Read-only actions. Only these are sent again when a reply is lost; the
    // rest (selftest, purge, set and the job starts) get one longer attempt.
    var REPEATABLE_ACTIONS = { status: true, job: true, joblog: true, log: true, get: true };
    function ctl(action, quiet, timeoutMs) {
        var repeatable = REPEATABLE_ACTIONS[action.split(' ')[0]] === true;
        var limit = timeoutMs || (repeatable ? HBC_ATTEMPT_MS : LUNA_TIMEOUT_MS);
        return appInfo().then(function (info) {
            return exec('sh ' + shq(info.folderPath + '/init/nospy-ctl.sh') + ' ' + action, quiet, limit, repeatable);
        });
    }
    var JOB_POLL_MS = 2000;
    // Longer than the script's own cap on one job, which kills a stuck stage.
    var JOB_WAIT_MS = 300000;
    // enable, disable and apply start a background job on the TV and
    // return at once. Wait for it, then print what it logged.
    function waitForJob(deadline) {
        return delay(JOB_POLL_MS).then(function () {
            return ctl('job', true);
        }).then(function (r) {
            var map = parseStatus(r.stdoutString);
            if (map.job === 'running') {
                if (Date.now() > deadline)
                    throw new Error('Still applying after ' + (JOB_WAIT_MS / 1000) + 's; see the log');
                return waitForJob(deadline);
            }
            return ctl('joblog').then(function () {
                if (map.job === 'failed')
                    throw new Error('The change reported a failure; see the log');
            });
        });
    }
    function waitForIdle(deadline) {
        return ctl('job', true).then(function (r) {
            if (parseStatus(r.stdoutString).job !== 'running')
                return null;
            if (Date.now() > deadline)
                throw new Error('Still applying after ' + (JOB_WAIT_MS / 1000) + 's; see the log');
            return delay(JOB_POLL_MS).then(function () {
                return waitForIdle(deadline);
            });
        });
    }
    function job(command) {
        return ctl(command).catch(function (e) {
            // A job is already running, such as one an earlier session of the
            // app started. It does not include this change, so let it finish
            // and then start this one.
            var stderr = e.data && e.data.stderrString;
            if (!stderr || stderr.indexOf('another change is still being applied') < 0)
                throw e;
            log('waiting for the change already being applied');
            return waitForIdle(Date.now() + JOB_WAIT_MS).then(function () {
                return ctl(command);
            });
        }).then(function () {
            return waitForJob(Date.now() + JOB_WAIT_MS);
        });
    }
    function parseStatus(text) {
        var map = {};
        (text || '').split('\n').forEach(function (line) {
            var i = line.indexOf('=');
            if (i > 0)
                map[line.slice(0, i)] = line.slice(i + 1).trim();
        });
        return map;
    }
    return { luna: luna, hbc: hbc, ctl: ctl, job: job, appInfo: appInfo, parseStatus: parseStatus };
};
