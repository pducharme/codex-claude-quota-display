import {readFile} from 'node:fs/promises';
import assert from 'node:assert/strict';
import test from 'node:test';
import vm from 'node:vm';
import {setImmediate} from 'node:timers/promises';

const mainScript = await readFile(new URL('./platform-auth.js', import.meta.url), 'utf8');
const forwardScript = await readFile(new URL('./platform-forward.js', import.meta.url), 'utf8');
const origin = 'https://platform.openai.com';
const endpoint = 'https://api.openai.com/v1/dashboard/billing/credit_grants';
const token = 'sess-test-session-token';
const headers = {Authorization: `Bearer ${token}`, 'OpenAI-Organization': 'org-test123',
  'X-Private-Header': 'never-forward-this', 'Cookie': 'never-forward-this'};
const expected = {type: 'platform-auth', credentials: {token, organization: 'org-test123'}};

function harness({pageOrigin = origin, top = true, withForward = true, fetcher} = {}) {
  const messages = [], forwarded = [], calls = [], listeners = new Set(), runtimeListeners = new Set(), timers = new Map();
  let now = 1000000, nextTimer = 0;
  const originalFetch = function(...args) {
    calls.push({receiver: this, args});
    return fetcher ? fetcher(...args) : Promise.resolve(new Response('{"private":"unread"}'));
  };
  const window = {
    fetch: originalFetch,
    addEventListener(type, listener) { assert.equal(type, 'message'); listeners.add(listener); },
    removeEventListener(type, listener) { assert.equal(type, 'message'); listeners.delete(listener); },
    postMessage(message, target) {
      messages.push(JSON.parse(JSON.stringify(message)));
      assert.equal(target, origin);
      queueMicrotask(() => {
        for (const listener of [...listeners]) listener({data: message, origin: pageOrigin, source: window});
      });
    },
  };
  window.top = top ? window : {};
  const runtime = {
    id: 'extension-id',
    sendMessage(value) { forwarded.push(JSON.parse(JSON.stringify(value))); return Promise.resolve({ok: true}); },
    onMessage: {addListener(fn) { runtimeListeners.add(fn); }, removeListener(fn) { runtimeListeners.delete(fn); }},
  };
  const context = vm.createContext({window, location: {origin: pageOrigin, href: `${pageOrigin}/settings/organization/billing/credit-grants`},
    chrome: {runtime}, URL, Headers, Request, Response, Date: {now: () => now},
    setTimeout(fn, delay) { assert.equal(delay, 600000); const id = ++nextTimer; timers.set(id, fn); return id; },
    clearTimeout(id) { timers.delete(id); }});
  if (withForward) vm.runInContext(forwardScript, context);
  vm.runInContext(mainScript, context);
  return {window, messages, forwarded, calls, listeners, runtimeListeners, timers, originalFetch, context,
    setNow(value) { now = value; },
    send(data, eventOrigin = pageOrigin, source = window) {
      for (const listener of [...listeners]) listener({data, origin: eventOrigin, source});
    },
    stop(sender = {id: runtime.id}) {
      for (const listener of [...runtimeListeners]) listener({type: 'quota-platform-stop'}, sender, () => {});
    },
    expire() { for (const fn of [...timers.values()]) fn(); },
  };
}

async function flush() { await setImmediate(); await setImmediate(); }

test('one successful GET forwards only the session token and organization and restores fetch', async () => {
  const response = new Response('{"secret_body":"never-forward-this"}');
  const pending = Promise.resolve(response);
  const env = harness({fetcher: () => pending});
  assert.equal(env.window.fetch(endpoint, {headers}), pending);
  assert.equal(env.calls[0].receiver, env.window);
  assert.deepEqual(env.calls[0].args, [endpoint, {headers}]);
  await flush();
  assert.deepEqual(env.forwarded, [expected]);
  assert.deepEqual(env.messages, [{type: 'quota-platform-auth', token, organization: 'org-test123'}, {type: 'quota-platform-stop'}]);
  assert.doesNotMatch(JSON.stringify(env.messages), /Authorization|Cookie|X-Private|never-forward|secret_body/);
  assert.equal(response.bodyUsed, false);
  assert.deepEqual(await response.json(), {secret_body: 'never-forward-this'});
  assert.equal(env.window.fetch, env.originalFetch);
  assert.equal(env.listeners.size, 0);
  assert.equal(env.runtimeListeners.size, 0);
  assert.equal(env.timers.size, 0);
  await env.window.fetch(endpoint, {headers});
  await flush();
  assert.equal(env.forwarded.length, 1);
});

test('only exact Platform top-frame origin and the strict successful GET are observed', async () => {
  for (const pageOrigin of ['http://platform.openai.com', 'https://platform.openai.com.evil.test', 'https://api.openai.com', 'https://chatgpt.com']) {
    const env = harness({pageOrigin});
    assert.equal(env.window.fetch, env.originalFetch);
    assert.equal(env.timers.size, 0);
  }
  const child = harness({top: false});
  assert.equal(child.window.fetch, child.originalFetch);
  for (const input of [endpoint + '?x=1', endpoint + '#fragment', endpoint + '/', endpoint.replace('https:', 'http:'), endpoint.replace('api.openai.com', 'evil.test')]) {
    const env = harness();
    await env.window.fetch(input, {headers});
    await flush();
    assert.deepEqual(env.forwarded, [], input);
  }
  for (const method of ['POST', 'PUT', 'DELETE', 'HEAD']) {
    const env = harness();
    await env.window.fetch(endpoint, {headers, method});
    await flush();
    assert.deepEqual(env.forwarded, [], method);
  }
  for (const status of [201, 302, 401, 403, 429, 500]) {
    const env = harness({fetcher: () => Promise.resolve(new Response('', {status}))});
    await env.window.fetch(endpoint, {headers});
    await flush();
    assert.deepEqual(env.forwarded, [], String(status));
  }
  for (const response of [{status: 200, redirected: true, url: endpoint}, {status: 200, redirected: false, url: 'https://evil.test/'}]) {
    const env = harness({fetcher: () => Promise.resolve(response)});
    await env.window.fetch(endpoint, {headers});
    await flush();
    assert.deepEqual(env.forwarded, []);
  }
});

test('supports Request and URL input and honors explicit method/header overrides', async () => {
  for (const [input, init] of [[new Request(endpoint, {headers}), undefined], [new URL(endpoint), {headers}],
    [new Request(endpoint, {method: 'POST', headers}), {method: 'GET', headers}]]) {
    const env = harness();
    await env.window.fetch(input, init);
    await flush();
    assert.deepEqual(env.forwarded, [expected]);
  }
  const env = harness();
  await env.window.fetch(new Request(endpoint, {headers}), {headers: {}});
  await flush();
  assert.deepEqual(env.forwarded, []);
});

test('rejects static API keys, malformed sessions and organizations', async () => {
  const invalidHeaders = [
    {}, {...headers, Authorization: 'Bearer sk-static-api-key'}, {...headers, Authorization: 'Basic sess-test'},
    {...headers, Authorization: 'Bearer sess-'}, {...headers, Authorization: 'Bearer sess-a b'},
    {...headers, Authorization: 'Bearer sess-' + 'a'.repeat(8193)},
    {...headers, 'OpenAI-Organization': 'someone@example.test'}, {...headers, 'OpenAI-Organization': 'org-'},
    {...headers, 'OpenAI-Organization': 'org-' + 'a'.repeat(125)},
  ];
  for (const inputHeaders of invalidHeaders) {
    const env = harness();
    await env.window.fetch(endpoint, {headers: inputHeaders});
    await flush();
    assert.deepEqual(env.forwarded, []);
  }
});

test('forwarder enforces source, origin and the complete message schema', async () => {
  const valid = {type: 'quota-platform-auth', token, organization: 'org-test123'};
  const env = harness();
  env.send(valid, 'https://evil.test');
  env.send(valid, origin, {});
  for (const value of [null, [], {...valid, extra: 'secret'}, {...valid, token: 'sk-static'}, {...valid, token: null},
    {...valid, organization: 'org-bad@example'}, {...valid, type: 'other'}]) env.send(value);
  await flush();
  assert.deepEqual(env.forwarded, []);
  env.send(valid);
  await flush();
  assert.deepEqual(env.forwarded, [expected]);
});

test('stop and deadline suppress pending responses, remove handlers and do not poll', async () => {
  for (const finish of [env => env.stop(), env => env.expire(), env => env.setNow(1600000)]) {
    let resolve;
    const pending = new Promise(done => { resolve = done; });
    const env = harness({fetcher: () => pending});
    env.window.fetch(endpoint, {headers});
    finish(env);
    await flush();
    resolve(new Response('{}'));
    await pending;
    await flush();
    assert.deepEqual(env.forwarded, []);
    assert.equal(env.calls.length, 1, 'no timer or message makes a network request');
    env.expire();
    await flush();
    assert.equal(env.window.fetch, env.originalFetch);
    assert.equal(env.listeners.size, 0);
    assert.equal(env.runtimeListeners.size, 0);
    assert.equal(env.timers.size, 0);
  }
  const env = harness();
  env.stop({id: 'another-extension'});
  assert.notEqual(env.window.fetch, env.originalFetch);
  env.send({type: 'quota-platform-stop'}, 'https://evil.test');
  assert.notEqual(env.window.fetch, env.originalFetch);
});

test('duplicate injections are idempotent and simultaneous successes capture once', async () => {
  let resolve;
  const pending = new Promise(done => { resolve = done; });
  const env = harness({fetcher: () => pending});
  const wrapped = env.window.fetch;
  vm.runInContext(forwardScript, env.context);
  vm.runInContext(mainScript, env.context);
  assert.equal(env.window.fetch, wrapped);
  assert.equal(env.timers.size, 2);
  env.window.fetch(endpoint, {headers});
  env.window.fetch(endpoint, {headers});
  resolve(new Response('{}'));
  await flush();
  assert.deepEqual(env.forwarded, [expected]);
});

test('network failures preserve the original rejection and publish no credentials', async () => {
  const failure = new Error('private network error');
  const pending = Promise.reject(failure);
  const env = harness({fetcher: () => pending});
  assert.equal(env.window.fetch(endpoint, {headers}), pending);
  await assert.rejects(pending, error => error === failure);
  await flush();
  assert.deepEqual(env.forwarded, []);
  assert.deepEqual(env.messages, []);
});
