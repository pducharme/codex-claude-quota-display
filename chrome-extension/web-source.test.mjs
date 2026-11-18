import {readFile} from 'node:fs/promises';
import assert from 'node:assert/strict';
import test from 'node:test';
import {sourceMode} from './web-source.js';
import {WEB_SERVICES} from './web-providers.js';

const accountA = '11111111-1111-1111-1111-111111111111';
const accountB = '22222222-2222-2222-2222-222222222222';
const platformToken = 'sess-test-token-0123456789';
const credentials = {token: platformToken, organization: 'org-First'};
const extensionSender = {id: 'test-extension', url: 'chrome-extension://test-extension/popup.html'};
const platformSender = {id: 'test-extension', url: 'https://platform.openai.com/settings/organization/billing/overview', frameId: 0, tab: {id: 7}};
let moduleID = 0;

// Exercise the actual worker and collectors; only browser APIs, network responses and time are simulated.
async function harness(t, settings = {}) {
  const original = {chrome: globalThis.chrome, fetch: globalThis.fetch, now: Date.now};
  const local = structuredClone(settings), session = {}, listeners = {}, calls = [], removals = [], scripts = new Map();
  const origins = new Set(), permissions = new Set(), cookies = new Map();
  let now = 1800000000, network = async () => {throw new Error('Unexpected network request');};
  const event = name => ({addListener(listener) {listeners[name] = listener;}});
  function storage(values) {
    return {
      async get(keys) {
        if (keys == null) return structuredClone(values);
        const list = typeof keys === 'string' ? [keys] : Array.isArray(keys) ? keys : Object.keys(keys);
        return structuredClone(Object.fromEntries(list.map(key => [key, Object.hasOwn(values, key) ? values[key] :
          typeof keys === 'object' && !Array.isArray(keys) ? keys[key] : undefined])));
      },
      async set(value) {Object.assign(values, structuredClone(value));},
      async remove(keys) {for (const key of Array.isArray(keys) ? keys : [keys]) delete values[key];},
      async setAccessLevel(value) {assert.equal(value.accessLevel, 'TRUSTED_CONTEXTS');},
    };
  }
  globalThis.chrome = {
    runtime: {id: extensionSender.id, getURL: path => `chrome-extension://test-extension/${path}`,
      onMessage: event('message'), onInstalled: event('installed'), onStartup: event('startup')},
    storage: {local: storage(local), session: storage(session), onChanged: event('storage')},
    action: {async setBadgeText() {}, async setBadgeBackgroundColor() {}, async setTitle() {}},
    alarms: {async create() {}, onAlarm: event('alarm')},
    permissions: {
      async contains(value) {return (value.origins || []).every(origin => origins.has(origin)) &&
        (value.permissions || []).every(permission => permissions.has(permission));},
      async remove(value) {
        removals.push(structuredClone(value));
        for (const origin of value.origins || []) origins.delete(origin);
        for (const permission of value.permissions || []) permissions.delete(permission);
        return true;
      },
      onAdded: event('permissions-added'), onRemoved: event('permissions-removed'),
    },
    cookies: {async get({url, name}) {const value = cookies.get(`${url}|${name}`); return value == null ? null : {value};},
      onChanged: event('cookie')},
    scripting: {
      async getRegisteredContentScripts() {return [...scripts.values()];},
      async registerContentScripts(values) {for (const value of values) scripts.set(value.id, structuredClone(value));},
      async unregisterContentScripts({ids}) {for (const id of ids) scripts.delete(id);},
    },
    tabs: {async query() {return [];}, async sendMessage() {}},
  };
  Date.now = () => now * 1000;
  globalThis.fetch = async (url, options) => {calls.push({url, options}); return network(url, options);};
  t.after(() => {globalThis.chrome = original.chrome; globalThis.fetch = original.fetch; Date.now = original.now;});
  const background = (await readFile(new URL('./background.js', import.meta.url), 'utf8'))
    .replace("'./api.js'", JSON.stringify(new URL('./api.js', import.meta.url).href))
    .replace("'./web-source.js'", JSON.stringify(new URL('./web-source.js', import.meta.url).href));
  await import(`data:text/javascript;base64,${Buffer.from(`${background}\n// test instance ${moduleID++}`).toString('base64')}`);
  return {
    local, session, listeners, calls, removals, scripts, origins, permissions, cookies,
    advance(seconds) {now += seconds;},
    get now() {return now;},
    network(value) {network = value;},
    allow(key) {for (const origin of WEB_SERVICES[key].origins) origins.add(origin);
      for (const permission of WEB_SERVICES[key].permissions) permissions.add(permission);},
    send(message, sender = extensionSender) {
      return new Promise(resolve => {if (listeners.message(message, sender, resolve) !== true) resolve(undefined);});
    },
  };
}
const response = (body, status = 200) => ({status, ok: status >= 200 && status < 300,
  text: async () => JSON.stringify(body), json: async () => structuredClone(body)});
function codexNetwork(h, account = accountA, used = 23) {
  h.network(async url => {
    if (url === 'https://chatgpt.com/api/auth/session') return response({accessToken: 'ephemeral-codex-token', account: {id: account}});
    if (url === 'https://chatgpt.com/backend-api/wham/usage') return response({account_id: account, plan_type: 'pro',
      rate_limit: {primary_window: {used_percent: used, limit_window_seconds: 18000, reset_at: h.now + 3600}}});
    if (url === 'https://chatgpt.com/backend-api/wham/rate-limit-reset-credits') return response({account_id: account, credits: []});
    assert.fail(`Unexpected URL: ${url}`);
  });
}
function platformNetwork(h) {
  h.network(async url => {
    assert.equal(url, 'https://api.openai.com/v1/dashboard/billing/credit_grants');
    return response({grants: {data: [{id: 'chatgpt_api_credits_promo_test', grant_amount: 96, used_amount: 1,
      effective_at: h.now - 100, expires_at: h.now + 86400, is_scheduled: false, is_held_for_prepaid_transition: false}]}});
  });
}

test('source selection preserves existing Mac setups and defaults new users to web', () => {
  assert.equal(sourceMode({}), 'web');
  assert.equal(sourceMode({connection: {baseURL: 'http://mac.local:8788'}}), 'mac');
  assert.equal(sourceMode({sourceMode: 'web', connection: {}}), 'web');
  assert.equal(sourceMode({sourceMode: 'mac'}), 'mac');
});

test('web mode works without a Mac connection and never falls back to a saved Mac', async t => {
  const h = await harness(t);
  let result = await h.send({type: 'read'});
  assert.equal(result.snapshot.source_mode, 'web');
  assert.equal(result.snapshot.refresh.enabled, true);
  assert.equal(result.snapshot.refresh.completed_at, null);
  assert.equal(h.calls.length, 0);
  h.local.sourceMode = 'web';
  h.local.connection = {baseURL: 'http://mac.local:8788', token: 'mac-token-0123456789'};
  h.local.webConnected = {codex: true};
  h.allow('codex'); codexNetwork(h);
  result = await h.send({type: 'read'});
  assert.equal(result.snapshot.providers.codex.five_hour.used_percent, 23);
  assert.equal(result.snapshot.refresh.completed_at, h.now);
  assert.ok(h.calls.every(call => new URL(call.url).hostname === 'chatgpt.com'));
  assert.equal(h.session.cached.source, 'web');
});

test('background polling respects the five-minute TTL and refresh bypasses it', async t => {
  const h = await harness(t, {sourceMode: 'web', webConnected: {codex: true}});
  h.allow('codex'); codexNetwork(h);
  await h.send({type: 'read'});
  assert.equal(h.calls.length, 3);
  h.advance(299);
  h.listeners.alarm({name: 'quota-read'});
  await h.send({type: 'read'}); // Queue behind the alarm to observe its completed work.
  assert.equal(h.calls.length, 3);
  h.advance(1);
  await h.send({type: 'read'});
  assert.equal(h.calls.length, 6);
  await h.send({type: 'refresh'});
  assert.equal(h.calls.length, 9);
  assert.equal(h.session.webCaptures.codex.data.updated_at, h.now);
});

test('credits expiring between polls refresh immediately, then back off after a network failure', async t => {
  const h = await harness(t, {sourceMode: 'web', webConnected: {openaiCredits: true}, platformCredentials: credentials});
  h.allow('openaiCredits');
  h.session.webCaptures = {openaiCredits: {identity: credentials.organization, last_attempt: h.now - 60,
    data: {status: 'ok', updated_at: h.now - 60, currency: 'USD', monthly: 80, monthly_granted: 96, expires_at: h.now - 1}}};
  h.network(async () => {throw new Error('offline at credit expiration');});
  let result = await h.send({type: 'read'});
  assert.equal(h.calls.length, 1); // Expiration overrides the still-valid five-minute cache.
  assert.equal(result.snapshot.providers.codex.api_credits.status, 'stale');
  assert.equal(result.snapshot.providers.codex.api_credits.monthly, 80);
  assert.equal(h.session.webCaptures.openaiCredits.last_attempt, h.now);
  await h.send({type: 'read'});
  h.advance(299);
  result = await h.send({type: 'read'});
  assert.equal(h.calls.length, 1); // The expired date must not cause a retry on every read.
  assert.equal(result.snapshot.web_services.openaiCredits.status, 'stale');
  h.advance(1);
  platformNetwork(h);
  result = await h.send({type: 'read'});
  assert.equal(h.calls.length, 2);
  assert.equal(result.snapshot.providers.codex.api_credits.status, 'ok');
  assert.equal(result.snapshot.providers.codex.api_credits.monthly, 95);
});

test('network failures retain stale data, while authentication failures erase it and sanitize errors', async t => {
  const h = await harness(t, {webConnected: {codex: true}});
  h.allow('codex'); codexNetwork(h);
  await h.send({type: 'read'});
  h.network(async () => {throw new Error('secret-network-details');});
  let result = await h.send({type: 'refresh'});
  assert.equal(result.snapshot.providers.codex.status, 'stale');
  assert.equal(result.snapshot.providers.codex.five_hour.used_percent, 23);
  assert.doesNotMatch(JSON.stringify(result), /secret-network-details/);
  h.network(async () => response({}, 401));
  result = await h.send({type: 'refresh'});
  assert.equal(result.snapshot.providers.codex.status, 'unavailable');
  assert.equal(result.snapshot.providers.codex.error_reason, 'authentication_required');
  assert.equal(result.snapshot.providers.codex.five_hour, undefined);
  assert.equal(h.session.webCaptures.codex.data, undefined);
});

test('selected account changes erase old data before an unsuccessful read and isolate the next account', async t => {
  const h = await harness(t, {webConnected: {codex: true}});
  h.allow('codex'); codexNetwork(h);
  await h.send({type: 'read'});
  h.cookies.set('https://chatgpt.com|_account', accountB);
  h.network(async () => {throw new Error('offline after switching accounts');});
  h.listeners.cookie({cookie: {domain: '.chatgpt.com', name: '_account', value: accountB}, removed: false, cause: 'explicit'});
  const failed = await h.send({type: 'read'});
  assert.equal(failed.snapshot.providers.codex.status, 'unavailable');
  assert.equal(failed.snapshot.providers.codex.five_hour, undefined);
  assert.equal(h.session.webCaptures.codex.identity, undefined);
  codexNetwork(h, accountB, 42);
  const loaded = await h.send({type: 'refresh'});
  assert.equal(h.session.webCaptures.codex.identity, accountB);
  assert.equal(loaded.snapshot.providers.codex.five_hour.used_percent, 42);
  assert.equal(JSON.stringify(loaded).includes(accountA), false);
});

test('Claude organization changes and session removal clear only the affected service', async t => {
  const h = await harness(t, {webConnected: {codex: true, claude: true, claudeCredits: true}});
  for (const key of ['codex', 'claude', 'claudeCredits']) {
    h.allow(key);
    h.session.webCaptures ??= {};
    h.session.webCaptures[key] = {identity: accountA, last_attempt: h.now,
      data: {updated_at: h.now, five_hour: {used_percent: 23}}};
  }
  h.cookies.set('https://claude.ai|lastActiveOrg', accountB);
  h.network(async () => {throw new Error('offline');});
  h.listeners.cookie({cookie: {domain: 'claude.ai', name: 'lastActiveOrg', value: accountB}, removed: false, cause: 'explicit'});
  let result = await h.send({type: 'read'});
  assert.equal(result.snapshot.providers.claude.five_hour, undefined);
  assert.equal(h.session.webCaptures.codex.identity, accountA);
  assert.equal(h.session.webCaptures.claudeCredits.identity, accountA);
  h.listeners.cookie({cookie: {domain: '.chatgpt.com', name: '__Secure-next-auth.session-token'}, removed: true, cause: 'explicit'});
  result = await h.send({type: 'read'});
  assert.equal(result.snapshot.providers.codex.five_hour, undefined);
  assert.equal(h.session.webCaptures.claudeCredits.identity, accountA);
});

test('refused permissions prevent connection and revoked permissions erase cached quotas', async t => {
  const h = await harness(t);
  assert.match((await h.send({type: 'connect-web', value: 'codex'})).error, /autorisé/);
  assert.equal(h.local.webConnected, undefined);
  assert.equal(h.calls.length, 0);
  h.allow('codex'); codexNetwork(h);
  assert.deepEqual(await h.send({type: 'connect-web', value: 'codex'}), {connected: true, needsLogin: false});
  h.origins.delete(WEB_SERVICES.codex.origins[0]);
  const previousCalls = h.calls.length;
  h.listeners['permissions-removed']({origins: WEB_SERVICES.codex.origins});
  const result = await h.send({type: 'read'});
  assert.equal(h.calls.length, previousCalls);
  assert.equal(result.snapshot.providers.codex.error_reason, 'permission_required');
  assert.equal(result.snapshot.providers.codex.five_hour, undefined);
  assert.equal(h.session.webCaptures.codex.data, undefined);
});

test('disconnect removes Platform credentials and capture while retaining scopes needed by Mac and other services', async t => {
  const connection = {baseURL: 'https://platform.openai.com', token: 'mac-token-0123456789'};
  const h = await harness(t, {sourceMode: 'web', connection, webConnected: {openaiCredits: true, codex: true}, platformCredentials: credentials});
  h.allow('openaiCredits'); h.allow('codex');
  h.session.webCaptures = {openaiCredits: {identity: 'org-First'}, codex: {identity: accountA}};
  h.session.cached = {source: 'web', snapshot: {providers: {codex: {api_credits: {monthly: 95}}}}};
  h.session.pendingPlatformAuth = h.now + 600;
  assert.deepEqual(await h.send({type: 'disconnect-web', value: 'openaiCredits'}), {disconnected: true});
  assert.equal(h.local.platformCredentials, undefined);
  assert.equal(h.session.pendingPlatformAuth, undefined);
  assert.equal(h.session.webCaptures.openaiCredits, undefined);
  assert.equal(h.session.cached, undefined);
  assert.equal(h.session.webCaptures.codex.identity, accountA);
  assert.equal(h.local.webConnected.openaiCredits, false);
  assert.deepEqual(h.local.connection, connection);
  assert.equal(h.origins.has('https://platform.openai.com/*'), true);
  assert.equal(h.origins.has('https://api.openai.com/*'), false);
  assert.equal(h.origins.has('https://chatgpt.com/*'), true);
  assert.equal(h.permissions.has('cookies'), true);
  assert.equal(h.permissions.has('scripting'), false);
  assert.equal(h.calls.length, 0);
});

test('Platform connection installs temporary capture only when login is needed, then stores a verified credential', async t => {
  const h = await harness(t);
  h.allow('openaiCredits'); platformNetwork(h);
  assert.deepEqual(await h.send({type: 'connect-web', value: 'openaiCredits'}), {connected: true, needsLogin: true});
  assert.equal(h.session.pendingPlatformAuth, h.now + 600);
  assert.equal(h.scripts.size, 2);
  for (const script of h.scripts.values()) {
    assert.deepEqual(script.matches, ['https://platform.openai.com/*']);
    assert.equal(script.persistAcrossSessions, false);
    assert.equal(script.allFrames, false);
  }
  assert.deepEqual(await h.send({type: 'platform-auth', credentials}, platformSender), {accepted: true});
  assert.deepEqual(h.local.platformCredentials, credentials);
  assert.equal(h.session.pendingPlatformAuth, undefined);
  assert.equal(h.scripts.size, 0);
  const verifiedCalls = h.calls.length;
  assert.deepEqual(await h.send({type: 'platform-auth', credentials}, platformSender), {accepted: false});
  assert.equal(h.calls.length, verifiedCalls);
  const result = await h.send({type: 'read'});
  assert.equal(result.snapshot.providers.codex.api_credits.monthly_granted, 96);
  assert.equal(result.snapshot.providers.codex.api_credits.monthly, 95);
  assert.doesNotMatch(JSON.stringify(result), new RegExp(platformToken));
  assert.deepEqual(await h.send({type: 'connect-web', value: 'openaiCredits'}), {connected: true, needsLogin: false});
  assert.equal(h.session.pendingPlatformAuth, undefined);
  assert.equal(h.scripts.size, 0);
});

test('Platform credentials require a top-level trusted sender, explicit connection and an unexpired ten-minute window', async t => {
  const h = await harness(t, {sourceMode: 'web', webConnected: {openaiCredits: true}});
  h.allow('openaiCredits'); platformNetwork(h);
  const message = {type: 'platform-auth', credentials};
  assert.deepEqual(await h.send(message, platformSender), {accepted: false});
  await h.send({type: 'connect-web', value: 'openaiCredits'});
  for (const sender of [extensionSender, {...platformSender, frameId: 1}, {...platformSender, tab: {}},
    {...platformSender, url: 'https://platform.openai.com.evil.example/'}, {...platformSender, url: 'http://platform.openai.com/'},
    {...platformSender, url: 'https://api.openai.com/'}, {...platformSender, url: 'invalid'}]) {
    assert.deepEqual(await h.send(message, sender), {accepted: false});
  }
  assert.equal(await h.send(message, {...platformSender, id: 'other-extension'}), undefined);
  assert.deepEqual(await h.send({type: 'platform-auth', credentials: {...credentials, token: 'bad'}}, platformSender), {accepted: false});
  h.local.webConnected.openaiCredits = false;
  assert.deepEqual(await h.send(message, platformSender), {accepted: false});
  h.local.webConnected.openaiCredits = true;
  h.local.sourceMode = 'mac';
  assert.deepEqual(await h.send(message, platformSender), {accepted: false});
  h.local.sourceMode = 'web';
  assert.equal(h.calls.length, 0);
  h.advance(601);
  assert.deepEqual(await h.send(message, platformSender), {accepted: false});
  assert.equal(h.local.platformCredentials, undefined);
  await h.send({type: 'read'});
  assert.equal(h.session.pendingPlatformAuth, undefined);
  assert.equal(h.scripts.size, 0);
});

test('Platform authentication and permission revocation remove persisted session credentials', async t => {
  const h = await harness(t, {sourceMode: 'web', webConnected: {openaiCredits: true}, platformCredentials: credentials});
  h.allow('openaiCredits'); platformNetwork(h);
  await h.send({type: 'read'});
  h.network(async () => response({}, 401));
  let result = await h.send({type: 'refresh'});
  assert.equal(h.local.platformCredentials, undefined);
  assert.equal(result.snapshot.providers.codex.api_credits.monthly, undefined);
  assert.equal(result.snapshot.web_services.openaiCredits.error_reason, 'authentication_required');
  h.local.platformCredentials = structuredClone(credentials);
  h.origins.delete('https://api.openai.com/*');
  h.listeners['permissions-removed']({origins: ['https://api.openai.com/*']});
  result = await h.send({type: 'read'});
  assert.equal(h.local.platformCredentials, undefined);
  assert.equal(result.snapshot.web_services.openaiCredits.error_reason, 'permission_required');
});

test('web display preferences remain local and reject sleep or hiding both providers', async t => {
  const h = await harness(t, {sourceMode: 'web', connection: {baseURL: 'http://mac.local:8788', token: 'mac-token-0123456789'}});
  const result = await h.send({type: 'display', value: {codex: false}});
  assert.deepEqual(result.snapshot.display, {codex: false, claude: true});
  assert.deepEqual(h.local.webDisplay, {codex: false});
  assert.match((await h.send({type: 'display', value: {sleep: {enabled: true}}})).error, /veille.*Companion Mac/);
  assert.match((await h.send({type: 'display', value: {claude: false}})).error, /au moins un fournisseur/);
  assert.match((await h.send({type: 'display', value: {codex: 'false'}})).error, /Réglage invalide/);
  assert.deepEqual(h.local.webDisplay, {codex: false});
  assert.equal(h.calls.length, 0);
});
