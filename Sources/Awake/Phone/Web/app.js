// Awake's phone app. One page, no framework, no build step.
//
// Everything shown comes from the Mac's API and is put on the page with
// textContent, never as HTML: agent prompts, log lines and device names
// are text from elsewhere.
(function () {
  'use strict';

  var TOKEN_KEY = 'awake.token';
  var NAME_KEY = 'awake.deviceName';

  // ----- Pure helpers (also exported for tests under Node) -----

  function formatRemaining(seconds) {
    if (seconds == null || isNaN(seconds)) return '—';
    seconds = Math.max(0, Math.floor(seconds));
    var d = Math.floor(seconds / 86400);
    var h = Math.floor((seconds % 86400) / 3600);
    var m = Math.floor((seconds % 3600) / 60);
    var s = seconds % 60;
    function two(n) { return n < 10 ? '0' + n : '' + n; }
    if (d > 0) return d + 'd ' + two(h) + ':' + two(m);
    if (h > 0) return h + ':' + two(m) + ':' + two(s);
    return m + ':' + two(s);
  }

  function formatMinutes(minutes) {
    if (minutes < 60) return minutes + ' m';
    if (minutes % 1440 === 0) return (minutes / 1440) + ' d';
    if (minutes % 60 === 0) return (minutes / 60) + ' h';
    return Math.floor(minutes / 60) + ' h ' + (minutes % 60) + ' m';
  }

  function formatAge(seconds) {
    if (seconds == null || isNaN(seconds)) return 'unknown';
    seconds = Math.max(0, Math.floor(seconds));
    if (seconds < 60) return seconds + ' s';
    if (seconds < 3600) return Math.floor(seconds / 60) + ' min';
    if (seconds < 86400) return Math.floor(seconds / 3600) + ' h ' + Math.floor((seconds % 3600) / 60) + ' min';
    return Math.floor(seconds / 86400) + ' d';
  }

  function formatBytes(bytes) {
    if (bytes == null || isNaN(bytes)) return 'unknown';
    var gb = bytes / 1e9;
    if (gb >= 10) return Math.round(gb) + ' GB';
    if (gb >= 1) return gb.toFixed(1) + ' GB';
    return Math.round(bytes / 1e6) + ' MB';
  }

  // How much of the ring is left: remaining over the session's length.
  function ringFraction(status, nowMs) {
    if (!status || !status.active || !status.endsAt || !status.startedAt) return 0;
    var start = Date.parse(status.startedAt);
    var end = Date.parse(status.endsAt);
    if (!(end > start)) return 0;
    return Math.min(1, Math.max(0, (end - nowMs) / (end - start)));
  }

  var STATE_LABELS = {
    alive: 'alive',
    busy: 'busy',
    idle: 'idle',
    waitingForInput: 'waiting for you',
    stalled: 'stalled',
    exited: 'exited'
  };

  function stateLabel(state) {
    return STATE_LABELS[state] || String(state || 'unknown');
  }

  // Reconnect waits: 1, 2, 4, 8, 16, then 30 seconds.
  function backoffSeconds(attempt) {
    return Math.min(30, Math.pow(2, Math.max(0, attempt)));
  }

  // Feeds text from the event stream; calls onEvent(name, data) per event.
  function EventParser(onEvent) {
    this.buffer = '';
    this.onEvent = onEvent;
  }
  EventParser.prototype.push = function (text) {
    this.buffer += text.replace(/\r\n/g, '\n');
    var cut;
    while ((cut = this.buffer.indexOf('\n\n')) >= 0) {
      var block = this.buffer.slice(0, cut);
      this.buffer = this.buffer.slice(cut + 2);
      var name = 'message';
      var data = [];
      var lines = block.split('\n');
      for (var i = 0; i < lines.length; i++) {
        var line = lines[i];
        if (line === '' || line.charAt(0) === ':') continue;
        var colon = line.indexOf(':');
        var field = colon < 0 ? line : line.slice(0, colon);
        var value = colon < 0 ? '' : line.slice(colon + 1).replace(/^ /, '');
        if (field === 'event') name = value;
        else if (field === 'data') data.push(value);
      }
      if (data.length) this.onEvent(name, data.join('\n'));
      else if (block.charAt(0) === ':') this.onEvent('keepalive', '');
    }
  };

  function guessDeviceName(userAgent) {
    if (/iPhone/.test(userAgent)) return 'iPhone';
    if (/iPad/.test(userAgent)) return 'iPad';
    if (/Android/.test(userAgent)) return 'Android phone';
    if (/Macintosh/.test(userAgent)) return 'Mac browser';
    return 'Browser';
  }

  function pairingCodeFromHash(hash) {
    var match = /[#&]pair=(\d{6})\b/.exec(hash || '');
    return match ? match[1] : null;
  }

  function base64UrlToBytes(text) {
    var padded = text.replace(/-/g, '+').replace(/_/g, '/');
    while (padded.length % 4) padded += '=';
    var raw = atob(padded);
    var bytes = new Uint8Array(raw.length);
    for (var i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
    return bytes;
  }

  // The lid in words, for the Session tab (status.json) and the Machine
  // tab: a lid that cannot be read is "unknown", never "open".
  function lidText(closed, onDesk, known) {
    if (known === false || closed == null) return 'unknown';
    return closed ? (onDesk ? 'closed, external display' : 'closed') : 'open';
  }

  // The Session tab's power line as [label, text, tone], or null for no
  // line. A Mac with no battery is on mains: never "on battery".
  function sessionPowerFact(status) {
    if (status.hasBattery === false) return ['Power', 'mains (no battery)', null];
    // No reading (a failed read): the Machine tab says so.
    if (status.batteryPercent == null) return null;
    var battery = status.batteryPercent + '%';
    if (status.chargerDraining) return ['Battery', battery + ', charger too weak', 'warn'];
    return ['Battery', battery + (status.isCharging ? ', on power' : ', on battery'), !status.isCharging && status.batteryPercent < 20 ? 'bad' : null];
  }

  // The Machine tab's battery, trend and charger lines, each as
  // [label, text, tone]. A Mac with no battery has one "no battery" line
  // and one "mains" line: no trend, and no charger "not connected".
  function machinePowerFacts(m) {
    var noBattery = m.hasBattery === false || (m.hasBattery == null && m.batteryPercent == null && m.isCharging == null);
    if (noBattery) return [['Battery', 'no battery', null], ['Power', 'mains', null]];
    var facts = [['Battery', m.batteryPercent == null ? 'unknown' : m.batteryPercent + '%', m.batteryPercent != null && m.batteryPercent < 20 && !m.isCharging ? 'bad' : null]];
    if (m.batteryWatts != null) {
      var w = Math.abs(m.batteryWatts).toFixed(1) + ' W';
      facts.push(['Trend', m.batteryWatts < -0.05 ? 'draining ' + w : m.batteryWatts > 0.05 ? 'charging ' + w : 'steady', m.batteryWatts < -0.05 && m.isCharging ? 'warn' : null]);
    } else {
      facts.push(['Trend', 'unknown', null]);
    }
    var charger = m.isCharging == null ? 'unknown' : m.isCharging ? 'connected' : 'not connected';
    if (m.isCharging && m.adapterWatts) charger += ', ' + m.adapterWatts + ' W';
    if (m.chargerDraining) charger += ', too weak for the load';
    facts.push(['Charger', charger, m.chargerDraining ? 'warn' : null]);
    return facts;
  }

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = {
      formatRemaining: formatRemaining, formatMinutes: formatMinutes, formatAge: formatAge, formatBytes: formatBytes,
      ringFraction: ringFraction, stateLabel: stateLabel, backoffSeconds: backoffSeconds, EventParser: EventParser,
      lidText: lidText, sessionPowerFact: sessionPowerFact, machinePowerFacts: machinePowerFacts,
      guessDeviceName: guessDeviceName, pairingCodeFromHash: pairingCodeFromHash, base64UrlToBytes: base64UrlToBytes
    };
    return;
  }

  // ----- State -----

  var token = null;
  try { token = localStorage.getItem(TOKEN_KEY); } catch (error) { token = null; }
  var state = { status: null, server: null };
  var clockOffset = 0;          // Mac's clock minus this phone's, in ms
  var currentTab = 'session';
  var stream = { controller: null, attempt: 0, timer: null, lastHeard: 0, connected: false, retryAt: 0 };
  var timers = { machine: null, shot: null, log: null, poll: null };
  var shotUrl = null;
  var busy = {};

  function $(id) { return document.getElementById(id); }

  function el(tag, className, text) {
    var node = document.createElement(tag);
    if (className) node.className = className;
    if (text != null) node.textContent = text;
    return node;
  }

  function clear(node) { while (node.firstChild) node.removeChild(node.firstChild); }

  function macNow() { return Date.now() + clockOffset; }

  // ----- Toast, sheet -----

  var toastTimer = null;
  function toast(message, bad) {
    var node = $('toast');
    node.textContent = message;
    node.className = bad ? 'toast bad' : 'toast';
    node.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { node.hidden = true; }, bad ? 6000 : 3000);
  }

  // A bottom sheet that asks before anything is done. Resolves with true
  // (or the typed text when `input` is set), or null when cancelled.
  function ask(options) {
    return new Promise(function (resolve) {
      var sheet = $('sheet');
      var input = $('sheet-input');
      var ok = $('sheet-ok');
      $('sheet-title').textContent = options.title;
      $('sheet-body').textContent = options.body || '';
      ok.textContent = options.ok || 'OK';
      ok.className = options.danger ? 'big danger' : 'big primary';
      input.hidden = !options.input;
      input.value = '';
      input.placeholder = options.placeholder || '';
      sheet.hidden = false;
      if (options.input) input.focus();
      function done(value) {
        sheet.hidden = true;
        ok.onclick = null;
        $('sheet-cancel').onclick = null;
        sheet.onclick = null;
        resolve(value);
      }
      ok.onclick = function () {
        if (options.input) {
          if (!input.value) { input.focus(); return; }
          done(input.value);
        } else {
          done(true);
        }
      };
      $('sheet-cancel').onclick = function () { done(null); };
      sheet.onclick = function (event) { if (event.target === sheet) done(null); };
    });
  }

  // ----- API -----

  function unpaired() {
    token = null;
    try { localStorage.removeItem(TOKEN_KEY); } catch (error) { /* private mode */ }
    stopStream();
    stopTimers();
    showPairing();
  }

  // Calls the Mac. Resolves with {ok, status, data}; never rejects.
  function api(method, path, body, raw) {
    var headers = {};
    if (token) headers.Authorization = 'Bearer ' + token;
    var options = { method: method, headers: headers, cache: 'no-store' };
    if (method === 'POST') {
      headers['Content-Type'] = 'application/json';
      options.body = JSON.stringify(body || {});
    }
    return fetch(path, options).then(function (response) {
      if (response.status === 401 && path !== '/api/pair') {
        unpaired();
        return { ok: false, status: 401, data: { error: 'This phone is no longer paired.' } };
      }
      if (raw && response.ok) {
        return response.blob().then(function (blob) { return { ok: true, status: response.status, blob: blob }; });
      }
      return response.json().catch(function () { return {}; }).then(function (data) {
        return { ok: response.ok, status: response.status, data: data };
      });
    }).catch(function () {
      return { ok: false, status: 0, data: { error: "Can't reach the Mac." } };
    });
  }

  function problem(result) {
    if (result.status === 429) return 'Too many requests. Wait a few seconds.';
    return (result.data && result.data.error) || 'That did not work (' + result.status + ').';
  }

  // Runs one action; one at a time per key, so a double tap sends once.
  function act(key, method, path, body) {
    if (busy[key]) return Promise.resolve(null);
    busy[key] = true;
    return api(method, path, body).then(function (result) {
      busy[key] = false;
      if (result.ok) toast((result.data && result.data.message) || 'Done.');
      else toast(problem(result), true);
      return result;
    });
  }

  // ----- Pairing -----

  function showPairing() {
    $('app').hidden = true;
    $('pair').hidden = false;
    setBanner(null);
    var name = null;
    try { name = localStorage.getItem(NAME_KEY); } catch (error) { name = null; }
    $('pair-name').value = name || guessDeviceName(navigator.userAgent);
    var code = pairingCodeFromHash(location.hash);
    if (code) {
      $('pair-code').value = code;
      // The code is in the address only until it is read.
      history.replaceState(null, '', location.pathname);
    }
  }

  function submitPairing(event) {
    event.preventDefault();
    var button = $('pair-button');
    var error = $('pair-error');
    var code = $('pair-code').value.replace(/\D/g, '');
    if (code.length !== 6) {
      error.textContent = 'The code is six digits.';
      error.hidden = false;
      return;
    }
    var name = $('pair-name').value.trim() || guessDeviceName(navigator.userAgent);
    button.disabled = true;
    error.hidden = true;
    api('POST', '/api/pair', { code: code, name: name }).then(function (result) {
      button.disabled = false;
      if (result.ok && result.data.token) {
        token = result.data.token;
        try {
          localStorage.setItem(TOKEN_KEY, token);
          localStorage.setItem(NAME_KEY, name);
        } catch (storageError) { /* kept for this visit only */ }
        $('pair-code').value = '';
        showApp();
        return;
      }
      var text = problem(result);
      if (result.status === 401 && result.data.attemptsLeft != null) {
        text += ' ' + result.data.attemptsLeft + (result.data.attemptsLeft === 1 ? ' try left.' : ' tries left.');
      }
      error.textContent = text;
      error.hidden = false;
    });
  }

  // ----- Live status -----

  function setBanner(text) {
    var banner = $('banner');
    banner.hidden = !text;
    banner.textContent = text || '';
  }

  function setLive(kind, text) {
    var live = $('live');
    live.className = 'live ' + kind;
    $('live-text').textContent = text;
  }

  function applyStatus(payload) {
    if (!payload || typeof payload !== 'object') return;
    if (payload.server) {
      state.server = payload.server;
      if (payload.server.time) {
        var t = Date.parse(payload.server.time);
        if (!isNaN(t)) clockOffset = t - Date.now();
      }
    }
    if (payload.status) state.status = payload.status;
    render();
  }

  function stopStream() {
    if (stream.controller) stream.controller.abort();
    stream.controller = null;
    clearTimeout(stream.timer);
    stream.timer = null;
    stream.connected = false;
  }

  function scheduleReconnect() {
    if (!token) return;
    stream.connected = false;
    var wait = backoffSeconds(stream.attempt);
    stream.attempt += 1;
    stream.retryAt = Date.now() + wait * 1000;
    setLive('off', 'offline');
    clearTimeout(stream.timer);
    stream.timer = setTimeout(startStream, wait * 1000);
    updateOfflineBanner();
  }

  function updateOfflineBanner() {
    if (!token || stream.connected) { setBanner(null); return; }
    if (navigator.onLine === false) {
      setBanner('This phone is offline. What you see may be out of date.');
      return;
    }
    if (stream.attempt === 0) return;
    var left = Math.max(0, Math.ceil((stream.retryAt - Date.now()) / 1000));
    setBanner("Can't reach the Mac. It may be asleep, or Tailscale may be off. Trying again" + (left > 0 ? ' in ' + left + ' s.' : '…'));
  }

  function startStream() {
    if (!token) return;
    stopStream();
    setLive('', 'connecting');
    if (!(window.ReadableStream && window.TextDecoder && window.AbortController)) {
      startPolling();
      return;
    }
    var controller = new AbortController();
    stream.controller = controller;
    fetch('/api/events', { headers: { Authorization: 'Bearer ' + token }, cache: 'no-store', signal: controller.signal })
      .then(function (response) {
        if (response.status === 401) { unpaired(); return null; }
        if (!response.ok || !response.body) throw new Error('events ' + response.status);
        stream.connected = true;
        stream.attempt = 0;
        stream.lastHeard = Date.now();
        setLive('on', 'live');
        setBanner(null);
        var reader = response.body.getReader();
        var decoder = new TextDecoder();
        var parser = new EventParser(function (name, data) {
          stream.lastHeard = Date.now();
          if (name !== 'status') return;
          try { applyStatus(JSON.parse(data)); } catch (error) { /* a torn event; the next one replaces it */ }
        });
        function pump() {
          return reader.read().then(function (chunk) {
            if (chunk.done) throw new Error('stream ended');
            parser.push(decoder.decode(chunk.value, { stream: true }));
            return pump();
          });
        }
        return pump();
      })
      .catch(function () {
        if (stream.controller !== controller) return;   // replaced or stopped on purpose
        scheduleReconnect();
      });
  }

  // Browsers without streaming fetch: ask for the status every five seconds.
  function startPolling() {
    clearInterval(timers.poll);
    function once() {
      api('GET', '/api/status').then(function (result) {
        if (!token) return;
        if (result.ok) {
          stream.connected = true;
          stream.attempt = 0;
          setLive('on', 'live');
          setBanner(null);
          applyStatus(result.data);
        } else if (result.status === 0) {
          stream.connected = false;
          stream.attempt = Math.max(1, stream.attempt);
          stream.retryAt = Date.now() + 5000;
          setLive('off', 'offline');
          updateOfflineBanner();
        }
      });
    }
    once();
    timers.poll = setInterval(once, 5000);
  }

  // The Mac sends a keepalive every 20 s; a stream silent for 45 s is dead
  // even if the phone has not noticed (a suspended tab, a changed network).
  function watchdog() {
    if (token && stream.connected && stream.controller && Date.now() - stream.lastHeard > 45000) {
      stream.controller.abort();
      stream.controller = null;
      scheduleReconnect();
    }
    if (token && !stream.connected) updateOfflineBanner();
    renderClock();
  }

  // ----- Rendering -----

  function fact(list, label, value, tone) {
    var row = el('div', 'fact');
    row.appendChild(el('span', null, label));
    row.appendChild(el('span', tone || null, value));
    list.appendChild(row);
  }

  function renderClock() {
    var status = state.status;
    var wrap = document.querySelector('.ring-wrap');
    var arc = $('ring-arc');
    var circumference = 2 * Math.PI * 96;
    arc.style.strokeDasharray = String(circumference);
    if (!status || !status.active || !status.endsAt) {
      wrap.className = 'ring-wrap idle';
      $('time-left').textContent = status ? 'Not awake' : '—';
      $('time-sub').textContent = status ? 'No session is running' : '';
      arc.style.strokeDashoffset = String(circumference);
      return;
    }
    var remaining = (Date.parse(status.endsAt) - macNow()) / 1000;
    var fraction = ringFraction(status, macNow());
    wrap.className = remaining <= 600 ? 'ring-wrap low' : 'ring-wrap';
    arc.style.strokeDashoffset = String(circumference * (1 - fraction));
    $('time-left').textContent = formatRemaining(remaining);
    var end = new Date(Date.parse(status.endsAt) - clockOffset);
    $('time-sub').textContent = 'ends ' + end.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' }) +
      (end.toDateString() === new Date().toDateString() ? '' : ' ' + end.toLocaleDateString([], { weekday: 'short' }));
  }

  function renderSession() {
    var status = state.status || {};
    var server = state.server || {};
    $('mac-name').textContent = server.name || 'Mac';
    $('mac-sub').textContent = server.version ? 'Awake ' + server.version : '';
    $('session-active').hidden = !status.active;
    $('session-idle').hidden = !!status.active || !state.status;

    var presets = $('presets');
    var wanted = (server.presetMinutes || [30, 60, 120]).slice(0, 9).join(',');
    if (presets.getAttribute('data-presets') !== wanted) {
      presets.setAttribute('data-presets', wanted);
      clear(presets);
      (server.presetMinutes || [30, 60, 120]).slice(0, 9).forEach(function (minutes) {
        var button = el('button', 'big', formatMinutes(minutes));
        button.addEventListener('click', function () { startSession(minutes); });
        presets.appendChild(button);
      });
    }

    var facts = $('session-facts');
    clear(facts);
    if (!state.status) {
      fact(facts, 'Status', 'waiting for the Mac…');
    } else {
      var power = sessionPowerFact(status);
      if (power) fact(facts, power[0], power[1], power[2]);
      fact(facts, 'Lid', lidText(status.lidClosed, status.lidOnDesk, status.lidKnown));
      fact(facts, 'Heat', status.thermalState || 'unknown', status.thermalState === 'serious' ? 'warn' : status.thermalState === 'critical' ? 'bad' : null);
      if (status.lowPowerSetByUs) fact(facts, 'Low Power Mode', 'on, set by Awake');
      if (status.frozenCount) fact(facts, 'Frozen apps', String(status.frozenCount));
      if (status.dockerPaused) fact(facts, 'Docker Desktop', 'paused');
      if (status.wifiSSID) fact(facts, 'Wi-Fi', status.wifiSSID);
      if (status.lastOutageSeconds != null) fact(facts, 'Last outage', formatAge(status.lastOutageSeconds));
    }

    var leases = Array.isArray(status.leases) ? status.leases : null;
    $('leases').hidden = !leases || leases.length === 0;
    if (leases && leases.length) {
      var list = $('lease-list');
      clear(list);
      leases.forEach(function (lease) {
        var row = el('div', 'device');
        var left = el('div');
        left.appendChild(el('b', null, lease.owner || lease.id || 'lease'));
        if (lease.reason) left.appendChild(el('div', 'muted small', lease.reason));
        row.appendChild(left);
        var until = lease.expiresAt ? Date.parse(lease.expiresAt) : NaN;
        row.appendChild(el('span', 'muted small', isNaN(until) ? '' : 'for ' + formatAge((until - macNow()) / 1000)));
        list.appendChild(row);
      });
    }
    renderClock();
  }

  var agentsSignature = null;
  function renderAgents() {
    var status = state.status || {};
    var server = state.server || {};
    var agents = Array.isArray(status.agents) ? status.agents : null;
    var waiting = agents ? agents.filter(function (a) { return a.state === 'waitingForInput' || a.state === 'stalled'; }).length : 0;
    var badge = $('agents-badge');
    badge.hidden = waiting === 0;
    badge.textContent = String(waiting);

    // Rebuilt only when something shown changed, so a field being typed
    // into or a button under a finger is not replaced mid-tap.
    var signature = JSON.stringify([agents, !!server.agentActions]);
    if (signature === agentsSignature) return;
    agentsSignature = signature;

    var note = $('agents-note');
    var list = $('agent-list');
    clear(list);
    if (!agents) {
      note.textContent = 'This Mac\'s Awake does not report agents yet.';
      return;
    }
    if (agents.length === 0) {
      note.textContent = 'No agents are running on the Mac.';
      return;
    }
    note.textContent = server.agentActions ? '' : 'Agent actions are not available yet in this build; the cards are read-only.';
    agents.forEach(function (agent) {
      var card = el('div', 'card agent');
      card.setAttribute('data-state', agent.state || '');
      var head = el('div', 'agent-head');
      head.appendChild(el('div', 'agent-name', agent.name || agent.kind || agent.id));
      var pill = el('span', 'pill', stateLabel(agent.state));
      pill.setAttribute('data-state', agent.state || '');
      head.appendChild(pill);
      card.appendChild(head);
      var meta = [];
      if (agent.kind && agent.kind !== agent.name) meta.push(agent.kind);
      if (agent.repo) meta.push(agent.repo);
      if (agent.tmuxTarget) meta.push('tmux ' + agent.tmuxTarget);
      if (agent.lastOutputAgeSeconds != null) meta.push('last output ' + formatAge(agent.lastOutputAgeSeconds) + ' ago');
      if (meta.length) card.appendChild(el('div', 'agent-meta', meta.join(' · ')));
      if (agent.waitingPrompt) card.appendChild(el('div', 'prompt', agent.waitingPrompt));

      var actions = el('div', 'agent-actions');
      function button(label, className, handler) {
        var b = el('button', className, label);
        b.disabled = !server.agentActions;
        b.addEventListener('click', handler);
        actions.appendChild(b);
      }
      var name = agent.name || agent.id;
      var base = '/api/agents/' + encodeURIComponent(agent.id) + '/';
      button('Answer…', 'answer primary', function () {
        ask({ title: 'Answer ' + name, body: agent.waitingPrompt || 'Typed into the agent, then Enter.', input: true, placeholder: 'Your answer', ok: 'Send' }).then(function (text) {
          if (text) act('agent', 'POST', base + 'answer', { text: text });
        });
      });
      button('Nudge', null, function () {
        ask({ title: 'Nudge ' + name + '?', body: 'Presses Enter in the agent\'s tmux pane.', ok: 'Nudge' }).then(function (yes) {
          if (yes) act('agent', 'POST', base + 'nudge');
        });
      });
      if (agent.state === 'exited') {
        // Nothing to pause or stop.
      } else {
        button('Pause', null, function () {
          ask({ title: 'Pause ' + name + '?', body: 'The agent is frozen until you resume it.', ok: 'Pause' }).then(function (yes) {
            if (yes) act('agent', 'POST', base + 'pause');
          });
        });
        button('Resume', null, function () {
          ask({ title: 'Resume ' + name + '?', ok: 'Resume' }).then(function (yes) {
            if (yes) act('agent', 'POST', base + 'resume');
          });
        });
        button('Stop', 'danger', function () {
          ask({ title: 'Stop ' + name + '?', body: 'The agent is asked to quit. Work it has not saved may be lost.', ok: 'Stop', danger: true }).then(function (yes) {
            if (yes) act('agent', 'POST', base + 'stop');
          });
        });
      }
      card.appendChild(actions);
      list.appendChild(card);
    });
  }

  function render() {
    renderSession();
    renderAgents();
    renderPush();
  }

  // ----- Session actions -----

  function startSession(minutes) {
    ask({ title: 'Keep the Mac awake for ' + formatMinutes(minutes) + '?', body: 'Sleep is turned off until the time runs out or you end the session.', ok: 'Start' }).then(function (yes) {
      if (yes) act('session', 'POST', '/api/session/start', { minutes: minutes });
    });
  }

  function extendSession(minutes) {
    ask({ title: 'Add ' + formatMinutes(minutes) + '?', ok: 'Add' }).then(function (yes) {
      if (yes) act('session', 'POST', '/api/session/extend', { minutes: minutes });
    });
  }

  function endSession() {
    ask({ title: 'End the session?', body: 'The Mac goes back to its normal sleep settings and everything Awake changed is undone.', ok: 'End session', danger: true }).then(function (yes) {
      if (yes) act('session', 'POST', '/api/session/end');
    });
  }

  // ----- Machine -----

  function loadMachine() {
    api('GET', '/api/machine').then(function (result) {
      var list = $('machine-list');
      if (!result.ok) {
        if (result.status !== 401) $('machine-note').textContent = problem(result);
        return;
      }
      var m = result.data;
      clear(list);
      function unknown(value, text) { return value == null ? 'unknown' : text; }
      machinePowerFacts(m).forEach(function (f) { fact(list, f[0], f[1], f[2]); });
      fact(list, 'Heat', m.thermalState || 'unknown', m.thermalState === 'serious' ? 'warn' : m.thermalState === 'critical' ? 'bad' : null);
      fact(list, 'CPU speed limit', m.cpuSpeedLimit == null ? 'none recorded' : m.cpuSpeedLimit + '%', m.cpuSpeedLimit != null && m.cpuSpeedLimit <= 50 ? 'warn' : null);
      fact(list, 'Battery temperature', m.batteryTemperatureC == null ? 'not reported' : m.batteryTemperatureC.toFixed(1) + ' °C', m.batteryTemperatureC != null && m.batteryTemperatureC >= 45 ? 'warn' : null);
      fact(list, 'Memory pressure', m.memoryPressure || 'unknown', m.memoryPressure === 'critical' ? 'bad' : m.memoryPressure === 'warning' ? 'warn' : null);
      fact(list, 'Free disk', formatBytes(m.freeDiskBytes), m.freeDiskBytes != null && m.freeDiskBytes < 10e9 ? 'warn' : null);
      var network = m.networkType || 'unknown';
      if (m.networkType === 'wifi') network = 'Wi-Fi' + (m.wifiSSID ? ' (' + m.wifiSSID + ')' : '');
      if (m.networkType === 'none') network = 'no connection';
      fact(list, 'Network', network, m.networkType === 'none' ? 'bad' : null);
      fact(list, 'Tailscale', m.tailscaleIPv4 || 'not found', m.tailscaleIPv4 ? null : 'warn');
      fact(list, 'Lid', lidText(m.lidClosed, false, true));
      fact(list, 'Low Power Mode', unknown(m.lowPowerMode, m.lowPowerMode ? 'on' : 'off'));
      if (m.uptimeSeconds != null) fact(list, 'Up for', formatAge(m.uptimeSeconds));
      $('machine-note').textContent = 'Read from the Mac at ' + new Date().toLocaleTimeString() + '. "unknown" means the Mac could not take that reading.';
    });
  }

  // ----- Security -----

  var zoom = { scale: 1, x: 0, y: 0, startDistance: 0, startScale: 1, startX: 0, startY: 0, panX: 0, panY: 0, lastTap: 0 };

  function applyZoom() {
    var box = $('shot-box');
    var maxX = box.clientWidth * (zoom.scale - 1);
    var maxY = box.clientHeight * (zoom.scale - 1);
    zoom.x = Math.min(0, Math.max(-maxX, zoom.x));
    zoom.y = Math.min(0, Math.max(-maxY, zoom.y));
    $('shot').style.transform = 'translate(' + zoom.x + 'px,' + zoom.y + 'px) scale(' + zoom.scale + ')';
  }

  function resetZoom() {
    zoom.scale = 1; zoom.x = 0; zoom.y = 0;
    applyZoom();
  }

  function touchDistance(touches) {
    var dx = touches[0].clientX - touches[1].clientX;
    var dy = touches[0].clientY - touches[1].clientY;
    return Math.sqrt(dx * dx + dy * dy);
  }

  function setupZoom() {
    var box = $('shot-box');
    box.addEventListener('touchstart', function (event) {
      if (event.touches.length === 2) {
        zoom.startDistance = touchDistance(event.touches);
        zoom.startScale = zoom.scale;
        var rect = box.getBoundingClientRect();
        // The point between the fingers stays under them as the image grows.
        zoom.midX = (event.touches[0].clientX + event.touches[1].clientX) / 2 - rect.left;
        zoom.midY = (event.touches[0].clientY + event.touches[1].clientY) / 2 - rect.top;
        zoom.startX = zoom.x;
        zoom.startY = zoom.y;
      } else if (event.touches.length === 1) {
        var now = Date.now();
        if (now - zoom.lastTap < 300) { resetZoom(); zoom.lastTap = 0; }
        else zoom.lastTap = now;
        zoom.panX = event.touches[0].clientX - zoom.x;
        zoom.panY = event.touches[0].clientY - zoom.y;
      }
    }, { passive: true });
    box.addEventListener('touchmove', function (event) {
      if (event.touches.length === 2 && zoom.startDistance > 0) {
        event.preventDefault();
        var scale = Math.min(6, Math.max(1, zoom.startScale * touchDistance(event.touches) / zoom.startDistance));
        var ratio = scale / zoom.startScale;
        zoom.x = zoom.midX - (zoom.midX - zoom.startX) * ratio;
        zoom.y = zoom.midY - (zoom.midY - zoom.startY) * ratio;
        zoom.scale = scale;
        applyZoom();
      } else if (event.touches.length === 1 && zoom.scale > 1) {
        event.preventDefault();
        zoom.x = event.touches[0].clientX - zoom.panX;
        zoom.y = event.touches[0].clientY - zoom.panY;
        applyZoom();
      }
    }, { passive: false });
    box.addEventListener('touchend', function (event) {
      if (event.touches.length < 2) zoom.startDistance = 0;
      if (event.touches.length === 1) {
        zoom.panX = event.touches[0].clientX - zoom.x;
        zoom.panY = event.touches[0].clientY - zoom.y;
      }
    }, { passive: true });
  }

  function loadScreenshot(quiet) {
    if (busy.shot) return;
    busy.shot = true;
    var width = Math.min(2560, Math.max(640, Math.round(window.innerWidth * (window.devicePixelRatio || 1) * 2)));
    api('GET', '/api/screenshot?display=main&width=' + width, null, true).then(function (result) {
      busy.shot = false;
      var note = $('shot-note');
      if (!result.ok) {
        note.textContent = problem(result);
        note.className = 'error small';
        if (!quiet) toast(problem(result), true);
        // Without the permission every retry fails the same way.
        if (result.status === 403) { $('shot-auto').checked = false; scheduleShots(); }
        return;
      }
      var url = URL.createObjectURL(result.blob);
      var img = $('shot');
      img.onload = function () {
        if (shotUrl) URL.revokeObjectURL(shotUrl);
        shotUrl = url;
      };
      img.src = url;
      $('shot-box').hidden = false;
      note.className = 'muted small';
      note.textContent = 'Taken at ' + new Date().toLocaleTimeString() + '. Pinch to zoom, double-tap to reset. Nothing is saved on the Mac.';
    });
  }

  function scheduleShots() {
    clearInterval(timers.shot);
    timers.shot = null;
    if ($('shot-auto').checked && currentTab === 'security' && !document.hidden) {
      loadScreenshot(true);
      timers.shot = setInterval(function () { loadScreenshot(true); }, 5000);
    }
  }

  function loadDevices() {
    api('GET', '/api/devices').then(function (result) {
      if (!result.ok) return;
      var list = $('device-list');
      clear(list);
      (result.data.devices || []).forEach(function (device) {
        var row = el('div', 'device');
        var left = el('div');
        left.appendChild(el('b', null, device.name + (device.current ? ' (this phone)' : '')));
        left.appendChild(el('div', 'muted small', 'paired ' + new Date(device.createdAt).toLocaleDateString()));
        row.appendChild(left);
        var seen = device.lastSeenAt ? (macNow() - Date.parse(device.lastSeenAt)) / 1000 : null;
        row.appendChild(el('span', 'muted small', seen == null ? '' : seen < 90 ? 'connected now' : 'seen ' + formatAge(seen) + ' ago'));
        list.appendChild(row);
      });
    });
  }

  function setupPanic() {
    var button = $('panic-button');
    var timer = null;
    function cancel() {
      clearTimeout(timer);
      timer = null;
      button.classList.remove('holding');
    }
    button.addEventListener('pointerdown', function (event) {
      event.preventDefault();
      if (timer || busy.panic) return;
      button.classList.add('holding');
      timer = setTimeout(function () {
        cancel();
        if (navigator.vibrate) navigator.vibrate(60);
        act('panic', 'POST', '/api/panic');
      }, 2000);
    });
    ['pointerup', 'pointerleave', 'pointercancel'].forEach(function (name) {
      button.addEventListener(name, cancel);
    });
    button.addEventListener('contextmenu', function (event) { event.preventDefault(); });
  }

  // ----- Web push -----

  var push = { supported: false, subscribed: false, key: undefined };

  function renderPush() {
    var card = $('push-card');
    var server = state.server || {};
    push.supported = !!(window.isSecureContext && 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window);
    // A Mac that cannot send web push shows no card at all: ntfy and
    // Pushover remain the alert path.
    card.hidden = server.webPush !== true;
    if (card.hidden) return;
    var note = $('push-note');
    var enable = $('push-enable');
    var test = $('push-test');
    if (!push.supported) {
      enable.disabled = true;
      test.disabled = true;
      note.textContent = window.isSecureContext
        ? 'This browser has no web push. On an iPhone, add Awake to the Home Screen first and open it from there.'
        : 'Notifications need the https address. On the Mac run "tailscale serve --bg ' + (server.port || 7788) + '" and open the https address Awake\'s Settings shows.';
      return;
    }
    if (push.key === null) {
      enable.disabled = true;
      test.disabled = true;
      note.textContent = 'This Mac\'s Awake cannot send web push. Alerts still arrive through ntfy or Pushover if they are set up.';
      return;
    }
    enable.disabled = false;
    test.disabled = !push.subscribed;
    enable.textContent = push.subscribed ? 'Turn off' : 'Turn on';
    note.textContent = push.subscribed
      ? 'This phone gets Awake\'s alerts as notifications.'
      : 'Get Awake\'s alerts (battery, heat, session ended, agent waiting) as notifications on this phone.';
  }

  function checkPush() {
    if (!push.supported) return;
    navigator.serviceWorker.ready.then(function (registration) {
      return registration.pushManager.getSubscription();
    }).then(function (subscription) {
      push.subscribed = !!subscription;
      renderPush();
    }).catch(function () {});
  }

  function togglePush() {
    if (!push.supported) return;
    navigator.serviceWorker.ready.then(function (registration) {
      return registration.pushManager.getSubscription().then(function (existing) {
        if (existing) {
          return existing.unsubscribe().then(function () {
            push.subscribed = false;
            renderPush();
            return act('push', 'POST', '/api/push/unsubscribe');
          });
        }
        return Notification.requestPermission().then(function (permission) {
          if (permission !== 'granted') {
            toast('Notifications are not allowed for Awake on this phone.', true);
            return null;
          }
          return api('GET', '/api/push/key').then(function (result) {
            if (!result.ok || !result.data.publicKey) {
              push.key = null;
              renderPush();
              return null;
            }
            push.key = result.data.publicKey;
            return registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: base64UrlToBytes(push.key) }).then(function (subscription) {
              return act('push', 'POST', '/api/push/subscribe', subscription.toJSON()).then(function (saved) {
                push.subscribed = !!(saved && saved.ok);
                if (!push.subscribed) subscription.unsubscribe();
                renderPush();
              });
            });
          });
        });
      });
    }).catch(function (error) {
      toast('Notifications could not be turned on: ' + (error && error.message ? error.message : 'unknown error'), true);
    });
  }

  // ----- Log -----

  function loadLog() {
    api('GET', '/api/log?lines=200').then(function (result) {
      if (!result.ok) return;
      var pre = $('log');
      var atBottom = pre.scrollHeight - pre.scrollTop - pre.clientHeight < 40;
      var text = (result.data.lines || []).join('\n');
      if (pre.textContent !== text) {
        pre.textContent = text || 'The log is empty.';
        if (atBottom) pre.scrollTop = pre.scrollHeight;
      }
    });
  }

  // ----- Tabs and timers -----

  function stopTimers() {
    Object.keys(timers).forEach(function (key) {
      clearInterval(timers[key]);
      timers[key] = null;
    });
  }

  function tabTimers() {
    clearInterval(timers.machine);
    clearInterval(timers.log);
    timers.machine = null;
    timers.log = null;
    if (document.hidden || !token) { scheduleShots(); return; }
    if (currentTab === 'machine') {
      loadMachine();
      timers.machine = setInterval(loadMachine, 10000);
    }
    if (currentTab === 'log') {
      loadLog();
      if ($('log-auto').checked) timers.log = setInterval(loadLog, 5000);
    }
    if (currentTab === 'security') loadDevices();
    scheduleShots();
  }

  function go(tab) {
    currentTab = tab;
    var sections = document.querySelectorAll('.tab');
    for (var i = 0; i < sections.length; i++) sections[i].hidden = sections[i].getAttribute('data-tab') !== tab;
    var buttons = document.querySelectorAll('.tabs button');
    for (var j = 0; j < buttons.length; j++) {
      var on = buttons[j].getAttribute('data-go') === tab;
      buttons[j].className = on ? 'on' : '';
      if (on) buttons[j].setAttribute('aria-current', 'page');
      else buttons[j].removeAttribute('aria-current');
    }
    window.scrollTo(0, 0);
    tabTimers();
    if (tab === 'log') { var pre = $('log'); pre.scrollTop = pre.scrollHeight; }
  }

  function showApp() {
    $('pair').hidden = true;
    $('app').hidden = false;
    render();
    go(currentTab);
    stream.attempt = 0;
    startStream();
    checkPush();
  }

  // ----- Wiring -----

  function init() {
    $('pair-form').addEventListener('submit', submitPairing);
    var tabButtons = document.querySelectorAll('.tabs button');
    for (var i = 0; i < tabButtons.length; i++) {
      tabButtons[i].addEventListener('click', function () { go(this.getAttribute('data-go')); });
    }
    var extendButtons = document.querySelectorAll('[data-extend]');
    for (var j = 0; j < extendButtons.length; j++) {
      extendButtons[j].addEventListener('click', function () { extendSession(parseInt(this.getAttribute('data-extend'), 10)); });
    }
    $('end-button').addEventListener('click', endSession);
    $('custom-start').addEventListener('submit', function (event) {
      event.preventDefault();
      var minutes = parseInt($('custom-minutes').value, 10);
      if (!(minutes >= 1)) { toast('Type a number of minutes.', true); return; }
      startSession(minutes);
    });
    $('lock-button').addEventListener('click', function () {
      ask({ title: 'Lock the Mac now?', body: 'The session keeps running behind the lock screen. The Mac cannot be unlocked from here.', ok: 'Lock' }).then(function (yes) {
        if (yes) act('lock', 'POST', '/api/lock');
      });
    });
    $('shot-button').addEventListener('click', function () { loadScreenshot(false); });
    $('shot-auto').addEventListener('change', scheduleShots);
    $('unpair-button').addEventListener('click', function () {
      ask({ title: 'Unpair this phone?', body: 'This phone forgets its key and the Mac stops accepting it. Pair again from the Mac to come back.', ok: 'Unpair', danger: true }).then(function (yes) {
        if (!yes) return;
        api('POST', '/api/unpair').then(function (result) {
          if (result.ok) unpaired();
          else if (result.status !== 401) toast(problem(result), true);
        });
      });
    });
    $('push-enable').addEventListener('click', togglePush);
    $('push-test').addEventListener('click', function () { act('push', 'POST', '/api/push/test'); });
    $('log-button').addEventListener('click', loadLog);
    $('log-auto').addEventListener('change', tabTimers);
    setupPanic();
    setupZoom();

    window.addEventListener('online', function () { if (token && !stream.connected) { stream.attempt = 0; startStream(); } });
    window.addEventListener('offline', updateOfflineBanner);
    document.addEventListener('visibilitychange', function () {
      tabTimers();
      // A phone that comes back from the lock screen reconnects at once.
      if (!document.hidden && token && !stream.connected) { stream.attempt = 0; startStream(); }
    });
    setInterval(watchdog, 1000);

    if (window.isSecureContext && 'serviceWorker' in navigator) {
      navigator.serviceWorker.register('/sw.js').catch(function () {});
    }

    if (token && !pairingCodeFromHash(location.hash)) showApp();
    else if (token) { history.replaceState(null, '', location.pathname); showApp(); }
    else showPairing();
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
