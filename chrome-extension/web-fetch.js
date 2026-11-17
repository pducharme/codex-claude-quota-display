import {WEB_SERVICES, parseCodexUsage, parseClaudeUsage, parseOpenAICredits, parseClaudeCredits} from './web-providers.js';

const uuid = value => typeof value === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(value)
  ? value.toLowerCase() : null;
const token = value => typeof value === 'string' && /^[\x21-\x7e]{1,16384}$/.test(value);
function failure(reason, status) {
  const error = new Error({authentication_required: 'Reconnectez ce service dans Chrome.',
    rate_limited: 'Le service limite les lectures. Réessayez plus tard.',
    unavailable: 'Les quotas de ce service sont momentanément indisponibles.'}[reason]);
  error.reason = reason;
  if (status !== undefined) error.status = status;
  return error;
}

async function jsonGET(fetcher, url, headers = {}, credentials = 'include') {
  let response, text;
  try {
    response = await fetcher(url, {method: 'GET', headers: {Accept: 'application/json', ...headers},
      credentials, cache: 'no-store', redirect: 'error', signal: AbortSignal.timeout(12000)});
  } catch { throw failure('unavailable'); }
  if (response.status !== 200) {
    throw failure(response.status === 401 ? 'authentication_required' : response.status === 429 ? 'rate_limited' : 'unavailable', response.status);
  }
  try {
    text = await response.text();
    if (new TextEncoder().encode(text).byteLength > 1048576) throw new Error();
    return JSON.parse(text);
  } catch { throw failure('unavailable'); }
}

async function cookieOrganization(cookies, url, name) {
  try { return uuid((await cookies?.get({url, name}))?.value); } catch { return null; }
}

function tokenAccount(accessToken) {
  try {
    const part = accessToken.split('.')[1];
    if (!part) return null;
    const encoded = part.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(part.length / 4) * 4, '=');
    return uuid(JSON.parse(atob(encoded))['https://api.openai.com/auth']?.chatgpt_account_id);
  } catch { return null; }
}

export async function fetchWebService(key, {fetcher = fetch, cookies = globalThis.chrome?.cookies, credentials} = {}, nowSeconds = Math.floor(Date.now() / 1000)) {
  if (!Object.hasOwn(WEB_SERVICES, key)) throw failure('unavailable');
  try {
    if (key === 'codex') {
      for (let attempt = 0; attempt < 2; attempt++) {
        try {
          const session = await jsonGET(fetcher, 'https://chatgpt.com/api/auth/session');
          if (!token(session?.accessToken)) throw failure('authentication_required');
          const selected = await cookieOrganization(cookies, 'https://chatgpt.com', '_account')
            ?? uuid(session.account?.id) ?? tokenAccount(session.accessToken);
          const headers = {Authorization: `Bearer ${session.accessToken}`, ...(selected ? {'ChatGPT-Account-Id': selected} : {})};
          const usage = await jsonGET(fetcher, 'https://chatgpt.com/backend-api/wham/usage', headers);
          const returned = uuid(usage?.account_id);
          if ((usage?.account_id != null && !returned) || (selected && returned && selected !== returned)) throw failure('unavailable');
          const identity = returned ?? selected;
          if (!identity) throw failure('authentication_required');
          let resets = null;
          try {
            resets = await jsonGET(fetcher, 'https://chatgpt.com/backend-api/wham/rate-limit-reset-credits',
              {...headers, 'ChatGPT-Account-Id': identity});
            if (resets?.account_id != null && uuid(resets.account_id) !== identity) resets = null;
          } catch (error) {
            if (error.status === 401) throw error;
          }
          return {identity, data: parseCodexUsage(usage, resets, nowSeconds)};
        } catch (error) {
          if (error.status === 401 && attempt === 0) continue;
          throw error;
        }
      }
    }
    if (key === 'openaiCredits') {
      const organization = credentials?.organization;
      if (!token(credentials?.token) || !credentials.token.startsWith('sess-') ||
        typeof organization !== 'string' || !/^org-[A-Za-z0-9]{1,124}$/.test(organization)) throw failure('authentication_required');
      const summary = await jsonGET(fetcher, 'https://api.openai.com/v1/dashboard/billing/credit_grants',
        {Authorization: `Bearer ${credentials.token}`, 'OpenAI-Organization': organization}, 'omit');
      return {identity: organization, data: parseOpenAICredits(summary, organization, nowSeconds)};
    }
    const origin = key === 'claude' ? 'https://claude.ai' : 'https://platform.claude.com';
    const organization = await cookieOrganization(cookies, origin, 'lastActiveOrg');
    if (!organization) throw failure('authentication_required');
    const path = key === 'claude' ? '/usage?cedar_ember=1&skip_spend=1' : '/prepaid/credits';
    const body = await jsonGET(fetcher, `${origin}/api/organizations/${organization}${path}`);
    const data = key === 'claude' ? parseClaudeUsage(body, nowSeconds) : parseClaudeCredits(body, organization, nowSeconds);
    if (key === 'claude' && !data.plan) {
      try {
        // Web usage omits the subscription; resolve it only for the selected organization.
        const organizations = await jsonGET(fetcher, 'https://claude.ai/api/organizations');
        const selected = Array.isArray(organizations) && organizations.length <= 1000
          ? organizations.find(value => uuid(value?.uuid) === organization) : null;
        if (selected) data.plan = parseClaudeUsage({...body, organization: selected}, nowSeconds).plan;
      } catch (error) {
        if (error.reason === 'authentication_required') throw error;
      }
    }
    return {identity: organization, data};
  } catch (error) {
    if (['authentication_required', 'rate_limited', 'unavailable'].includes(error?.reason)) throw error;
    throw failure('unavailable');
  }
}
