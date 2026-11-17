import {readFile} from 'node:fs/promises';
import assert from 'node:assert/strict';
import test from 'node:test';
import vm from 'node:vm';
import {setImmediate} from 'node:timers/promises';

const source = await readFile(new URL('./quota_menu.swift', import.meta.url), 'utf8');
const script = source.match(/static let captureScript = #"""\n([\s\S]*?)\n\s*"""#/)[1];
const endpoint = 'https://api.openai.com/v1/dashboard/billing/credit_grants';
const grant = {id: 'chatgpt_api_credits_promo_test', grant_amount: 96, used_amount: 0,
  effective_at: 1794956400, expires_at: 1795993200, is_scheduled: false,
  is_held_for_prepaid_transition: false};
const body = {grants: {data: [grant]}};
const headers = {'OpenAI-Organization': 'org-test', Authorization: 'Bearer secret-token'};

async function capture({input = endpoint, init = {headers}, payload = body, status = 200,
  origin = 'https://platform.openai.com', failure} = {}) {
  const messages = [];
  const response = failure ? null : new Response(typeof payload === 'string' ? payload : JSON.stringify(payload), {status});
  const pending = failure ? Promise.reject(failure) : Promise.resolve(response);
  let call;
  const originalFetch = function(...args) { call = {receiver: this, args}; return pending; };
  const window = {fetch: originalFetch, webkit: {messageHandlers: {openAICredits: {
    postMessage: value => messages.push(JSON.parse(JSON.stringify(value))),
  }}}};
  vm.runInNewContext(script, {window, location: {origin, href: `${origin}/settings/organization/billing/credit-grants`},
    URL, Headers, Request, Response, TextEncoder});
  assert.equal(window.fetch(input, init), pending, 'must return the original fetch promise');
  assert.equal(call.receiver, window);
  assert.deepEqual(call.args, [input, init], 'must preserve request arguments');
  await pending.catch(() => {});
  await setImmediate();
  await setImmediate();
  return {messages, response, intercepted: window.fetch !== originalFetch};
}

test('captures only grant fields and organization while preserving the response body', async () => {
  const payload = {...body, access_token: 'secret-token', grants: {data: [{...grant, private: 'secret-token'}]}};
  const {messages, response} = await capture({payload});
  assert.deepEqual(messages, [{organization_id: 'org-test', grants: [grant]}]);
  assert.doesNotMatch(JSON.stringify(messages), /secret-token|Authorization|private|access_token/);
  assert.deepEqual(await response.json(), payload);
});

test('requires Platform origin and the exact successful GET endpoint', async () => {
  for (const options of [
    {origin: 'https://platform.openai.com.evil.example'}, {origin: 'http://platform.openai.com'},
    {input: `${endpoint}?extra=1`}, {input: `${endpoint}#fragment`}, {input: `${endpoint}/`},
    {input: endpoint.replace('api.openai.com', 'other.example')}, {input: endpoint.replace('https:', 'http:')},
    {init: {headers, method: 'POST'}}, ...[201, 302, 401, 403, 500].map(status => ({status})),
  ]) assert.deepEqual((await capture(options)).messages, [], JSON.stringify(options));
  assert.equal((await capture({origin: 'https://other.example'})).intercepted, false);
});

test('supports Request and URL inputs and honors init method and header overrides', async () => {
  for (const input of [new Request(endpoint, {headers}), new URL(endpoint)]) {
    assert.equal((await capture({input, init: input instanceof Request ? null : {headers}})).messages[0].organization_id, 'org-test');
  }
  const input = new Request(endpoint, {method: 'POST', headers});
  const init = {method: 'GET', headers: {'OpenAI-Organization': 'org-override'}};
  assert.equal((await capture({input, init})).messages[0].organization_id, 'org-override');
  assert.deepEqual((await capture({input: new Request(endpoint, {headers}), init: {method: 'POST'}})).messages, []);
  assert.equal((await capture({input, init: {...init, headers: {}}})).messages[0].organization_id, null);
});

test('isolates malformed responses and network errors from the page fetch', async () => {
  for (const payload of ['{invalid', null, {}, {grants: {}}, {grants: {data: [null]}},
    {grants: {data: Array(1001).fill(grant)}}]) {
    assert.deepEqual((await capture({payload})).messages, []);
  }
  assert.deepEqual((await capture({failure: new Error('network unavailable')})).messages, []);
});

test('rejects response bodies above 1 MiB, including multibyte JSON', async () => {
  const base = {...body, padding: ''};
  base.padding = 'x'.repeat(1048576 - Buffer.byteLength(JSON.stringify(base)));
  assert.equal((await capture({payload: base})).messages.length, 1);
  for (const padding of ['x'.repeat(1048577), 'é'.repeat(600000)]) {
    const payload = {...body, padding};
    assert.ok(Buffer.byteLength(JSON.stringify(payload)) > 1048576);
    assert.deepEqual((await capture({payload})).messages, []);
  }
});
