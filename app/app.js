// lifesgoodwithoutspying frontend.
'use strict';

(function () {
    var APP_ID = 'ooo.lew.lifesgoodwithoutspying';
    var HBC = 'luna://org.webosbrew.hbchannel.service';
    var appEl = document.getElementById('app');
    var consoleEl = document.getElementById('console');
    var out = document.getElementById('out');
    var logView = document.getElementById('logview');
    var enabled = false;
    var dirty = false;
    var restoreFocus = null;
    var STATUS_POLL_MS = 5000;
    var statusPollTimer = null;
    var lastStatus = null;
    var navigationRowsCache = null;
    var logBtn = document.getElementById('btn-log');
    var i18n = window.nospyI18n;
    var setText = i18n.setText;
    // Cap the retained log; the oldest lines are dropped past this.
    var MAX_LOG_LINES = 2000;
    var logLines = [];
    function errmsg(e) {
        return e instanceof Error ? e.message : String(e);
    }
    function showConsole(show) {
        logView.hidden = !show;
        var layers = document.getElementById('layers');
        if (layers)
            layers.hidden = show;
        invalidateNavigation();
        if (show)
            scrollConsoleToBottom();
        if (logBtn)
            setText(logBtn, show ? 'button.hideLog' : 'button.showLog');
    }
    // One text node per line, trimmed to MAX_LOG_LINES, so the buffer is not
    // re-parsed on every append and cannot grow for the whole session.
    function log(line) {
        if (!line && line !== 0)
            return;
        var stick = consoleAtBottom();
        var t = new Date().toLocaleTimeString();
        var node = document.createTextNode('[' + t + '] ' + line + '\n');
        out.appendChild(node);
        logLines.push(node);
        while (logLines.length > MAX_LOG_LINES) {
            var old = logLines.shift();
            if (old.parentNode)
                old.parentNode.removeChild(old);
        }
        if (stick)
            scrollConsoleToBottom();
    }
    function maxConsoleScroll() {
        return Math.max(0, consoleEl.scrollHeight - consoleEl.clientHeight);
    }
    function consoleAtBottom(slack) {
        if (consoleEl.clientHeight === 0)
            return true;
        return consoleEl.scrollTop >= maxConsoleScroll() - (slack || 8);
    }
    function scrollConsoleToBottom() {
        if (consoleEl.clientHeight === 0)
            return;
        consoleEl.scrollTop = maxConsoleScroll();
    }
    // True when the view actually moved, so a keypress at either end of the
    // buffer can hand focus back to the buttons instead of spinning.
    function scrollConsoleBy(delta) {
        var before = consoleEl.scrollTop;
        consoleEl.scrollTop = before + delta;
        return consoleEl.scrollTop !== before;
    }
    // Arriving at the log parks it on the newest line.
    consoleEl.addEventListener('focus', function () {
        scrollConsoleToBottom();
    });
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
    function callLost(e) {
        return !!e && (e.timedOut === true ||
            /^(Message status unknown|Service does not exist)/.test(e.message));
    }
    function hbc(method, params, timeoutMs) {
        var attempt = 0;
        function once() {
            attempt++;
            return luna(HBC + '/' + method, params, timeoutMs || HBC_ATTEMPT_MS).catch(function (e) {
                if (attempt < HBC_ATTEMPTS && callLost(e))
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
        if (appIsActive())
            luna(HBC + '/checkRoot', {}, HBC_ATTEMPT_MS).catch(function () { });
    }, KEEPALIVE_MS);
    function shq(s) {
        return "'" + String(s).replace(/'/g, "'\\''") + "'";
    }
    function exec(command, quiet, timeoutMs) {
        return hbc('exec', { command: command }, timeoutMs).then(function (res) {
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
    // The folder of an installed app does not move while it runs.
    var folderPath = null;
    function getFolder() {
        if (folderPath)
            return Promise.resolve(folderPath);
        return hbc('getAppInfo', { id: APP_ID }).then(function (res) {
            if (!res.appInfo || !res.appInfo.folderPath) {
                throw new Error('Could not resolve app folder path');
            }
            folderPath = res.appInfo.folderPath;
            return folderPath;
        });
    }
    function ctl(action, quiet, timeoutMs) {
        return getFolder().then(function (dir) {
            return exec('sh ' + shq(dir + '/init/nospy-ctl.sh') + ' ' + action, quiet, timeoutMs);
        });
    }
    var JOB_POLL_MS = 2000;
    // Longer than the script's own cap on one job, which kills a stuck stage.
    var JOB_WAIT_MS = 300000;
    function showApplying() {
        setText(document.getElementById('verdict'), 'verdict.applying');
        setText(document.getElementById('explain'), 'explain.applying');
    }
    // enable, disable and apply start a background job on the TV and
    // return at once. Wait for it, then print what it logged.
    function waitForJob(deadline) {
        return delay(JOB_POLL_MS).then(function () {
            return ctl('status', true);
        }).then(function (r) {
            var map = parseStatus(r.stdoutString);
            if (map.job === 'running') {
                if (Date.now() > deadline)
                    throw new Error('Still applying after ' + (JOB_WAIT_MS / 1000) + 's; see "Show log"');
                return waitForJob(deadline);
            }
            return ctl('joblog').then(function () {
                if (map.job === 'failed')
                    throw new Error('The change reported a failure; see the log');
            });
        });
    }
    function job(command) {
        showApplying();
        return ctl(command).catch(function (e) {
            // A retried call can find the job its lost first attempt started.
            var stderr = e.data && e.data.stderrString;
            if (stderr && stderr.indexOf('another change is still being applied') >= 0)
                return null;
            throw e;
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
    function toArray(list) {
        var arr = [];
        for (var i = 0; i < list.length; i++)
            arr.push(list[i]);
        return arr;
    }
    function toggleButtons() {
        return toArray(document.querySelectorAll('.layer[data-key]'));
    }
    function renderToggles(map) {
        toggleButtons().forEach(function (btn) {
            var key = btn.getAttribute('data-key');
            var on = !!key && map[key] === 'on';
            btn.classList.toggle('on', on);
            btn.setAttribute('aria-checked', on ? 'true' : 'false');
        });
    }
    function updateMainButton() {
        var b = document.getElementById('btn-main');
        if (!b)
            return;
        b.classList.remove('pending', 'danger');
        if (!enabled) {
            setText(b, 'button.enable');
        }
        else if (dirty) {
            setText(b, 'button.update');
            b.classList.add('pending');
        }
        else {
            setText(b, 'button.disable');
            b.classList.add('danger');
        }
    }
    function setTag(key, cls) {
        var tag = document.getElementById('dev-root');
        setText(tag, key);
        tag.className = 'tag' + (cls ? ' ' + cls : '');
    }
    function renderState(map, isRoot) {
        enabled = map.autostart === 'on';
        document.getElementById('r-domains').textContent = map.blocklist || '—';
        setText(document.getElementById('r-hosts'),
            map.hosts === 'ours' ? 'value.active' :
            (map.hosts === 'waiting' ? 'value.waiting' :
            (map.hosts === 'external' ? 'value.other' : 'value.off')));
        var dnsRuntime = map.dns_filter || 'unavailable';
        var dnsEnabled = map['dns.filter'] === 'on';
        var dnsIpv6Disabled = map['dns.disable_ipv6'] === 'on';
        setText(document.getElementById('r-dns'),
            dnsEnabled ?
                (dnsRuntime === 'yes' ? 'value.active' :
                    (dnsRuntime === 'no' ? 'value.pending' : 'value.unavailable')) : 'value.off');
        setText(document.getElementById('r-ipv6'),
            !dnsEnabled ? 'value.notManaged' : (dnsIpv6Disabled ? 'value.disabled' : 'value.preserved'));
        setText(document.getElementById('r-voice'), map.voice === 'stopped' ? 'value.stopped' : 'value.running');
        setText(document.getElementById('r-ads'), map.ads === 'stopped' ? 'value.stopped' : 'value.running');
        var verdict = document.getElementById('verdict');
        var explain = document.getElementById('explain');
        verdict.classList.remove('is-secure', 'is-warn', 'is-danger');
        appEl.classList.remove('secured', 'pending');
        if (isRoot === null) {
            // No answer is not the same as "not rooted": the Homebrew Channel
            // service may be restarting.
            setTag('tag.noAnswer', 'bad');
            setText(verdict, 'verdict.noAnswer');
            setText(explain, 'explain.noAnswer');
            verdict.classList.add('is-warn');
        }
        else if (!isRoot) {
            setTag('tag.noRoot', 'bad');
            setText(verdict, 'verdict.noRoot');
            setText(explain, 'explain.noRoot');
            verdict.classList.add('is-danger');
        }
        else {
            setTag('tag.rooted', 'ok');
            if (map.job === 'running') {
                // Left running by an earlier session of the app; the poll
                // above picks up the result.
                setText(verdict, 'verdict.applying');
                setText(explain, 'explain.jobRunning');
                verdict.classList.add('is-warn');
            }
            else if (!enabled) {
                setText(verdict, 'verdict.off');
                setText(explain, 'explain.off');
                verdict.classList.add('is-danger');
            }
            else if (dirty) {
                setText(verdict, 'verdict.pending');
                setText(explain, 'explain.pending');
                verdict.classList.add('is-warn');
                appEl.classList.add('secured', 'pending');
            }
            else if (map['dns.filter'] === 'on' && map.dns_filter !== 'yes') {
                setText(verdict, 'verdict.dnsAttention');
                setText(explain, 'explain.dnsAttention');
                verdict.classList.add('is-warn');
                appEl.classList.add('secured', 'pending');
            }
            else if (map['dns.filter'] === 'on' && map['dns.disable_ipv6'] === 'off') {
                setText(verdict, 'verdict.dnsIpv4');
                setText(explain, 'explain.dnsIpv4');
                verdict.classList.add('is-warn');
                appEl.classList.add('secured', 'pending');
            }
            else if (map.hosts === 'waiting') {
                setText(verdict, 'verdict.sdpGrace');
                setText(explain, 'explain.sdpGrace');
                verdict.classList.add('is-warn');
                appEl.classList.add('secured', 'pending');
            }
            else {
                setText(verdict, 'verdict.protected');
                setText(explain, 'explain.protected');
                verdict.classList.add('is-secure');
                appEl.classList.add('secured');
            }
        }
        updateMainButton();
        invalidateNavigation();
    }
    // The SDP worker changes the host state asynchronously. Status is not a
    // free call (the helper inspects the process table), so poll only while an
    // active app is actually showing that grace-period state.
    function appIsActive() {
        if (document.hidden === true || document.webkitHidden === true ||
            document.visibilityState === 'hidden')
            return false;
        return true;
    }
    function stopStatusPolling() {
        if (statusPollTimer !== null) {
            clearTimeout(statusPollTimer);
            statusPollTimer = null;
        }
    }
    function scheduleStatusPolling() {
        stopStatusPolling();
        if (!appIsActive() || !lastStatus ||
            (lastStatus.hosts !== 'waiting' && lastStatus.job !== 'running'))
            return;
        statusPollTimer = setTimeout(function () {
            statusPollTimer = null;
            if (appIsActive())
                refresh({ quiet: true });
        }, STATUS_POLL_MS);
    }
    function refresh(options) {
        var quiet = !!(options && options.quiet);
        stopStatusPolling();
        return hbc('checkRoot', {}).then(function () {
            return true;
        }, function (e) {
            // Only a plain returnValue:false answer means "not root".
            if (e.data && e.data.returnValue === false && !e.data.errorText)
                return false;
            throw e;
        }).then(function (isRoot) {
            if (!isRoot) {
                lastStatus = null;
                renderState({}, false);
                return null;
            }
            return ctl('status', quiet).then(function (r) {
                var map = parseStatus(r.stdoutString);
                lastStatus = map;
                dirty = map.changes === 'pending';
                renderToggles(map);
                renderState(map, true);
                return null;
            });
        }).catch(function (e) {
            // A quiet poll keeps the last state visible and retries; a manual
            // refresh retains the existing error state and log behavior.
            if (!quiet) {
                lastStatus = null;
                renderState({}, null);
                log('status: ' + errmsg(e));
            }
            return null;
        }).then(function (result) {
            scheduleStatusPolling();
            return result;
        });
    }
    function allButtons() {
        return toArray(document.querySelectorAll('button'));
    }
    // lock the ui while something runs, then put focus back
    function busy(on) {
        if (on) {
            stopStatusPolling();
            restoreFocus = document.activeElement;
        }
        allButtons().forEach(function (b) { b.disabled = on; });
        invalidateNavigation();
        if (!on) {
            var target = document.getElementById('btn-main');
            if (restoreFocus instanceof HTMLButtonElement &&
                restoreFocus.offsetParent !== null && !restoreFocus.disabled) {
                target = restoreFocus;
            }
            if (target)
                target.focus();
            restoreFocus = null;
            scheduleStatusPolling();
        }
    }
    // run the passed function, refresh after
    function run(label, fn, then) {
        busy(true);
        log('> ' + label);
        return Promise.resolve()
            .then(fn)
            .then(then)
            .catch(function (e) {
                log('! ' + errmsg(e));
                showConsole(true);
                // A failed job may still have changed the TV; show what it left.
                return refresh();
            })
            .then(function () { busy(false); });
    }
    toggleButtons().forEach(function (btn) {
        btn.addEventListener('click', function () {
            var key = btn.getAttribute('data-key');
            if (!key)
                return;
            var next = btn.classList.contains('on') ? 'off' : 'on';
            // set only saves the key; "Update protection" (or Enable) applies
            // every change at once. A status call costs seconds, so update the
            // view from the last known state instead.
            run(key + ' = ' + next, function () {
                return ctl('set ' + key + ' ' + next, true);
            }, function () {
                if (enabled)
                    dirty = true;
                if (!lastStatus)
                    return refresh();
                lastStatus[key] = next;
                renderToggles(lastStatus);
                renderState(lastStatus, true);
            });
        });
    });
    document.getElementById('btn-main').addEventListener('click', function () {
        if (!enabled) {
            run('Enable protection', function () { return job('enable'); }, function () {
                dirty = false;
                return refresh();
            });
        }
        else if (dirty) {
            run('Update protection', function () { return job('apply'); }, function () {
                dirty = false;
                return refresh();
            });
        }
        else {
            run('Disable protection', function () { return job('disable'); }, function () {
                dirty = false;
                return refresh();
            });
        }
    });
    document.getElementById('btn-purge').addEventListener('click', function () {
        run('Purge ACR and voice residue', function () { return ctl('purge'); }, refresh);
    });
    document.getElementById('btn-selftest').addEventListener('click', function () {
        showConsole(true);
        // Its resolver and curl probes can take a while on a slow TV.
        run('Self-test', function () { return ctl('selftest', false, LUNA_TIMEOUT_MS); });
    });
    document.getElementById('btn-refresh').addEventListener('click', function () {
        run('Refresh', refresh);
    });
    logBtn.addEventListener('click', function () {
        showConsole(logView.hidden);
    });
    document.getElementById('btn-language').addEventListener('click', function () {
        i18n.cycle();
    });
    // d-pad navigation
    function invalidateNavigation() {
        navigationRowsCache = null;
    }
    function focusables() {
        return toArray(document.querySelectorAll('button:not([disabled]), #console'))
            .filter(function (el) { return el.offsetParent !== null; });
    }
    function focusElement(el) {
        if (!el)
            return;
        try {
            el.focus({ preventScroll: true });
        }
        catch (_error) {
            el.focus();
        }
        // The layers list scrolls itself; anything else goes through
        // scrollIntoView below.
        var scroller = document.querySelector('.layers');
        if (scroller && scroller.contains(el)) {
            var top = el.__nospyNavTop;
            var bottom = el.__nospyNavBottom;
            if (typeof top === 'number' && typeof bottom === 'number') {
                var viewportHeight = scroller.__nospyNavViewportHeight || scroller.clientHeight;
                var currentTop = scroller.scrollTop;
                if (top < currentTop)
                    scroller.scrollTop = top;
                else if (bottom > currentTop + viewportHeight)
                    scroller.scrollTop = bottom - viewportHeight;
            }
            else {
                var item = el.getBoundingClientRect();
                var view = scroller.getBoundingClientRect();
                if (item.top < view.top)
                    scroller.scrollTop -= view.top - item.top;
                else if (item.bottom > view.bottom)
                    scroller.scrollTop += item.bottom - view.bottom;
            }
        }
        else if (el.scrollIntoViewIfNeeded) {
            // Chromium before 61 reads scrollIntoView's options object as true
            // and aligns to the top; this non-standard call scrolls minimally
            // on every Chromium build.
            el.scrollIntoViewIfNeeded(false);
        }
        else if (el.scrollIntoView) {
            el.scrollIntoView({ block: 'nearest' });
        }
    }
    function centerX(el) {
        if (typeof el.__nospyNavCenterX === 'number')
            return el.__nospyNavCenterX;
        var r = el.getBoundingClientRect();
        return r.left + r.width / 2;
    }
    // Group buttons into rows once per layout change. Remote navigation then
    // avoids measuring every button on every key repeat.
    function layoutRows() {
        if (navigationRowsCache !== null)
            return navigationRowsCache;
        var rows = [];
        var scroller = document.querySelector('.layers');
        var scrollerRect = scroller ? scroller.getBoundingClientRect() : null;
        var scrollTop = scroller ? scroller.scrollTop : 0;
        if (scroller)
            scroller.__nospyNavViewportHeight = scroller.clientHeight;
        focusables().forEach(function (el) {
            var r = el.getBoundingClientRect();
            if (scrollerRect) {
                el.__nospyNavTop = r.top - scrollerRect.top + scrollTop;
                el.__nospyNavBottom = el.__nospyNavTop + r.height;
            }
            el.__nospyNavCenterX = r.left + r.width / 2;
            var cy = r.top + r.height / 2;
            var row = null;
            for (var i = 0; i < rows.length; i++) {
                if (Math.abs(rows[i].cy - cy) < Math.max(r.height, rows[i].h) / 2) {
                    row = rows[i];
                    break;
                }
            }
            if (row) {
                row.items.push(el);
            }
            else {
                rows.push({ cy: cy, h: r.height, items: [el] });
            }
        });
        rows.sort(function (a, b) { return a.cy - b.cy; });
        rows.forEach(function (row) {
            row.items.sort(function (a, b) {
                return a.__nospyNavCenterX - b.__nospyNavCenterX;
            });
        });
        navigationRowsCache = rows;
        return rows;
    }
    function locate(rows, el) {
        if (!el)
            return null;
        for (var i = 0; i < rows.length; i++) {
            for (var j = 0; j < rows[i].items.length; j++) {
                if (rows[i].items[j] === el)
                    return { row: i, col: j };
            }
        }
        return null;
    }
    function moveFocus(dir) {
        var rows = layoutRows();
        if (!rows.length)
            return;
        var pos = locate(rows, document.activeElement);
        if (!pos) {
            focusElement(rows[0].items[0]);
            return;
        }
        var row = rows[pos.row];
        if (dir === 'left') {
            if (pos.col > 0)
                focusElement(row.items[pos.col - 1]);
            return;
        }
        if (dir === 'right') {
            if (pos.col < row.items.length - 1)
                focusElement(row.items[pos.col + 1]);
            return;
        }
        var targetRow = rows[pos.row + (dir === 'down' ? 1 : -1)];
        if (!targetRow)
            return;
        // single button row goes to the start of the next row
        if (row.items.length === 1 || targetRow.items.length === 1) {
            focusElement(targetRow.items[0]);
            return;
        }
        var active = document.activeElement;
        var cx = active ? centerX(active) : 0;
        var best = targetRow.items[0];
        var bestDist = Infinity;
        targetRow.items.forEach(function (el) {
            var d = Math.abs(centerX(el) - cx);
            if (d < bestDist) {
                bestDist = d;
                best = el;
            }
        });
        focusElement(best);
    }
    // While the log holds focus the d-pad scrolls it instead of walking the
    // button grid. The rocker reaches us as plain arrow keys on webOS builds
    // where the Magic Remote's wheel is not forwarded to the app.
    function consoleNav(dir) {
        // The log wraps, so the horizontal axis is free to be the way out, and
        // the toolbar toggle doubles as the escape once it relabels itself.
        if (dir === 'left' || dir === 'right') {
            focusElement(logBtn);
            return;
        }
        // Page by four fifths of the view so pages share some context.
        var step = Math.max(40, Math.round(consoleEl.clientHeight * 0.8));
        if (dir === 'down') {
            scrollConsoleBy(step);
            return;
        }
        if (scrollConsoleBy(-step) || consoleEl.scrollTop > 0)
            return;
        focusElement(logBtn);
    }
    window.addEventListener('resize', invalidateNavigation, true);
    document.addEventListener('nospy-language-change', invalidateNavigation);
    var KEY_DIR = { 37: 'left', 38: 'up', 39: 'right', 40: 'down' };
    document.addEventListener('keydown', function (e) {
        var dir = KEY_DIR[e.keyCode];
        if (dir) {
            e.preventDefault();
            if (document.activeElement === consoleEl) {
                consoleNav(dir);
                return;
            }
            moveFocus(dir);
            return;
        }
        if (e.keyCode === 13 || e.keyCode === 32) {
            var el = document.activeElement;
            if (el && el.tagName === 'BUTTON') {
                e.preventDefault();
                el.click();
            }
        }
    }, true);
    // webOS 5-era WebKit uses webkitvisibilitychange; newer engines use the
    // standard event. Stop background work when hidden and re-check on resume.
    function visibilityChanged() {
        if (appIsActive()) {
            stopStatusPolling();
            refresh({ quiet: true });
        }
        else {
            stopStatusPolling();
        }
    }
    var visibilityEvent = typeof document.hidden !== 'undefined' ? 'visibilitychange' :
        (typeof document.webkitHidden !== 'undefined' ? 'webkitvisibilitychange' : 'visibilitychange');
    document.addEventListener(visibilityEvent, visibilityChanged, true);
    document.addEventListener('webOSRelaunch', function () {
        // webOSRelaunch can arrive just before document.hidden is cleared.
        stopStatusPolling();
        refresh({ quiet: true });
    }, true);
    // The menu language lives in the settings service; navigator.language in
    // the web runtime does not always follow it.
    luna('luna://com.webos.settingsservice/getSystemSettings', { keys: ['localeInfo'] }).then(function (res) {
        var info = res && res.settings && res.settings.localeInfo;
        i18n.setSystemLocale(info && info.locales && info.locales.UI);
    }).catch(function () { });
    refresh();
    var main = document.getElementById('btn-main');
    if (main)
        main.focus();
})();
