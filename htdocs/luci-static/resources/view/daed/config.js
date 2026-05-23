// SPDX-License-Identifier: Apache-2.0

'use strict';
'require form';
'require fs';
'require poll';
'require rpc';
'require uci';
'require ui';
'require view';

const callServiceList = rpc.declare({
	object: 'service',
	method: 'list',
	params: ['name'],
	expect: { '': {} }
});


const CSS = [
	'.dd-wrap{padding:6px 0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC",sans-serif}',
	'.dd-card{border:1px solid rgba(0,0,0,.06);border-radius:10px;padding:14px 16px;margin-bottom:14px;box-shadow:0 2px 8px rgba(0,0,0,.03);background:rgba(255,255,255,.02)}',
	'.dd-card-title{font-size:12px;font-weight:600;opacity:.55;margin:0 0 10px;letter-spacing:.3px;text-transform:uppercase}',
	'.dd-status-row{display:flex;align-items:center;flex-wrap:wrap;gap:14px;margin-bottom:10px}',
	'.dd-status-row .dd-grow{flex:1 1 auto}',
	'.dd-badge{display:inline-flex;align-items:center;gap:6px;padding:3px 12px;border-radius:999px;font-size:11px;font-weight:700;letter-spacing:.3px;border:1px solid transparent;line-height:1.3}',
	'.dd-badge-run{color:#3da66a;border-color:rgba(61,166,106,.5)}',
	'.dd-badge-stop{color:#d96d6d;border-color:rgba(217,109,109,.55)}',
	'.dd-badge-dot{width:6px;height:6px;border-radius:50%;background:currentColor;display:inline-block}',
	'.dd-meta{font-size:12px;opacity:.7;font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,"Liberation Mono",monospace}',
	'.dd-meta-label{opacity:.55;margin-right:4px}',
	'.dd-actions{display:flex;flex-wrap:wrap;gap:8px;margin-top:4px}',
	'.dd-actions .cbi-button{font-size:12px;padding:6px 14px;border-radius:6px}',
	'.dd-actions a.cbi-button{display:inline-flex;align-items:center;gap:4px}',
	'.dd-switch{position:relative;width:46px;height:24px;border:0;border-radius:999px;background:rgba(128,128,128,.28);padding:0;cursor:pointer;transition:background .18s ease,opacity .18s ease;flex-shrink:0}',
	'.dd-switch .dd-switch-knob{position:absolute;top:3px;left:3px;width:18px;height:18px;border-radius:50%;background:rgba(255,255,255,.96);box-shadow:0 1px 4px rgba(0,0,0,.2);transition:transform .18s ease}',
	'.dd-switch.is-on{background:rgba(74,160,101,.65)}',
	'.dd-switch.is-on .dd-switch-knob{transform:translateX(22px)}',
	'.dd-switch:disabled{opacity:.45;cursor:not-allowed}',
	'.dd-switch-label{font-size:11px;font-weight:600;opacity:.62;letter-spacing:.3px}',
	'.dd-switch-wrap{display:inline-flex;align-items:center;gap:8px;white-space:nowrap}',
	'body.dark .dd-card,html[data-theme="dark"] .dd-card,html[data-bs-theme="dark"] .dd-card{border-color:rgba(255,255,255,.08);background:rgba(255,255,255,.02)}'
].join('');

function execInit(action) {
	return fs.exec('/etc/init.d/daed', [action]).then(function(res) {
		if (res.code !== 0)
			ui.addNotification(null, E('p', _('Action "%s" failed (exit %d): %s').format(action, res.code, res.stderr || res.stdout || '')), 'danger');
		else
			ui.addNotification(null, E('p', _('Action "%s" succeeded.').format(action)), 'info');
	}).catch(function(e) {
		ui.addNotification(null, E('p', _('Action "%s" error: %s').format(action, e)), 'danger');
	});
}

function fetchStatus() {
	return L.resolveDefault(callServiceList('daed'), {}).then(function(svc) {
		let pid = 0, running = false;
		try {
			const inst = svc['daed']['instances']['daed'];
			running = !!inst.running;
			pid = inst.pid || 0;
		} catch (e) { /* not installed or not started */ }
		return { running: running, pid: pid };
	});
}

function toggleService(turnOn) {
	// Pill switch — flip UCI enabled via /sbin/uci then start/stop the service.
	// daed's init.d checks `enabled` in start_service and returns early when 0,
	// so we must update UCI before calling start. We use /sbin/uci (CLI) rather
	// than LuCI's uci RPC because uci/commit needs an extra ACL grant.
	const enabled = turnOn ? '1' : '0';
	const action = turnOn ? 'start' : 'stop';
	return fs.exec('/sbin/uci', ['set', 'daed.config.enabled=' + enabled])
		.then(function() { return fs.exec('/sbin/uci', ['commit', 'daed']); })
		.then(function() {
			if (turnOn)
				fs.exec('/etc/init.d/daed', ['enable']);
			else
				fs.exec('/etc/init.d/daed', ['disable']);
		})
		.then(function() { return fs.exec('/etc/init.d/daed', [action]); })
		.then(function(res) {
			if (res && res.code !== 0)
				ui.addNotification(null, E('p', _('Action "%s" failed: %s').format(action, res.stderr || res.stdout || ('exit ' + res.code))), 'danger');
		}).catch(function(e) {
			ui.addNotification(null, E('p', _('Toggle failed: %s').format(e)), 'danger');
		});
}

function renderStatusCard(state, listenAddr) {
	const port = (listenAddr || '0.0.0.0:2023').split(':').slice(-1)[0];
	const host = window.location.hostname;
	const badge = state.running
		? E('span', { 'class': 'dd-badge dd-badge-run' }, [ E('span', { 'class': 'dd-badge-dot' }), 'RUNNING' ])
		: E('span', { 'class': 'dd-badge dd-badge-stop' }, [ E('span', { 'class': 'dd-badge-dot' }), 'STOPPED' ]);

	const meta = [];
	if (state.running && state.pid)
		meta.push(E('span', { 'class': 'dd-meta' }, [ E('span', { 'class': 'dd-meta-label' }, 'PID'), state.pid ]));
	meta.push(E('span', { 'class': 'dd-meta' }, [ E('span', { 'class': 'dd-meta-label' }, 'Listen'), listenAddr || '0.0.0.0:2023' ]));

	const sw = E('button', { 'class': 'dd-switch' + (state.running ? ' is-on' : ''), 'type': 'button', 'aria-label': 'Toggle service' }, [
		E('span', { 'class': 'dd-switch-knob' })
	]);
	sw.addEventListener('click', function(ev) {
		ev.preventDefault();
		sw.disabled = true;
		toggleService(!state.running).finally(function() { sw.disabled = false; });
	});
	const swWrap = E('span', { 'class': 'dd-switch-wrap' }, [
		E('span', { 'class': 'dd-switch-label' }, state.running ? 'ON' : 'OFF'),
		sw
	]);

	const openBtn = E('a', {
		'class': 'cbi-button cbi-button-action',
		'href': 'http://%s:%s'.format(host, port),
		'target': '_blank',
		'rel': 'noreferrer noopener'
	}, 'Open WebUI');

	const mkBtn = function(label, action, style) {
		const b = E('button', { 'class': 'cbi-button cbi-button-' + style }, label);
		b.addEventListener('click', function(ev) {
			ev.preventDefault();
			b.disabled = true;
			execInit(action).finally(function() { b.disabled = false; });
		});
		return b;
	};

	const actions = state.running
		? [ openBtn, mkBtn('Restart', 'restart', 'positive'), mkBtn('Reload', 'reload', 'neutral') ]
		: [];

	const row1 = E('div', { 'class': 'dd-status-row' }, [ badge ].concat(meta).concat([
		E('span', { 'class': 'dd-grow' }), swWrap
	]));

	if (actions.length === 0)
		return [ row1 ];
	return [ row1, E('div', { 'class': 'dd-actions' }, actions) ];
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('daed')
		]);
	},

	render: function(data) {
		const self = this;
		const listenAddr = uci.get(data[0], 'config', 'listen_addr') || '0.0.0.0:2023';

		const statusBody = E('div', { 'id': 'dd-status-body' }, E('em', {}, _('Collecting data…')));
		const statusCard = E('div', { 'class': 'dd-card' }, [
			E('h4', { 'class': 'dd-card-title' }, 'Service Status'),
			statusBody
		]);

		const refresh = function() {
			return fetchStatus().then(function(state) {
				while (statusBody.firstChild) statusBody.removeChild(statusBody.firstChild);
				renderStatusCard(state, uci.get('daed', 'config', 'listen_addr') || listenAddr)
					.forEach(function(el) { statusBody.appendChild(el); });
			});
		};
		poll.add(refresh);
		refresh();

		let m, s, o;
		m = new form.Map('daed', _('daed'),
			_('A modern dashboard for dae — eBPF-based transparent proxy. Subscriptions, nodes, routing and DNS are managed in the daed WebUI.'));

		// Single NamedSection for all fields — splitting one UCI section into
		// multiple form.NamedSection rows triggers a false "Unsaved Changes"
		// dirty marker in LuCI.
		s = m.section(form.NamedSection, 'config', 'daed');
		s.addremove = false;

		o = s.option(form.Value, 'listen_addr', 'Listen Address',
			_('Host:port that the daed WebUI and GraphQL API listen on.'));
		o.datatype = 'ipaddrport(1)';
		o.default = '0.0.0.0:2023';
		o.rmempty = false;

		o = s.option(form.Value, 'log_maxsize', 'Max Log Size (MB)',
			_('Rotate the log file once it grows past this many megabytes.'));
		o.datatype = 'uinteger';
		o.default = '5';

		o = s.option(form.Value, 'log_maxbackups', 'Max Log Backups',
			_('Number of rotated log files to keep.'));
		o.datatype = 'uinteger';
		o.default = '1';

		return Promise.resolve(m.render()).then(function(node) {
			return E('div', { 'class': 'dd-wrap' }, [
				E('style', {}, CSS),
				statusCard,
				node
			]);
		});
	}
});
