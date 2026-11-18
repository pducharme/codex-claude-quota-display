export const WEB_SERVICES = {
  codex: {label: 'OpenAI / Codex', connectURL: 'https://chatgpt.com/settings/usage?tab=overview',
    origins: ['https://chatgpt.com/*'], permissions: ['cookies']},
  claude: {label: 'Claude', connectURL: 'https://claude.ai/settings/usage',
    origins: ['https://claude.ai/*'], permissions: ['cookies']},
  openaiCredits: {label: 'Crédits API OpenAI', connectURL: 'https://platform.openai.com/settings/organization/billing/overview',
    origins: ['https://platform.openai.com/*', 'https://api.openai.com/*'], permissions: ['scripting']},
  claudeCredits: {label: 'Crédits API Claude', connectURL: 'https://platform.claude.com/settings/billing',
    origins: ['https://platform.claude.com/*'], permissions: ['cookies']},
  gemini: {label: 'Gemini', connectURL: 'https://gemini.google.com/usage',
    origins: ['https://gemini.google.com/*'], permissions: ['cookies']},
  grok: {label: 'Grok', connectURL: 'https://grok.com',
    origins: ['https://grok.com/*'], permissions: ['cookies']},
};

const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const numeric = (value, maximum) => typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= maximum;
const emptyWindow = () => ({used_percent: null, resets_at: null});
const epoch = value => numeric(value, 4294967295) ? Math.floor(value) : null;
function requireValue(valid) {
  if (!valid) throw new TypeError('Réponse de quotas invalide.');
}
function fresh(now) {
  requireValue(Number.isInteger(now) && epoch(now) !== null);
  return {status: 'ok', updated_at: now};
}
function isoEpoch(value) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(value)) return null;
  const [year, month, day] = value.slice(0, 10).split('-').map(Number);
  if (day < 1 || month < 1 || month > 12 || day > new Date(Date.UTC(year, month, 0)).getUTCDate()) return null;
  return epoch(Date.parse(value) / 1000);
}
function expirationList(values) {
  return values.sort((a, b) => a - b).map(expires_at => ({expires_at}));
}

export function parseGeminiUsage(html, nowSeconds = Math.floor(Date.now() / 1000)) {
  requireValue(typeof html === 'string' && html.length <= 4194304);
  // shortcut: read Gemini's quota-only Relay preload until a stable public usage API exists.
  const chunks = [];
  for (const match of html.matchAll(/<script\b[^>]*data-bg3-relay-preload[^>]*>([\s\S]*?)<\/script>/gi)) {
    const events = JSON.parse(match[1]).events;
    if (events === undefined) continue;
    requireValue(Array.isArray(events) && events.length <= 1000);
    for (const event of events) if (event.id === 'usage:0' && event.kind === 'chunk') {
      requireValue(typeof event.chunk === 'string');
      chunks.push(event.chunk);
    }
  }
  const results = JSON.parse(chunks.join(''));
  requireValue(Array.isArray(results) && results.length <= 1000);
  const usage = results.map(value => value?.data?.viewer?.rpcs?.getUsageInfo).find(object);
  requireValue(object(usage) && Array.isArray(usage.pools) && usage.pools.length <= 100);
  const window = type => {
    const pool = usage.pools.find(value => value?.poolType === type);
    return numeric(pool?.percentageUsed, 1)
      ? {used_percent: Math.round(pool.percentageUsed * 100), resets_at: isoEpoch(pool.gxu?.windowRefreshesAt)} : emptyWindow();
  };
  const five_hour = window('GXU_FIVE_HOURLY'), weekly = window('GXU_WEEKLY');
  requireValue(five_hour.used_percent !== null || weekly.used_percent !== null);
  return {...fresh(nowSeconds), plan: usage.subscriptionTier === 'TIER1' ? 'Pro' : null, five_hour, weekly};
}

export function parseGrokUsage(responses, subscriptions, nowSeconds = Math.floor(Date.now() / 1000)) {
  requireValue(object(responses));
  const limits = [];
  for (const [model, label] of Object.entries({fast: 'RAPIDE', expert: 'EXPERT', heavy: 'LOURD', auto: 'AUTO'})) {
    const value = responses[model];
    if (!object(value) || !Number.isSafeInteger(value.totalQueries) || value.totalQueries <= 0 ||
      !numeric(value.totalQueries, 1e9) || !Number.isSafeInteger(value.remainingQueries) ||
      !numeric(value.remainingQueries, value.totalQueries) || !numeric(value.windowSizeSeconds, 31536000) || !value.windowSizeSeconds) continue;
    limits.push({label, used_percent: Math.round(100 * (value.totalQueries - value.remainingQueries) / value.totalQueries),
      remaining: value.remainingQueries, total: value.totalQueries, duration_seconds: value.windowSizeSeconds,
      resets_at: numeric(value.waitTimeSeconds, value.windowSizeSeconds) && value.waitTimeSeconds > 0
        ? epoch(nowSeconds + value.waitTimeSeconds) : null});
  }
  requireValue(limits.length > 0);
  const tiers = {SUBSCRIPTION_TIER_SUPER_GROK_PRO: 'Heavy', SUBSCRIPTION_TIER_SUPER_GROK_PLUS: 'Plus',
    SUBSCRIPTION_TIER_GROK_PRO: 'SuperGrok', SUBSCRIPTION_TIER_SUPER_GROK_LITE: 'Lite',
    SUBSCRIPTION_TIER_X_PREMIUM_PLUS: 'Premium+', SUBSCRIPTION_TIER_X_PREMIUM: 'Premium'};
  const list = subscriptions?.subscriptions;
  const active = Array.isArray(list) && list.length <= 100 ? list.filter(value => value?.status === 'SUBSCRIPTION_STATUS_ACTIVE') : null;
  const tier = active && Object.keys(tiers).find(tier => active.some(value => value.tier === tier));
  return {...fresh(nowSeconds), plan: tier ? tiers[tier] : active?.length === 0 ? 'Gratuit' : null, limits};
}

export function parseCodexUsage(usage, resets, nowSeconds = Math.floor(Date.now() / 1000)) {
  requireValue(object(usage) && typeof usage.plan_type === 'string');
  const plans = {plus: 'Plus', prolite: 'Pro 100', pro: 'Pro 200', promax: 'Pro 500'};
  const result = {...fresh(nowSeconds),
    plan: Object.hasOwn(plans, usage.plan_type) ? plans[usage.plan_type] : null,
    five_hour: emptyWindow(), weekly: emptyWindow(), fable_weekly: emptyWindow(), credits: null, banked_resets: null};
  for (const window of [usage.rate_limit?.primary_window, usage.rate_limit?.secondary_window]) {
    if (!object(window) || !numeric(window.used_percent, 100) || !numeric(window.limit_window_seconds, 4294967295)) continue;
    const minutes = window.limit_window_seconds / 60;
    const key = minutes >= 240 && minutes <= 360 ? 'five_hour' : minutes >= 9000 && minutes <= 11000 ? 'weekly' : null;
    if (key) result[key] = {used_percent: Math.floor(window.used_percent), resets_at: epoch(window.reset_at)};
  }
  if (object(usage.credits)) {
    const raw = usage.credits.balance;
    const balance = typeof raw === 'string' && /^\d+(?:\.\d+)?$/.test(raw) ? Number(raw) : raw;
    result.credits = {balance: numeric(balance, 1e12) ? balance : null, unlimited: usage.credits.unlimited === true};
  }
  const count = usage.rate_limit_reset_credits?.available_count;
  if (Number.isInteger(count) && numeric(count, 1000)) result.banked_resets = {available_count: count, expirations: []};
  if (object(resets) && Array.isArray(resets.credits) && resets.credits.length <= 1000) {
    const seen = new Set(), dates = [];
    let available = 0, valid = true;
    for (const credit of resets.credits) {
      if (!object(credit)) { valid = false; break; }
      if (credit.reset_type !== 'codex_rate_limits' || credit.status !== 'available') continue;
      if (typeof credit.id !== 'string' || !credit.id || credit.id.length > 256) { valid = false; break; }
      if (seen.has(credit.id)) continue;
      seen.add(credit.id);
      const expiry = isoEpoch(credit.expires_at);
      if (credit.expires_at != null && expiry === null) { valid = false; break; }
      if (expiry !== null && expiry <= nowSeconds) continue;
      available++;
      if (expiry !== null) dates.push(expiry);
    }
    if (valid) result.banked_resets = {available_count: available, expirations: expirationList(dates)};
  }
  return result;
}

function claudeResets(bank, now) {
  if (!object(bank) || bank.eligible !== true || !Array.isArray(bank.grants) || bank.grants.length > 1000) return null;
  const dates = [], seen = new Set();
  for (const grant of bank.grants) {
    if (!object(grant) || typeof grant.id !== 'string' || !grant.id || grant.id.length > 256) return null;
    if (seen.has(grant.id)) continue;
    seen.add(grant.id);
    if (!Number.isInteger(grant.resets_left) || !Number.isInteger(grant.resets_total)
      || !numeric(grant.resets_total, 1000) || !numeric(grant.resets_left, grant.resets_total)) return null;
    if (!grant.resets_left || grant.paused === true) continue;
    const expiry = isoEpoch(grant.ends_at);
    if (expiry === null) return null;
    if (expiry > now) dates.push(...Array(grant.resets_left).fill(expiry));
    if (dates.length > 1000) return null;
  }
  return {available_count: dates.length, expirations: expirationList(dates)};
}

export function parseClaudeUsage(usage, nowSeconds = Math.floor(Date.now() / 1000)) {
  requireValue(object(usage));
  const window = value => object(value) && numeric(value.utilization ?? value.percent, 100)
    ? {used_percent: Math.floor(value.utilization ?? value.percent), resets_at: isoEpoch(value.resets_at)} : emptyWindow();
  let fable = usage.seven_day_fable;
  if (Array.isArray(usage.limits)) {
    requireValue(usage.limits.length <= 1000);
    fable = usage.limits.find(limit => limit?.kind === 'weekly_scoped' &&
      typeof limit.scope?.model?.display_name === 'string' && limit.scope.model.display_name.toLowerCase() === 'fable') ?? fable;
  }
  const windows = {five_hour: window(usage.five_hour), weekly: window(usage.seven_day), fable_weekly: window(fable)};
  requireValue(Object.values(windows).some(value => value.used_percent !== null));
  const organization = object(usage.organization) ? usage.organization : {};
  const tier = organization.rate_limit_tier ?? usage.rate_limit_tier;
  const subscription = organization.subscription_type ?? usage.subscription_type ?? organization.organization_type ?? tier;
  const text = typeof subscription === 'string' ? subscription.toLowerCase() : '';
  const plan = text.includes('ultra') || (text.includes('max') && typeof tier === 'string' && tier.endsWith('20x')) ? 'Ultra'
    : text.includes('max') ? 'Max' : text.includes('pro') ? 'Pro' : null;
  return {...fresh(nowSeconds), ...windows, plan, banked_resets: claudeResets(usage.cedar_ember, nowSeconds)};
}

export function parseOpenAICredits(summary, organization, nowSeconds = Math.floor(Date.now() / 1000)) {
  requireValue(typeof organization === 'string' && /^org-[A-Za-z0-9]{1,124}$/.test(organization)
    && object(summary) && Array.isArray(summary.grants?.data) && summary.grants.data.length <= 1000);
  const result = {...fresh(nowSeconds), organization_id: organization, currency: 'USD', monthly: 0, monthly_granted: 0, expires_at: null};
  const seen = new Set(), dates = [];
  for (const grant of summary.grants.data) {
    requireValue(object(grant) && typeof grant.id === 'string');
    if (!grant.id.startsWith('chatgpt_api_credits_promo_')) continue;
    requireValue(!seen.has(grant.id) && numeric(grant.grant_amount, 1e12) && numeric(grant.used_amount, grant.grant_amount)
      && epoch(grant.effective_at) !== null && epoch(grant.expires_at) !== null && grant.expires_at > grant.effective_at
      && typeof grant.is_scheduled === 'boolean' && typeof grant.is_held_for_prepaid_transition === 'boolean');
    seen.add(grant.id);
    if (grant.is_scheduled || grant.is_held_for_prepaid_transition || grant.effective_at > nowSeconds || grant.expires_at <= nowSeconds) continue;
    result.monthly += grant.grant_amount - grant.used_amount;
    result.monthly_granted += grant.grant_amount;
    dates.push(Math.floor(grant.expires_at));
  }
  requireValue(numeric(result.monthly_granted, 1e12));
  result.expires_at = dates.length ? Math.min(...dates) : null;
  return result;
}

export function parseClaudeCredits(credits, organization, nowSeconds = Math.floor(Date.now() / 1000)) {
  requireValue(typeof organization === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(organization)
    && object(credits) && credits.currency === 'USD' && Array.isArray(credits.promo_tranches) && credits.promo_tranches.length <= 1000);
  const cents = value => { requireValue(Number.isSafeInteger(value) && numeric(value, 1e14)); return value; };
  const purchased = cents(credits.amount_without_scoped_credits);
  let monthly = 0, granted = 0, promotional = 0;
  const dates = [];
  for (const tranche of credits.promo_tranches) {
    requireValue(object(tranche) && tranche.currency === 'USD');
    const remaining = cents(tranche.remaining_amount_minor_units), initial = cents(tranche.granted_amount_minor_units);
    const expiry = isoEpoch(tranche.expires_at);
    requireValue(remaining <= initial && expiry !== null);
    if (expiry <= nowSeconds) continue;
    if (tranche.program_id === 'subscription_api_credit') {
      monthly += remaining;
      granted += initial;
      dates.push(expiry);
    } else promotional += remaining;
  }
  cents(granted); cents(promotional);
  return {...fresh(nowSeconds), organization_id: organization.toLowerCase(), currency: 'USD', purchased: purchased / 100,
    monthly: monthly / 100, monthly_granted: granted / 100, promotional: promotional / 100,
    expires_at: dates.length ? Math.min(...dates) : null};
}
