import {readFile} from 'node:fs/promises';
import assert from 'node:assert/strict';
import test from 'node:test';

const source = await readFile(new URL('./api.js', import.meta.url), 'utf8');
const {connectionFrom, hostPermission, importedConnection, requestAPI, remaining, badgeState, sleepSettings} =
  await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
const token = 'test-key-0123456789';
const connection = {baseURL: 'http://mac.local:8788', token};
const quotas = {version: 1, providers: {codex: {status: 'ok', five_hour: {used_percent: 23}}, claude: {status: 'ok'}}};
const response = (payload, status = 200) => ({status, ok: status >= 200 && status < 300, json: async () => payload});

test('connection accepts root HTTP(S), local names, ports and IPv6', () => {
  assert.deepEqual(connectionFrom(' mac.local:8788 ', ` ${token}\n`), connection);
  assert.deepEqual(connectionFrom('https://mac.example:9443/', token), {baseURL: 'https://mac.example:9443', token});
  assert.equal(connectionFrom('http://[::1]:8788', token).baseURL, 'http://[::1]:8788');
  assert.equal(hostPermission(connection.baseURL), 'http://mac.local/*');
  assert.equal(hostPermission('https://[::1]:8788'), 'https://[::1]/*');
});

test('connection rejects absent URLs, paths, credentials, queries and fragments', () => {
  for (const address of ['', 'http://', 'ftp://mac.local', 'file:///tmp', 'https://user:pass@mac.local',
    'http://mac.local/v1/quotas', 'http://mac.local/?token=secret', 'http://mac.local/#secret', 'http://mac.local/../secret']) {
    assert.throws(() => connectionFrom(address, token), undefined, address);
  }
});

test('connection validates the Mac API token bounds and printable ASCII', () => {
  for (const key of ['', 'a'.repeat(15), 'a'.repeat(257), 'with internal spaces', 'a'.repeat(16) + '\u007f', 'é'.repeat(16)]) {
    assert.throws(() => connectionFrom(connection.baseURL, key), undefined, JSON.stringify(key));
  }
  for (const key of ['a'.repeat(16), 'a'.repeat(256)]) assert.equal(connectionFrom(connection.baseURL, key).token, key);
});

test('Mac two-line clipboard configuration imports without leaking secrets in errors', () => {
  assert.deepEqual(importedConnection(`Adresse: mac.local:8788\r\nJeton: ${token}\r\n`), connection);
  for (const value of [`Adresse: mac.local:8788`, `Jeton: ${token}`, `Adresse: http://user:secret@mac.local\nJeton: ${token}`]) {
    assert.throws(() => importedConnection(value), error => !error.message.includes(token) && !error.message.includes('user:secret'));
  }
});

test('quota reads send only API credentials, disable cache/cookies and block redirects', async () => {
  let called;
  assert.deepEqual(await requestAPI(connection, '/v1/quotas', undefined, async (...args) => {
    called = args;
    return response(quotas);
  }), quotas);
  const [url, options] = called;
  assert.equal(url, 'http://mac.local:8788/v1/quotas');
  assert.equal(options.method, 'GET');
  assert.deepEqual(options.headers, {Authorization: `Bearer ${token}`});
  assert.equal(options.credentials, 'omit');
  assert.equal(options.cache, 'no-store');
  assert.equal(options.redirect, 'error');
  assert.ok(options.signal instanceof AbortSignal);
  assert.equal(options.signal.aborted, false);
  assert.equal(options.body, undefined);
});

test('refresh supports the asynchronous HTTP 202 contract', async () => {
  const payload = {version: 1, started: true, refresh: {active: true, generation: 2}};
  assert.deepEqual(await requestAPI(connection, '/v1/refresh', undefined, async (url, options) => {
    assert.equal(url, connection.baseURL + '/v1/refresh');
    assert.equal(options.method, 'POST');
    return response(payload, 202);
  }), payload);
});

test('display changes send JSON without altering omitted settings', async () => {
  const body = {codex: false};
  await requestAPI(connection, '/v1/display', body, async (url, options) => {
    assert.equal(url, connection.baseURL + '/v1/display');
    assert.equal(options.method, 'POST');
    assert.equal(options.headers['Content-Type'], 'application/json');
    assert.deepEqual(JSON.parse(options.body), body);
    return response({version: 1, display: {codex: false, claude: true, sleep: null}});
  });
});

test('unlisted endpoints and invalid connections are rejected before fetch', async () => {
  let calls = 0;
  const fetcher = async () => { calls++; return response(quotas); };
  for (const path of ['/health', '/designer/', '/v1/quotas?token=secret', 'https://evil.example/v1/quotas', '/v1/quotas/../display']) {
    await assert.rejects(requestAPI(connection, path, undefined, fetcher), /Action API inconnue/);
  }
  await assert.rejects(requestAPI({...connection, baseURL: 'http://user:secret@mac.local'}, '/v1/quotas', undefined, fetcher));
  assert.equal(calls, 0);
});

test('network, timeout and redirect failures expose only a sanitized message', async () => {
  for (const failure of [new Error(`redirected with Bearer ${token}`), new DOMException(token, 'TimeoutError')]) {
    await assert.rejects(requestAPI(connection, '/v1/quotas', undefined, async () => {throw failure;}), error => {
      assert.match(error.message, /Mac source injoignable/);
      assert.equal(error.message.includes(token), false);
      return true;
    });
  }
});

test('authentication, HTTP and malformed JSON errors remain actionable', async () => {
  await assert.rejects(requestAPI(connection, '/v1/quotas', undefined, async () => response({}, 401)), /Clé API refusée/);
  await assert.rejects(requestAPI(connection, '/v1/quotas', undefined, async () => response({}, 503)), /HTTP 503/);
  await assert.rejects(requestAPI(connection, '/v1/quotas', undefined, async () => ({status: 200, ok: true, json: async () => {throw new Error(token);}})), /Réponse API invalide/);
});

test('wrong versions and missing providers are rejected', async () => {
  for (const payload of [null, {}, {...quotas, version: 2}, {version: 1, providers: {}}, {version: 1, providers: {codex: {}}},
    {version: 1, providers: {codex: 'bad', claude: []}}, {version: 1, providers: {codex: [], claude: {}}}]) {
    await assert.rejects(requestAPI(connection, '/v1/quotas', undefined, async () => response(payload)), /API Quota Display v1/);
  }
});

test('remaining preserves missing values and clamps finite percentages', () => {
  for (const window of [undefined, null, {}, {used_percent: null}, {used_percent: '23'}, {used_percent: NaN}, {used_percent: Infinity}]) {
    assert.equal(remaining(window), null);
  }
  for (const [used, expected] of [[0, 100], [23, 77], [100, 0], [101, 0], [-5, 100], [12.5, 87.5]]) {
    assert.equal(remaining({used_percent: used}), expected);
  }
});

test('badge marks stale and offline data and supports hiding the badge', () => {
  assert.equal(badgeState(quotas).text, '77%');
  assert.match(badgeState(quotas).title, /77 % libre/);
  const stale = {...quotas, providers: {...quotas.providers, codex: {...quotas.providers.codex, status: 'stale'}}};
  assert.equal(badgeState(stale).color, '#7c8da4');
  assert.match(badgeState(stale).title, /non actualisées/);
  assert.equal(badgeState(quotas, 'codex:five_hour', false).text, '!');
  assert.match(badgeState(quotas, 'codex:five_hour', false).title, /hors ligne/);
  assert.equal(badgeState(quotas, 'none').text, '');
  assert.equal(badgeState(quotas, 'claude:fable_weekly').text, '—');
  assert.equal(badgeState(quotas, 'claude:fable_weekly').color, '#7c8da4');
  assert.match(badgeState(quotas, 'claude:fable_weekly').title, /Fable : non fourni/);
});

test('sleep accepts valid crossing-midnight and daytime schedules', () => {
  assert.deepEqual(sleepSettings(true, '23:00', '07:00', 'America/Toronto'), {
    enabled: true, start_minute: 1380, end_minute: 420, timezone: 'America/Toronto',
  });
  assert.deepEqual(sleepSettings(false, '00:00', '23:59', 'Europe/Paris'), {
    enabled: false, start_minute: 0, end_minute: 1439, timezone: 'Europe/Paris',
  });
});

test('sleep rejects invalid hours, identical bounds and unknown IANA zones', () => {
  for (const start of ['24:00', '23:60', '7:00', '-1:00', '12', '', '99:99']) {
    assert.throws(() => sleepSettings(true, start, '07:00', 'America/Toronto'), /Heure/);
  }
  assert.throws(() => sleepSettings(true, '07:00', '07:00', 'America/Toronto'), /différents/);
  assert.throws(() => sleepSettings(true, '23:00', '07:00', 'Not/A_timezone'), /Fuseau/);
  assert.throws(() => sleepSettings('false', '23:00', '07:00', 'America/Toronto'), /veille/);
  assert.throws(() => sleepSettings(true, '23:00', '07:00', undefined), /Fuseau/);
  assert.throws(() => sleepSettings(true, '23:00', '07:00', ''), /Fuseau/);
});

test('background restricts messages, caches successful reads and never reuses another source', async () => {
  const originalChrome = globalThis.chrome, originalFetch = globalThis.fetch;
  const local = {}, session = {}, actions = {}, listeners = {};
  const event = name => ({addListener(listener) {listeners[name] = listener;}});
  function storage(values) {
    return {
      async get(key) {return {[key]: values[key]};},
      async set(value) {Object.assign(values, value);},
      async remove(key) {delete values[key];},
      async setAccessLevel(value) {assert.equal(value.accessLevel, 'TRUSTED_CONTEXTS');},
    };
  }
  globalThis.chrome = {
    runtime: {
      id: 'test-extension', getURL: path => `chrome-extension://test-extension/${path}`,
      onMessage: event('message'), onInstalled: event('installed'), onStartup: event('startup'),
    },
    storage: {local: storage(local), session: storage(session), onChanged: event('changed')},
    action: {
      async setBadgeText(value) {actions.text = value.text;},
      async setBadgeBackgroundColor(value) {actions.color = value.color;},
      async setTitle(value) {actions.title = value.title;},
    },
    alarms: {async create() {}, onAlarm: event('alarm')},
  };
  const apiURL = `data:text/javascript;base64,${Buffer.from(source).toString('base64')}`;
  const background = (await readFile(new URL('./background.js', import.meta.url), 'utf8'))
    .replace("'./api.js'", JSON.stringify(apiURL));
  try {
    await import(`data:text/javascript;base64,${Buffer.from(background).toString('base64')}`);
    const sender = {id: 'test-extension', url: 'chrome-extension://test-extension/popup.html'};
    const message = value => new Promise(resolve => {
      assert.equal(listeners.message(value, sender, resolve), true);
    });
    assert.equal(listeners.message({type: 'read'}, {...sender, id: 'another-extension'}, () => assert.fail()), undefined);
    assert.equal(listeners.message({type: 'read'}, {...sender, url: 'https://evil.example/'}, () => assert.fail()), undefined);
    assert.equal(listeners.message({type: 'delete'}, sender, () => assert.fail()), undefined);
    assert.deepEqual(await message({type: 'read'}), {snapshot: null});
    assert.equal(actions.text, '');
    local.connection = connection;
    globalThis.fetch = async () => response(quotas);
    const loaded = await message({type: 'read'});
    assert.equal(loaded.online, true);
    assert.deepEqual(loaded.snapshot, quotas);
    assert.equal(session.cached.source, connection.baseURL);
    assert.equal(actions.text, '77%');
    globalThis.fetch = async () => {throw new Error(token);};
    const offline = await message({type: 'read'});
    assert.equal(offline.online, false);
    assert.deepEqual(offline.snapshot, quotas);
    assert.equal(offline.error.includes(token), false);
    assert.equal(actions.text, '!');
    local.connection = {...connection, baseURL: 'http://other-mac.local:8788'};
    assert.equal((await message({type: 'read'})).snapshot, null);
    globalThis.fetch = async () => response({version: 1, refresh: {enabled: false}}, 202);
    assert.match((await message({type: 'refresh'})).error, /qui collecte réellement/);
    assert.match((await message({type: 'display', value: {token: 'ignored'}})).error, /Réglage invalide/);
    delete local.connection;
    await message({type: 'read'});
    assert.equal(session.cached, undefined);
  } finally {
    globalThis.chrome = originalChrome;
    globalThis.fetch = originalFetch;
  }
});

test('dashboard interaction follows provider visibility and detail navigation', async () => {
  const rendererSource = await readFile(new URL('./dashboard.js', import.meta.url), 'utf8');
  const {hitTest, dashboardSummary, drawDashboard} = await import(`data:text/javascript;base64,${Buffer.from(rendererSource).toString('base64')}`);
  assert.equal(hitTest(30, 30, quotas), 'codex');
  assert.equal(hitTest(400, 30, quotas), 'claude');
  const claudeOnly = {...quotas, display: {codex: false, claude: true}};
  assert.equal(hitTest(30, 30, claudeOnly), 'claude');
  assert.equal(hitTest(400, 30, claudeOnly), 'claude');
  assert.equal(hitTest(607, 193, quotas, 'codex'), 'refresh');
  assert.equal(hitTest(30, 30, quotas, 'codex'), 'back');
  assert.equal(hitTest(-1, 30, quotas), null);
  assert.equal(hitTest(NaN, 30, quotas), null);
  assert.match(dashboardSummary(quotas), /Codex.*77%/);
  assert.match(dashboardSummary(quotas, {online: false}), /hors ligne/);
  assert.doesNotMatch(dashboardSummary(claudeOnly), /Codex/);
  const resets = {...quotas, providers: {...quotas.providers, codex: {
    ...quotas.providers.codex, error_reason: 'authentication_required',
    banked_resets: {available_count: 2, expirations: [{expires_at: NaN}, {expires_at: -1}, {expires_at: 'invalid'}]},
  }}};
  const summary = dashboardSummary(resets, {detail: 'codex'});
  assert.match(summary, /2 resets en banque/);
  assert.match(summary, /Dates d’expiration non fournies/);
  assert.match(summary, /connexion requise sur le Mac source/);
  // Exercise the drawing paths without needing a browser or a canvas dependency.
  let fills = 0;
  const ctx = new Proxy({measureText: text => ({width: String(text).length * 7}), fillRect() {fills++;}}, {
    get(target, key) {return key in target ? target[key] : () => {};},
  });
  const canvas = {getContext: () => ctx, width: 0, height: 0};
  drawDashboard(canvas, quotas, {now: 1700000000});
  drawDashboard(canvas, claudeOnly, {online: false});
  drawDashboard(canvas, resets, {detail: 'codex'});
  assert.equal(canvas.width, 640);
  assert.equal(canvas.height, 250);
  assert.ok(fills > 0);
});

test('manifest is a client-only MV3 package with optional host access', async () => {
  const manifest = JSON.parse(await readFile(new URL('./manifest.json', import.meta.url), 'utf8'));
  assert.equal(manifest.manifest_version, 3);
  assert.equal(manifest.background.type, 'module');
  assert.deepEqual(manifest.permissions, ['storage', 'alarms']);
  assert.deepEqual(manifest.optional_host_permissions, ['http://*/*', 'https://*/*']);
  assert.equal(manifest.host_permissions, undefined);
  assert.equal(manifest.content_scripts, undefined);
  assert.equal(manifest.externally_connectable, undefined);
  for (const path of [manifest.background.service_worker, manifest.action.default_popup,
    ...new Set(Object.values(manifest.icons))]) await readFile(new URL(path, import.meta.url));
});
