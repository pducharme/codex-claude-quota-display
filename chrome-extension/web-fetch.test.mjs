import {readFile} from 'node:fs/promises';
import assert from 'node:assert/strict';
import test from 'node:test';

const providerSource = await readFile(new URL('./web-providers.js', import.meta.url), 'utf8');
const providerURL = `data:text/javascript;base64,${Buffer.from(providerSource).toString('base64')}`;
const source = (await readFile(new URL('./web-fetch.js', import.meta.url), 'utf8'))
  .replace("'./web-providers.js'", JSON.stringify(providerURL));
const {fetchWebService} = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
const account = '00000000-0000-4000-8000-000000000001';
const secondAccount = '00000000-0000-4000-8000-000000000002';
const now = 1794931200;
const jwt = (id, extra = '') => `eyJhbGciOiJub25lIn0.${Buffer.from(JSON.stringify({
  'https://api.openai.com/auth': {chatgpt_account_id: id}, extra,
})).toString('base64url')}.signature`;
const accessToken = jwt(account);
const usage = {account_id: account, plan_type: 'pro', rate_limit: {primary_window: {
  used_percent: 23, limit_window_seconds: 604800, reset_at: now + 604800}}, rate_limit_reset_credits: {available_count: 2}};
const response = (value, status = 200) => new Response(JSON.stringify(value), {status, headers: {'Content-Type': 'application/json'}});
const sessionURL = 'https://chatgpt.com/api/auth/session';
const usageURL = 'https://chatgpt.com/backend-api/wham/usage';
const resetsURL = 'https://chatgpt.com/backend-api/wham/rate-limit-reset-credits';
const cookie = value => ({get: async () => value == null ? null : {value}});
function mockFetch(replies) {
  const calls = [];
  const fetcher = async (url, options) => {
    calls.push({url, options});
    assert.equal(options.method, 'GET');
    assert.equal(options.redirect, 'error');
    assert.equal(options.cache, 'no-store');
    assert.equal(options.headers.Accept, 'application/json');
    assert.ok(options.signal instanceof AbortSignal);
    const reply = replies.shift();
    if (reply instanceof Error) throw reply;
    assert.ok(reply, `Unexpected request ${url}`);
    return reply;
  };
  return {fetcher, calls};
}
const reason = expected => error => {
  assert.equal(error.reason, expected);
  assert.doesNotMatch(error.message, /private-secret|sess-test-secret|Bearer|https?:\/\//);
  return true;
};

test('Codex uses browser session then fixed WHAM GETs, and keeps credentials out of results', async () => {
  const {fetcher, calls} = mockFetch([response({accessToken}), response(usage), response({credits: []})]);
  const cookies = {get: async details => {
    assert.deepEqual(details, {url: 'https://chatgpt.com', name: '_account'});
    return {value: account};
  }};
  const result = await fetchWebService('codex', {fetcher, cookies}, now);
  assert.deepEqual(calls.map(call => call.url), [sessionURL, usageURL, resetsURL]);
  assert.ok(calls.every(call => call.options.credentials === 'include'));
  assert.equal(calls[0].options.headers.Authorization, undefined);
  for (const call of calls.slice(1)) {
    assert.equal(call.options.headers.Authorization, `Bearer ${accessToken}`);
    assert.equal(call.options.headers['ChatGPT-Account-Id'], account);
  }
  assert.equal(result.identity, account);
  assert.equal(result.data.weekly.used_percent, 23);
  assert.equal(result.data.updated_at, now);
  assert.ok(!JSON.stringify(result).includes(accessToken));
});

test('Codex honors selected account, falls back to session account/JWT and detects account changes', async () => {
  for (const session of [{accessToken: jwt(secondAccount), account: {id: account}}, {accessToken}]) {
    const {fetcher, calls} = mockFetch([response(session), response(usage), response({credits: []})]);
    assert.equal((await fetchWebService('codex', {fetcher, cookies: cookie(null)}, now)).identity, account);
    assert.equal(calls[1].options.headers['ChatGPT-Account-Id'], account);
  }
  const {fetcher, calls} = mockFetch([response({accessToken, account: {id: account}}),
    response({...usage, account_id: secondAccount}), response({credits: []})]);
  assert.equal((await fetchWebService('codex', {fetcher, cookies: cookie(secondAccount)}, now)).identity, secondAccount);
  assert.equal(calls[1].options.headers['ChatGPT-Account-Id'], secondAccount);
  for (const returned of [secondAccount, 'private-secret']) {
    const fake = mockFetch([response({accessToken}), response({...usage, account_id: returned})]);
    await assert.rejects(fetchWebService('codex', {fetcher: fake.fetcher, cookies: cookie(account)}, now), reason('unavailable'));
    assert.equal(fake.calls.length, 2);
  }
});

test('Codex retries one 401 with a new session and never loops on repeated rejection', async () => {
  const refreshed = jwt(account, 'new');
  const {fetcher, calls} = mockFetch([response({accessToken}), response({error: 'private-secret'}, 401),
    response({accessToken: refreshed}), response(usage), response({credits: []})]);
  await fetchWebService('codex', {fetcher, cookies: cookie(account)}, now);
  assert.deepEqual(calls.map(call => call.url), [sessionURL, usageURL, sessionURL, usageURL, resetsURL]);
  assert.equal(calls[3].options.headers.Authorization, `Bearer ${refreshed}`);
  const rejected = mockFetch([response({accessToken}), response({}, 401), response({accessToken: refreshed}), response({}, 401)]);
  await assert.rejects(fetchWebService('codex', {fetcher: rejected.fetcher, cookies: cookie(account)}, now), reason('authentication_required'));
  assert.equal(rejected.calls.length, 4);
});

test('Codex missing session token is authentication-required; optional reset errors retain the quota', async () => {
  for (const accessToken of [undefined, '', 'token\r\nprivate-secret', 'x'.repeat(16385)]) {
    const fake = mockFetch([response({accessToken})]);
    await assert.rejects(fetchWebService('codex', {fetcher: fake.fetcher, cookies: cookie(account)}, now), reason('authentication_required'));
    assert.equal(fake.calls.length, 1);
  }
  for (const resetReply of [response({}, 503), response({account_id: secondAccount, credits: []})]) {
    const {fetcher} = mockFetch([response({accessToken}), response(usage), resetReply]);
    const result = await fetchWebService('codex', {fetcher, cookies: cookie(account)}, now);
    assert.equal(result.data.weekly.used_percent, 23);
    assert.equal(result.data.banked_resets.available_count, 2);
  }
});

test('Claude and Console use only their organization metadata cookie and automatic browser authentication', async () => {
  for (const [key, origin, path, payload] of [
    ['claude', 'https://claude.ai', '/usage?cedar_ember=1&skip_spend=1', {seven_day: {utilization: 12}}],
    ['claudeCredits', 'https://platform.claude.com', '/prepaid/credits', {currency: 'USD', amount_without_scoped_credits: 500, promo_tranches: []}],
  ]) {
    const {fetcher, calls} = mockFetch([response(payload), ...(key === 'claude' ? [response([])] : [])]);
    const cookies = {get: async details => {
      assert.deepEqual(details, {url: origin, name: 'lastActiveOrg'});
      return {value: account};
    }};
    assert.equal((await fetchWebService(key, {fetcher, cookies}, now)).identity, account);
    assert.equal(calls[0].url, `${origin}/api/organizations/${account}${path}`);
    assert.equal(calls.length, key === 'claude' ? 2 : 1);
    for (const call of calls) {
      assert.equal(call.options.credentials, 'include');
      assert.deepEqual(call.options.headers, {Accept: 'application/json'});
    }
  }
});

test('Claude resolves Ultra from the selected organization when usage omits the subscription', async () => {
  const {fetcher, calls} = mockFetch([response({seven_day: {utilization: 12}}), response([
    {uuid: secondAccount, rate_limit_tier: 'default_claude_max_5x'},
    {uuid: account, rate_limit_tier: 'default_claude_max_20x', name: 'private-secret', settings: {private: 'private-secret'}},
  ])]);
  const result = await fetchWebService('claude', {fetcher, cookies: cookie(account)}, now);
  assert.deepEqual(calls.map(call => call.url), [
    `https://claude.ai/api/organizations/${account}/usage?cedar_ember=1&skip_spend=1`,
    'https://claude.ai/api/organizations',
  ]);
  assert.equal(result.identity, account);
  assert.equal(result.data.plan, 'Ultra');
  assert.equal(result.data.weekly.used_percent, 12);
  assert.doesNotMatch(JSON.stringify(result), /private-secret|settings/);
});

test('Claude keeps quotas if optional plan metadata is unavailable and never adopts another organization', async () => {
  for (const metadata of [response([]), response([{uuid: secondAccount, rate_limit_tier: 'default_claude_max_20x'}]),
    response({unexpected: 'private-secret'}), response({}, 503), new Error('private-secret')]) {
    const {fetcher} = mockFetch([response({seven_day: {utilization: 12}}), metadata]);
    const {data} = await fetchWebService('claude', {fetcher, cookies: cookie(account)}, now);
    assert.equal(data.status, 'ok');
    assert.equal(data.plan, null);
    assert.equal(data.weekly.used_percent, 12);
  }
  const expired = mockFetch([response({seven_day: {utilization: 12}}), response({}, 401)]);
  await assert.rejects(fetchWebService('claude', {fetcher: expired.fetcher, cookies: cookie(account)}, now), reason('authentication_required'));
});

test('Claude does not fetch extra metadata when usage already identifies the plan', async () => {
  const {fetcher, calls} = mockFetch([response({seven_day: {utilization: 12}, subscription_type: 'ultra'})]);
  assert.equal((await fetchWebService('claude', {fetcher, cookies: cookie(account)}, now)).data.plan, 'Ultra');
  assert.equal(calls.length, 1);
});

test('missing or malformed Claude organization never guesses an account or creates a request', async () => {
  for (const key of ['claude', 'claudeCredits']) {
    for (const value of [null, 'private-secret', 'https://evil.example', account + '/other']) {
      const {fetcher, calls} = mockFetch([]);
      await assert.rejects(fetchWebService(key, {fetcher, cookies: cookie(value)}, now), reason('authentication_required'));
      assert.equal(calls.length, 0);
    }
  }
});

test('OpenAI API credit reads use only the connected sess token and selected organization', async () => {
  const {fetcher, calls} = mockFetch([response({grants: {data: [{
    id: 'chatgpt_api_credits_promo_test', grant_amount: 96, used_amount: 0,
    effective_at: now - 100, expires_at: now + 100, is_scheduled: false, is_held_for_prepaid_transition: false,
  }]}})]);
  const result = await fetchWebService('openaiCredits', {fetcher, credentials: {token: 'sess-test-secret', organization: 'org-Test'}}, now);
  assert.equal(calls[0].url, 'https://api.openai.com/v1/dashboard/billing/credit_grants');
  assert.equal(calls[0].options.credentials, 'omit');
  assert.deepEqual(calls[0].options.headers, {Accept: 'application/json', Authorization: 'Bearer sess-test-secret', 'OpenAI-Organization': 'org-Test'});
  assert.equal(result.identity, 'org-Test');
  assert.equal(result.data.monthly, 96);
  assert.doesNotMatch(JSON.stringify(result), /sess-test-secret|Authorization/);
  for (const credentials of [null, {token: 'sk-private-secret', organization: 'org-Test'},
    {token: 'sess-test-secret', organization: 'org-evil/path'}, {token: 'sess-test-secret\n', organization: 'org-Test'}]) {
    const fake = mockFetch([]);
    await assert.rejects(fetchWebService('openaiCredits', {fetcher: fake.fetcher, credentials}, now), reason('authentication_required'));
    assert.equal(fake.calls.length, 0);
  }
});

test('HTTP, HTML challenges, network failures and oversized bodies expose only sanitized errors', async () => {
  for (const [reply, expected] of [
    [response({error: 'private-secret'}, 401), 'authentication_required'],
    [response({error: 'private-secret'}, 429), 'rate_limited'],
    [new Response('<html>private-secret</html>', {status: 403}), 'unavailable'],
    [response({error: 'private-secret'}, 500), 'unavailable'],
    [new Response('private-secret'), 'unavailable'],
    [new Error('private-secret https://evil.example'), 'unavailable'],
    [response({padding: 'é'.repeat(600000)}), 'unavailable'],
  ]) {
    const {fetcher} = mockFetch([reply]);
    await assert.rejects(fetchWebService('claude', {fetcher, cookies: cookie(account)}, now), reason(expected));
  }
  const {fetcher, calls} = mockFetch([]);
  await assert.rejects(fetchWebService('https://evil.example', {fetcher}, now), reason('unavailable'));
  await assert.rejects(fetchWebService('__proto__', {fetcher}, now), reason('unavailable'));
  assert.equal(calls.length, 0);
});
