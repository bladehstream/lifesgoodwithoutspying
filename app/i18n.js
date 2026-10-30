// UI strings and language selection.
//
// Every translatable element carries a data-i18n key (data-i18n-label for an
// aria-label). index.html marks the static ones and app.js marks the rest
// through setText(), so a language change re-renders the page from those
// keys alone. The log stays in English so bug reports stay readable.
//
// Keep one entry per line: tests/test_i18n.py reads this file to check that
// every key used exists and that each language covers the English set.
'use strict';

(function () {
    var STRINGS = {
        en: {
            'tag.checking': 'checking',
            'tag.rooted': 'rooted',
            'tag.noRoot': 'no root',
            'verdict.checking': 'Checking…',
            'explain.checking': 'Reading the TV\'s state.',
            'verdict.noRoot': 'Needs root',
            'explain.noRoot': 'Install and enable the Homebrew Channel, then reopen this app.',
            'verdict.off': 'Not protected',
            'explain.off': 'This TV can still send viewing, ad, and voice data.',
            'verdict.pending': 'Changes pending',
            'explain.pending': 'Your settings changed. Select "Update protection" to apply them.',
            'verdict.dnsAttention': 'DNS filter needs attention',
            'explain.dnsAttention': 'The DNS filter is on but its handoff is not active. Check the log for the reason.',
            'verdict.dnsIpv4': 'DNS filter active (IPv4 path)',
            'explain.dnsIpv4': 'IPv6 lookups can bypass the filter; turn on "Disable IPv6 with DNS filter" to cover them.',
            'verdict.sdpGrace': 'SDP grace period',
            'explain.sdpGrace': 'Other domain blocks are active. SDP will be blocked after its 60-second grace period.',
            'verdict.domainAttention': 'Domain lists need attention',
            'explain.domainAttention': 'An enabled domain list could not be checked. Review the installation before relying on it.',
            'verdict.statusAttention': 'Selected checks need attention',
            'explain.statusAttention': 'An enabled control appears inactive or a status check is unavailable. Review the self-test.',
            'verdict.protected': 'Selected checks passed',
            'explain.protected': 'These checks cover listed targets only and do not prove complete privacy.',
            'button.enable': 'Enable protection',
            'button.update': 'Update protection',
            'button.disable': 'Disable protection',
            'button.purge': 'Purge now',
            'button.selftest': 'Self-test',
            'button.refresh': 'Refresh',
            'button.showLog': 'Show log',
            'button.hideLog': 'Hide log',
            'button.language': 'Language: {name}',
            'language.auto': 'Auto',
            'readout.domains': 'Domain entries',
            'readout.hosts': 'Domain sink',
            'readout.dns': 'DNS filter',
            'readout.ipv6': 'DNS IPv6 mode',
            'readout.voice': 'Voice services',
            'readout.ads': 'Ad services',
            'value.active': 'active',
            'value.waiting': 'waiting',
            'value.other': 'other',
            'value.off': 'off',
            'value.pending': 'pending',
            'value.unavailable': 'unavailable',
            'value.notManaged': 'not managed',
            'value.disabled': 'disabled',
            'value.preserved': 'preserved',
            'value.stopped': 'not observed',
            'value.running': 'running',
            'heading.protections': 'Protections',
            'heading.log': 'Log',
            'label.logOutput': 'Log output',
            'layer.domains.acr.title': 'ACR / Alphonso',
            'layer.domains.acr.detail': 'Blocks automatic content-recognition uploads',
            'layer.domains.smartad.title': 'SmartAd & ad platform',
            'layer.domains.smartad.detail': 'Blocks ad delivery and tracking',
            'layer.domains.quickset.title': 'QuickSet remote codes',
            'layer.domains.quickset.detail': 'Optional. Blocks remote-code lookup; may affect remote setup',
            'layer.domains.dashboard.title': 'Home dashboard & recs',
            'layer.domains.dashboard.detail': 'Blocks recommendation telemetry',
            'layer.domains.lgrecommends.title': 'LG Content Store',
            'layer.domains.lgrecommends.detail': 'Optional. Blocks the LG Content Store and its app recommendations; the store will not open',
            'layer.domains.wiselg.title': 'Home app sessions',
            'layer.domains.wiselg.detail': 'Optional. Blocks app-usage uploads; may break Home previews, sports and channel info',
            'layer.domains.telemetry.title': 'Telemetry & crash uploads',
            'layer.domains.telemetry.detail': 'Blocks crash and APM phone-home',
            'layer.domains.sdp.title': 'LG SDP & clock sync',
            'layer.domains.sdp.detail': 'Blocks SDP after a 60-second clock-sync grace period; breaks the LG Content Store',
            'layer.clock.ntp.title': 'Clock from NTP',
            'layer.clock.ntp.detail': 'Optional. Sets the time from pool.ntp.org, so SDP is blocked from boot with no grace period',
            'layer.dns.filter.title': 'Local DNS filter',
            'layer.dns.filter.detail': 'Routes ConnMan IPv4 DNS through the local helper; IPv6 is a separate companion choice',
            'layer.dns.disable_ipv6.title': 'Disable IPv6 with DNS filter',
            'layer.dns.disable_ipv6.detail': 'Companion switch; turns ConnMan IPv6 off only while the DNS filter is enabled. If off, IPv6 DNS may bypass the helper.',
            'layer.voice.stop.title': 'Voice services',
            'layer.voice.stop.detail': 'Stops the LG mic, wake-word and voice app (Breaks remote voice key)',
            'layer.ads.stop.title': 'Ad services',
            'layer.ads.stop.detail': 'Stops ad, ACR and telemetry daemons',
            'layer.lan.block.title': 'LAN discovery',
            'layer.lan.block.detail': 'Block LAN discovery. May break casting',
            'layer.domains.thinq.title': 'ThinQ & companion',
            'layer.domains.thinq.detail': 'Optional. Stops ThinQ/Alexa/IoT daemons and breaks the LG ThinQ app',
            'layer.purge.boot.title': 'Purge on boot',
            'layer.purge.boot.detail': 'Clear ACR and voice data at startup',
            'layer.domains.lgchannels.title': 'LG Channels',
            'layer.domains.lgchannels.detail': 'Optional. breaks the LG Channels app',
            'layer.domains.updates.title': 'Firmware updates',
            'layer.domains.updates.detail': 'Optional. Blocks updates and fixes.\nCan be handled by the Homebrew Channel'
        },
        // Russian translation by inchigor (#33).
        ru: {
            'tag.checking': 'проверка',
            'tag.rooted': 'root доступен',
            'tag.noRoot': 'нет root',
            'verdict.checking': 'Проверка…',
            'explain.checking': 'Чтение состояния телевизора.',
            'verdict.noRoot': 'Требуется root',
            'explain.noRoot': 'Установите и включите Homebrew Channel, затем откройте приложение снова.',
            'verdict.off': 'Защита выключена',
            'explain.off': 'Телевизор всё ещё может отправлять данные о просмотрах, рекламе и голосе.',
            'verdict.pending': 'Есть изменения',
            'explain.pending': 'Настройки изменены. Выберите «Обновить защиту», чтобы применить их.',
            'verdict.dnsAttention': 'Проверьте DNS-фильтр',
            'explain.dnsAttention': 'DNS-фильтр включён, но перенаправление не работает. Проверьте журнал.',
            'verdict.dnsIpv4': 'DNS-фильтр активен (IPv4)',
            'explain.dnsIpv4': 'Запросы IPv6 могут обходить фильтр. Для их блокировки включите «Отключить IPv6 с DNS-фильтром».',
            'verdict.sdpGrace': 'Ожидание блокировки SDP',
            'explain.sdpGrace': 'Другие домены блокируются. SDP будет заблокирован через 60 секунд.',
            'verdict.domainAttention': 'Проверьте списки доменов',
            'explain.domainAttention': 'Не удалось проверить включённый список доменов. Проверьте установку.',
            'verdict.statusAttention': 'Проверьте выбранные проверки',
            'explain.statusAttention': 'Включённая защита, возможно, не работает или её состояние недоступно. Запустите самопроверку.',
            'verdict.protected': 'Выбранные проверки пройдены',
            'explain.protected': 'Проверяются только указанные компоненты; полная конфиденциальность не гарантируется.',
            'button.enable': 'Включить защиту',
            'button.update': 'Обновить защиту',
            'button.disable': 'Отключить защиту',
            'button.purge': 'Очистить сейчас',
            'button.selftest': 'Самопроверка',
            'button.refresh': 'Обновить',
            'button.showLog': 'Показать журнал',
            'button.hideLog': 'Скрыть журнал',
            'button.language': 'Язык: {name}',
            'language.auto': 'Авто',
            'readout.domains': 'Домены в списке',
            'readout.hosts': 'Блокировка доменов',
            'readout.dns': 'DNS-фильтр',
            'readout.ipv6': 'Режим DNS IPv6',
            'readout.voice': 'Голосовые службы',
            'readout.ads': 'Рекламные службы',
            'value.active': 'активно',
            'value.waiting': 'ожидание',
            'value.other': 'другая',
            'value.off': 'выкл.',
            'value.pending': 'ожидает',
            'value.unavailable': 'недоступно',
            'value.notManaged': 'не управляется',
            'value.disabled': 'отключён',
            'value.preserved': 'сохранён',
            'value.stopped': 'не обнаружены',
            'value.running': 'работают',
            'heading.protections': 'Защита',
            'heading.log': 'Журнал',
            'label.logOutput': 'Вывод журнала',
            'layer.domains.acr.title': 'ACR / Alphonso',
            'layer.domains.acr.detail': 'Блокирует отправку данных автоматического распознавания контента',
            'layer.domains.smartad.title': 'SmartAd и рекламная платформа',
            'layer.domains.smartad.detail': 'Блокирует доставку рекламы и отслеживание',
            'layer.domains.quickset.title': 'Коды пульта QuickSet',
            'layer.domains.quickset.detail': 'Дополнительно. Блокирует поиск кодов; может помешать настройке пульта',
            'layer.domains.dashboard.title': 'Главный экран и рекомендации',
            'layer.domains.dashboard.detail': 'Блокирует телеметрию рекомендаций',
            'layer.domains.lgrecommends.title': 'LG Content Store',
            'layer.domains.lgrecommends.detail': 'Дополнительно. Блокирует магазин LG и рекомендации; магазин не откроется',
            'layer.domains.wiselg.title': 'Сеансы приложений Home',
            'layer.domains.wiselg.detail': 'Дополнительно. Блокирует отправку данных об использовании; может нарушить превью, спорт и сведения о каналах',
            'layer.domains.telemetry.title': 'Телеметрия и отчёты о сбоях',
            'layer.domains.telemetry.detail': 'Блокирует отправку отчётов о сбоях и данных APM',
            'layer.domains.sdp.title': 'LG SDP и синхронизация времени',
            'layer.domains.sdp.detail': 'Блокирует SDP через 60 секунд после запуска; LG Content Store не будет работать',
            'layer.clock.ntp.title': 'Время через NTP',
            'layer.clock.ntp.detail': 'Дополнительно. Устанавливает время через pool.ntp.org; SDP блокируется сразу после запуска',
            'layer.dns.filter.title': 'Локальный DNS-фильтр',
            'layer.dns.filter.detail': 'Направляет DNS IPv4 ConnMan через локальный фильтр; IPv6 настраивается отдельно',
            'layer.dns.disable_ipv6.title': 'Отключить IPv6 с DNS-фильтром',
            'layer.dns.disable_ipv6.detail': 'Отключает IPv6 ConnMan только при включённом фильтре. Иначе DNS IPv6 может обходить фильтр.',
            'layer.voice.stop.title': 'Голосовые службы',
            'layer.voice.stop.detail': 'Останавливает микрофон LG, пробуждение голосом и голосовое приложение; кнопка голоса не работает',
            'layer.ads.stop.title': 'Рекламные службы',
            'layer.ads.stop.detail': 'Останавливает службы рекламы, ACR и телеметрии',
            'layer.lan.block.title': 'Обнаружение в LAN',
            'layer.lan.block.detail': 'Блокирует обнаружение в локальной сети; трансляция на ТВ может не работать',
            'layer.domains.thinq.title': 'ThinQ и связанные службы',
            'layer.domains.thinq.detail': 'Дополнительно. Останавливает службы ThinQ/Alexa/IoT; приложение LG ThinQ не работает',
            'layer.purge.boot.title': 'Очистка при запуске',
            'layer.purge.boot.detail': 'Удаляет данные ACR и голоса при запуске',
            'layer.domains.lgchannels.title': 'LG Channels',
            'layer.domains.lgchannels.detail': 'Дополнительно. Приложение LG Channels не будет работать',
            'layer.domains.updates.title': 'Обновления прошивки',
            'layer.domains.updates.detail': 'Дополнительно. Блокирует обновления и исправления.\nЭто также можно настроить в Homebrew Channel'
        }
    };
    // Each language names itself, so the switcher stays readable whichever
    // language is showing.
    var NAMES = { en: 'English', ru: 'Русский' };
    var SETTING_KEY = 'nospy-language';
    var SYSTEM_KEY = 'nospy-system-locale';

    function has(obj, key) {
        return Object.prototype.hasOwnProperty.call(obj, key);
    }
    function load(key) {
        try {
            return window.localStorage.getItem(key);
        }
        catch (e) {
            return null;
        }
    }
    function save(key, value) {
        try {
            window.localStorage.setItem(key, value);
        }
        catch (e) { }
    }
    // 'ru-RU', 'ru_RU' and 'ru' all map to 'ru'; anything unsupported is null.
    function supported(tag) {
        var code = String(tag || '').toLowerCase().split(/[-_]/)[0];
        return has(STRINGS, code) ? code : null;
    }

    // 'auto' follows the TV's menu language. The settings service is the
    // authority, but it answers asynchronously, so start from the last answer
    // it gave and let app.js correct it through setSystemLocale().
    var setting = load(SETTING_KEY);
    if (setting !== 'auto' && !(setting && has(STRINGS, setting)))
        setting = 'auto';
    var systemLocale = (window.PalmSystem && window.PalmSystem.locale) ||
        load(SYSTEM_KEY) || navigator.language || '';
    var lang = 'en';

    function resolve() {
        return setting === 'auto' ? (supported(systemLocale) || 'en') : setting;
    }
    // Missing translations fall back to English, so they show untranslated
    // rather than as a raw key.
    function t(key, params) {
        var s = has(STRINGS[lang], key) ? STRINGS[lang][key] :
            (has(STRINGS.en, key) ? STRINGS.en[key] : key);
        if (params) {
            s = s.replace(/\{(\w+)\}/g, function (m, name) {
                return has(params, name) ? params[name] : m;
            });
        }
        return s;
    }
    // A newline in a string becomes a <br>; everything else stays text.
    function fill(el, text) {
        var parts = text.split('\n');
        while (el.firstChild)
            el.removeChild(el.firstChild);
        for (var i = 0; i < parts.length; i++) {
            if (i)
                el.appendChild(document.createElement('br'));
            el.appendChild(document.createTextNode(parts[i]));
        }
    }
    function setText(el, key) {
        if (!el)
            return;
        el.setAttribute('data-i18n', key);
        fill(el, t(key));
    }
    function apply() {
        var i, nodes;
        document.documentElement.lang = lang;
        nodes = document.querySelectorAll('[data-i18n]');
        for (i = 0; i < nodes.length; i++)
            fill(nodes[i], t(nodes[i].getAttribute('data-i18n')));
        nodes = document.querySelectorAll('[data-i18n-label]');
        for (i = 0; i < nodes.length; i++)
            nodes[i].setAttribute('aria-label', t(nodes[i].getAttribute('data-i18n-label')));
        var btn = document.getElementById('btn-language');
        if (btn) {
            btn.textContent = t('button.language', {
                name: setting === 'auto' ? t('language.auto') : NAMES[setting]
            });
        }
    }
    function update() {
        lang = resolve();
        apply();
        // Labels change width, so app.js re-measures its d-pad rows.
        document.dispatchEvent(new Event('nospy-language-change'));
    }
    // Auto, then each language in turn.
    function cycle() {
        var order = ['auto'].concat(Object.keys(STRINGS));
        setting = order[(order.indexOf(setting) + 1) % order.length];
        save(SETTING_KEY, setting);
        update();
    }
    function setSystemLocale(tag) {
        if (!tag)
            return;
        save(SYSTEM_KEY, tag);
        if (tag === systemLocale)
            return;
        systemLocale = tag;
        if (setting === 'auto')
            update();
    }

    lang = resolve();
    apply();
    window.nospyI18n = { t: t, setText: setText, cycle: cycle, setSystemLocale: setSystemLocale };
})();
