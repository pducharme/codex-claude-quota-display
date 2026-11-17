import {readFile} from 'node:fs/promises';
import assert from 'node:assert/strict';
import test from 'node:test';

const source = await readFile(new URL('./web-providers.js', import.meta.url), 'utf8');
const {WEB_SERVICES, parseCodexUsage, parseClaudeUsage, parseOpenAICredits, parseClaudeCredits} =
  await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
const now = 1794931200;
const expiry = now + 604800;
const iso = value => new Date(value * 1000).toISOString();
const codex = {plan_type: 'pro', rate_limit: {primary_window: {
  used_percent: 23, limit_window_seconds: 604800, reset_at: expiry}},
  credits: {balance: '12345.6700', unlimited: false}, rate_limit_reset_credits: {available_count: 2}};
const claude = {seven_day: {utilization: 12.8, resets_at: iso(expiry)},
  organization: {organization_type: 'claude_max', rate_limit_tier: 'default_claude_max_20x'}};
const grant = {id: 'chatgpt_api_credits_promo_test', grant_amount: 96, used_amount: 12.5,
  effective_at: now - 100.5, expires_at: expiry, is_scheduled: false, is_held_for_prepaid_transition: false};
const openai = grants => ({grants: {data: grants}});
const organization = '00000000-0000-4000-8000-000000000001';
const tranche = {currency: 'USD', remaining_amount_minor_units: 19918, granted_amount_minor_units: 20000,
  program_id: 'subscription_api_credit', expires_at: iso(expiry)};
const consoleCredits = {currency: 'USD', amount_without_scoped_credits: 1250, promo_tranches: [tranche]};
const invalidNumbers = [null, true, false, '', '96', -1, NaN, Infinity, -Infinity, 1e100];

test('service metadata requests only the relevant HTTPS sites', () => {
  assert.deepEqual(Object.keys(WEB_SERVICES), ['codex', 'claude', 'openaiCredits', 'claudeCredits']);
  for (const [key, service] of Object.entries(WEB_SERVICES)) {
    assert.deepEqual(service.permissions, [key === 'openaiCredits' ? 'scripting' : 'cookies']);
    assert.ok(service.origins.includes(`${new URL(service.connectURL).origin}/*`));
    assert.ok(service.origins.every(origin => /^https:\/\/[a-z.]+\/\*$/.test(origin)));
  }
  assert.equal(WEB_SERVICES.codex.connectURL, 'https://chatgpt.com/settings/usage?tab=overview');
});

test('WHAM windows are classified by duration, preserve zero and do not mix Codex/API credits', () => {
  const parsed = parseCodexUsage(codex, undefined, now);
  assert.deepEqual(parsed.five_hour, {used_percent: null, resets_at: null});
  assert.deepEqual(parsed.weekly, {used_percent: 23, resets_at: expiry});
  assert.equal(parsed.plan, 'Pro 200');
  assert.deepEqual(parsed.credits, {balance: 12345.67, unlimited: false});
  assert.equal(parsed.api_credits, undefined);
  assert.deepEqual(parsed.banked_resets, {available_count: 2, expirations: []});
  const two = parseCodexUsage({...codex, rate_limit: {primary_window: codex.rate_limit.primary_window,
    secondary_window: {used_percent: 0, limit_window_seconds: 18000, reset_at: now + 18000}}}, null, now);
  assert.equal(two.five_hour.used_percent, 0);
  assert.equal(two.weekly.used_percent, 23);
});

test('WHAM optional or invalid values remain unknown; app-server camelCase is not accepted', () => {
  assert.throws(() => parseCodexUsage({rateLimits: {planType: 'pro'}}, null, now), TypeError);
  for (const plan of ['future', '__proto__', 'constructor', 'toString']) {
    const parsed = parseCodexUsage({plan_type: plan, rate_limit: null}, null, now);
    assert.equal(parsed.plan, null);
    assert.equal(parsed.weekly.used_percent, null);
    assert.equal(parsed.credits, null);
    assert.equal(parsed.banked_resets, null);
  }
  for (const value of invalidNumbers.concat([101])) {
    const parsed = parseCodexUsage({...codex, rate_limit: {primary_window: {
      ...codex.rate_limit.primary_window, used_percent: value}}}, null, now);
    assert.equal(parsed.weekly.used_percent, null);
  }
  for (const value of invalidNumbers.filter(value => value !== '96').concat([' ', '0x10', 'Infinity', '1e100'])) {
    assert.equal(parseCodexUsage({...codex, credits: {balance: value}}, null, now).credits.balance, null);
  }
  assert.deepEqual(parseCodexUsage({...codex, credits: {balance: '0', unlimited: true}}, null, now).credits,
    {balance: 0, unlimited: true});
});

test('Codex reset details deduplicate and exclude expired, consumed or unrelated grants', () => {
  const reset = {id: 'reset', reset_type: 'codex_rate_limits', status: 'available', expires_at: iso(expiry)};
  const credits = [reset, {...reset}, {...reset, id: 'old', expires_at: iso(now)},
    {...reset, id: 'used', status: 'consumed'}, {...reset, id: 'other', reset_type: 'unknown'},
    {...reset, id: 'undated', expires_at: null}];
  assert.deepEqual(parseCodexUsage(codex, {credits}, now).banked_resets,
    {available_count: 2, expirations: [{expires_at: expiry}]});
  assert.deepEqual(parseCodexUsage(codex, {credits: [null]}, now).banked_resets,
    {available_count: 2, expirations: []});
  assert.deepEqual(parseCodexUsage(codex, {credits: []}, now).banked_resets,
    {available_count: 0, expirations: []});
});

test('Claude usage ports scoped Fable windows and current plan metadata', () => {
  const result = parseClaudeUsage({...claude, five_hour: {utilization: 0}, limits: [
    {kind: 'weekly_scoped', scope: {model: {display_name: 'Fable'}}, percent: 81, resets_at: iso(expiry)},
  ]}, now);
  assert.equal(result.plan, 'Ultra');
  assert.deepEqual(result.five_hour, {used_percent: 0, resets_at: null});
  assert.deepEqual(result.weekly, {used_percent: 12, resets_at: expiry});
  assert.deepEqual(result.fable_weekly, {used_percent: 81, resets_at: expiry});
  assert.equal(result.banked_resets, null);
  assert.equal(parseClaudeUsage({seven_day: claude.seven_day}, now).plan, null);
});

test('Claude rejects absent quotas and invalid numbers without turning missing windows into zero', () => {
  for (const value of invalidNumbers.concat([101])) {
    assert.throws(() => parseClaudeUsage({five_hour: {utilization: value}}, now), TypeError);
  }
  for (const value of [null, {}, [], 'private-secret']) assert.throws(() => parseClaudeUsage(value, now), TypeError);
  const result = parseClaudeUsage({...claude, five_hour: {utilization: true}}, now);
  assert.equal(result.five_hour.used_percent, null);
  for (const resets_at of ['0', '2026-11-17T00:00:00', '2026-02-30T00:00:00Z', 'invalid', false]) {
    assert.equal(parseClaudeUsage({seven_day: {utilization: 5, resets_at}}, now).weekly.resets_at, null);
  }
});

test('Claude reset bank preserves unsupported versus empty and counts only active grants', () => {
  const reset = {id: 'offer', resets_left: 2, resets_total: 2, paused: false, ends_at: iso(expiry)};
  const bank = {eligible: true, grants: [reset, {...reset}, {...reset, id: 'paused', paused: true},
    {...reset, id: 'expired', ends_at: iso(now)}, {...reset, id: 'spent', resets_left: 0}]};
  assert.deepEqual(parseClaudeUsage({...claude, cedar_ember: bank}, now).banked_resets,
    {available_count: 2, expirations: [{expires_at: expiry}, {expires_at: expiry}]});
  assert.deepEqual(parseClaudeUsage({...claude, cedar_ember: {eligible: true, grants: []}}, now).banked_resets,
    {available_count: 0, expirations: []});
  for (const cedar_ember of [{eligible: false, grants: []}, {eligible: true, grants: [{...reset, resets_left: true}]},
    {eligible: true, grants: [{...reset, resets_left: 3}]}]) {
    assert.equal(parseClaudeUsage({...claude, cedar_ember}, now).banked_resets, null);
  }
});

test('OpenAI API credits use actual prorated USD grants and aggregate active upgrades', () => {
  const parsed = parseOpenAICredits(openai([grant]), 'org-Example123', now);
  assert.deepEqual(parsed, {status: 'ok', updated_at: now, organization_id: 'org-Example123', currency: 'USD',
    monthly: 83.5, monthly_granted: 96, expires_at: expiry});
  const grants = [grant, {...grant, id: 'chatgpt_api_credits_promo_upgrade', grant_amount: 4, used_amount: 1, expires_at: expiry - 1},
    {...grant, id: 'purchased_credit', grant_amount: 1000}, {...grant, id: 'chatgpt_api_credits_promo_future', effective_at: now + 0.1},
    {...grant, id: 'chatgpt_api_credits_promo_expired', expires_at: now}, {...grant, id: 'chatgpt_api_credits_promo_scheduled', is_scheduled: true},
    {...grant, id: 'chatgpt_api_credits_promo_held', is_held_for_prepaid_transition: true}];
  const result = parseOpenAICredits(openai(grants), 'org-Example123', now);
  assert.equal(result.monthly, 86.5);
  assert.equal(result.monthly_granted, 100);
  assert.equal(result.expires_at, expiry - 1);
  assert.equal(parseOpenAICredits(openai([grant]), 'org-Example123', expiry).monthly, 0);
  assert.equal(parseOpenAICredits(openai([]), 'org-Example123', now).expires_at, null);
  assert.equal(parseOpenAICredits(openai([{...grant, used_amount: 96}]), 'org-Example123', now).monthly, 0);
});

test('OpenAI credit validation rejects malformed grants, duplicate IDs, overflow and wrong organizations', () => {
  for (const field of ['grant_amount', 'used_amount', 'effective_at', 'expires_at']) {
    for (const value of invalidNumbers) {
      assert.throws(() => parseOpenAICredits(openai([{...grant, [field]: value}]), 'org-valid', now), TypeError);
    }
  }
  for (const change of [{used_amount: 97}, {expires_at: grant.effective_at}, {is_scheduled: 0}, {is_held_for_prepaid_transition: 'false'}]) {
    assert.throws(() => parseOpenAICredits(openai([{...grant, ...change}]), 'org-valid', now), TypeError);
  }
  for (const id of [null, '', 'org-', 'org-é', 'org-abc\n', 'org-' + 'a'.repeat(125), 'https://private-secret']) {
    assert.throws(() => parseOpenAICredits(openai([grant]), id, now), error => !error.message.includes('private-secret'));
  }
  for (const grants of [[grant, grant], Array(1001).fill(grant), [null], [{...grant, grant_amount: 1e12},
    {...grant, id: 'chatgpt_api_credits_promo_extra', grant_amount: 1e12}]]) {
    assert.throws(() => parseOpenAICredits(openai(grants), 'org-valid', now), TypeError);
  }
});

test('Claude API credits convert cents once, separate purchased/promotional and expire monthly tranches', () => {
  const credits = {...consoleCredits, promo_tranches: [tranche, {...tranche, program_id: 'other', remaining_amount_minor_units: 500},
    {...tranche, expires_at: iso(now)}]};
  assert.deepEqual(parseClaudeCredits(credits, organization, now), {
    status: 'ok', updated_at: now, organization_id: organization, currency: 'USD', purchased: 12.5,
    monthly: 199.18, monthly_granted: 200, promotional: 5, expires_at: expiry,
  });
  const result = parseClaudeCredits({...consoleCredits, amount_without_scoped_credits: 0,
    promo_tranches: [{...tranche, remaining_amount_minor_units: 0}]}, organization, now);
  assert.equal(result.purchased, 0);
  assert.equal(result.monthly, 0);
  assert.equal(result.monthly_granted, 200);
});

test('Claude API credit validation rejects coercion, fractions, currencies and invalid expiries', () => {
  for (const value of invalidNumbers.concat([0.5])) {
    assert.throws(() => parseClaudeCredits({...consoleCredits, amount_without_scoped_credits: value}, organization, now), TypeError);
    assert.throws(() => parseClaudeCredits({...consoleCredits, promo_tranches: [{...tranche, remaining_amount_minor_units: value}]}, organization, now), TypeError);
  }
  for (const change of [{currency: 'CAD'}, {remaining_amount_minor_units: 20001}, {expires_at: '2026-11-29'}, {expires_at: '2026-02-30T00:00:00Z'}]) {
    assert.throws(() => parseClaudeCredits({...consoleCredits, promo_tranches: [{...tranche, ...change}]}, organization, now), TypeError);
  }
  for (const id of [null, 'org-valid', organization + '\n']) assert.throws(() => parseClaudeCredits(consoleCredits, id, now), TypeError);
  assert.throws(() => parseClaudeCredits({...consoleCredits, currency: 'EUR'}, organization, now), TypeError);
});

test('normalizers allowlist output and never mutate inputs or carry tokens/account identities', () => {
  const secret = {accessToken: 'private-secret', account_id: 'private-secret', user_id: 'private-secret', Authorization: 'private-secret'};
  const samples = [
    [parseCodexUsage, [{...codex, ...secret}, null, now]],
    [parseClaudeUsage, [{...claude, ...secret}, now]],
    [parseOpenAICredits, [{...openai([{...grant, ...secret}]), ...secret}, 'org-valid', now]],
    [parseClaudeCredits, [{...consoleCredits, ...secret}, organization, now]],
  ];
  for (const [parse, args] of samples) {
    const before = JSON.stringify(args);
    assert.doesNotMatch(JSON.stringify(parse(...args)), /private-secret|accessToken|Authorization|user_id|account_id/);
    assert.equal(JSON.stringify(args), before);
    for (const badNow of [-1, true, NaN, 0.5, '1794931200']) {
      assert.throws(() => parse(...args.slice(0, -1), badNow), TypeError);
    }
  }
});
