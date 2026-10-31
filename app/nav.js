// Remote navigation. The page is four zones: hero actions, the rail, the
// selected pane and the footer. Arrows move spatially inside a zone and
// between zones by fixed rules, so the rail and the pane never trade focus
// by accident.
'use strict';

window.nospyNav = function (consoleEl) {
    function visible(el) {
        return el.offsetParent !== null;
    }
    function focusables(zone) {
        var sel = {
            hero: '#hero button:not([disabled])',
            rail: '.rail button:not([disabled])',
            pane: '.pane:not([hidden]) button:not([disabled]), .pane:not([hidden]) #console',
            footer: '.tools button:not([disabled])'
        }[zone];
        return Array.prototype.filter.call(document.querySelectorAll(sel), visible);
    }
    function zoneOf(el) {
        if (!el || !el.closest)
            return null;
        if (el.closest('#hero'))
            return 'hero';
        if (el.closest('.rail'))
            return 'rail';
        if (el.closest('.pane'))
            return 'pane';
        if (el.closest('.tools'))
            return 'footer';
        return null;
    }
    function selectedRail() {
        return document.querySelector('.rail .sel');
    }
    function defaultFocus() {
        return focusables('hero')[0] || selectedRail();
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
        if (el.scrollIntoViewIfNeeded) {
            // Chromium before 61 reads scrollIntoView's options object as true
            // and aligns to the top; this non-standard call scrolls minimally
            // on every Chromium build.
            el.scrollIntoViewIfNeeded(false);
        }
        else if (el.scrollIntoView) {
            el.scrollIntoView({ block: 'nearest' });
        }
    }
    // The nearest element in a direction. One that overlaps the current one
    // across the direction of travel wins over one that doesn't.
    function nearest(from, dir, list) {
        var r = from.getBoundingClientRect();
        var best = null, bestScore = Infinity, bestOverlap = false;
        list.forEach(function (el) {
            if (el === from)
                return;
            var q = el.getBoundingClientRect(), along, across, overlap;
            if (dir === 'up' || dir === 'down') {
                along = dir === 'down' ? q.top - r.bottom : r.top - q.bottom;
                if (along < -r.height / 2)
                    return;
                overlap = q.left < r.right && q.right > r.left;
                across = overlap ? 0 : Math.min(Math.abs(q.left - r.right), Math.abs(r.left - q.right));
            }
            else {
                along = dir === 'right' ? q.left - r.right : r.left - q.right;
                if (along < -r.width / 2)
                    return;
                overlap = q.top < r.bottom && q.bottom > r.top;
                across = overlap ? 0 : Math.min(Math.abs(q.top - r.bottom), Math.abs(r.top - q.bottom));
            }
            var score = Math.max(along, 0) + across * 2;
            if ((overlap && !bestOverlap) || (overlap === bestOverlap && score < bestScore)) {
                best = el;
                bestScore = score;
                bestOverlap = overlap;
            }
        });
        return best;
    }
    var LEAVE = {
        hero: { down: function () { return selectedRail(); } },
        rail: {
            up: function () { return focusables('hero')[0]; },
            down: function () { return focusables('footer')[0]; },
            right: function (from) { return nearest(from, 'right', focusables('pane')); }
        },
        pane: {
            up: defaultFocus,
            down: function () { return focusables('footer')[0]; },
            left: function () { return selectedRail(); }
        },
        footer: { up: function (from) { return nearest(from, 'up', focusables('pane')) || selectedRail(); } }
    };
    function moveFocus(dir) {
        var cur = document.activeElement, zone = zoneOf(cur);
        if (!zone) {
            focusElement(defaultFocus());
            return;
        }
        var next = nearest(cur, dir, focusables(zone));
        if (!next && LEAVE[zone][dir])
            next = LEAVE[zone][dir](cur);
        if (next)
            focusElement(next);
    }
    // True when the log actually scrolled, so a keypress at either end can
    // hand focus on instead of spinning.
    function scrollConsoleBy(delta) {
        var before = consoleEl.scrollTop;
        consoleEl.scrollTop = before + delta;
        return consoleEl.scrollTop !== before;
    }
    // While the log holds focus the d-pad scrolls it instead of moving focus.
    // The rocker reaches us as plain arrow keys on webOS builds where the
    // Magic Remote's wheel is not forwarded to the app.
    function consoleNav(dir) {
        // The log wraps, so the horizontal axis is free to be the way out.
        if (dir === 'left' || dir === 'right') {
            focusElement(selectedRail());
            return;
        }
        // Page by four fifths of the view so pages share some context.
        var step = Math.max(40, Math.round(consoleEl.clientHeight * 0.8));
        if (dir === 'down') {
            if (!scrollConsoleBy(step))
                focusElement(focusables('footer')[0]);
            return;
        }
        if (scrollConsoleBy(-step) || consoleEl.scrollTop > 0)
            return;
        focusElement(defaultFocus());
    }
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
    return { focus: focusElement, defaultFocus: defaultFocus, zoneOf: zoneOf, selectedRail: selectedRail };
};
