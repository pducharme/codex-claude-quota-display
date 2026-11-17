import {hostPermission} from './api.js';
import {WEB_SERVICES} from './web-providers.js';
import {fetchWebService} from './web-fetch.js';

export const sourceMode = settings => settings.sourceMode || (settings.connection ? 'mac' : 'web');
const serviceIDs = Object.keys(WEB_SERVICES);
const authScripts = ['quota-platform-auth', 'quota-platform-forward'];
const nowSeconds = () => Math.floor(Date.now() / 1000);

async function permitted(key) {
  const {origins, permissions} = WEB_SERVICES[key];
  return chrome.permissions.contains({origins, permissions});
}

export async function stopPlatformAuth() {
  if (!await chrome.permissions.contains({permissions: ['scripting']})) return;
  const tabs = await chrome.tabs.query({url: 'https://platform.openai.com/*'});
  await Promise.allSettled(tabs.map(tab => chrome.tabs.sendMessage(tab.id, {type: 'quota-platform-stop'}, {frameId: 0})));
  const registered = await chrome.scripting.getRegisteredContentScripts();
  const ids = authScripts.filter(id => registered.some(script => script.id === id));
  if (ids.length) await chrome.scripting.unregisterContentScripts({ids});
}

export async function syncPlatformAuth(settings) {
  const {pendingPlatformAuth} = await chrome.storage.session.get('pendingPlatformAuth');
  if (sourceMode(settings) !== 'web' || settings.webConnected?.openaiCredits !== true ||
      !pendingPlatformAuth || pendingPlatformAuth < nowSeconds() || !await permitted('openaiCredits')) {
    await chrome.storage.session.remove('pendingPlatformAuth');
    await stopPlatformAuth();
    return;
  }
  const registered = await chrome.scripting.getRegisteredContentScripts();
  const scripts = authScripts.map((id, index) => ({id, matches: ['https://platform.openai.com/*'],
    js: [index ? 'platform-forward.js' : 'platform-auth.js'], runAt: 'document_start',
    world: index ? 'ISOLATED' : 'MAIN', allFrames: false, persistAcrossSessions: false}))
    .filter(script => !registered.some(existing => existing.id === script.id));
  if (scripts.length) await chrome.scripting.registerContentScripts(scripts);
}

export async function connectWebService(key, settings) {
  if (!Object.hasOwn(WEB_SERVICES, key)) throw new Error('Service inconnu.');
  if (!await permitted(key)) throw new Error('Chrome n’a pas autorisé ce service.');
  const webConnected = {...settings.webConnected, [key]: true};
  settings = {...settings, sourceMode: 'web', webConnected};
  await chrome.storage.local.set({sourceMode: 'web', webConnected});
  const snapshot = await readWebSnapshot(settings, true);
  const needsLogin = snapshot.web_services[key]?.status !== 'ok';
  if (key === 'openaiCredits' && needsLogin) {
    await chrome.storage.session.set({pendingPlatformAuth: nowSeconds() + 600});
    await syncPlatformAuth(settings);
  }
  return {connected: true, needsLogin};
}

export async function disconnectWebService(key, settings) {
  if (!Object.hasOwn(WEB_SERVICES, key)) throw new Error('Service inconnu.');
  const webConnected = {...settings.webConnected, [key]: false};
  if (key === 'openaiCredits') {
    await chrome.storage.session.remove('pendingPlatformAuth');
    await stopPlatformAuth();
    await chrome.storage.local.remove('platformCredentials');
  }
  const {webCaptures = {}} = await chrome.storage.session.get('webCaptures');
  delete webCaptures[key];
  await chrome.storage.session.set({webCaptures});
  await chrome.storage.session.remove('cached');
  await chrome.storage.local.set({webConnected});
  const retained = new Set(serviceIDs.filter(id => webConnected[id]).flatMap(id => WEB_SERVICES[id].origins));
  if (settings.connection) retained.add(hostPermission(settings.connection.baseURL));
  const origins = WEB_SERVICES[key].origins.filter(origin => !retained.has(origin));
  if (origins.length) await chrome.permissions.remove({origins});
  const permissions = WEB_SERVICES[key].permissions.filter(permission =>
    !serviceIDs.some(id => webConnected[id] && WEB_SERVICES[id].permissions.includes(permission)));
  if (permissions.length) await chrome.permissions.remove({permissions});
  return {disconnected: true};
}

export async function acceptPlatformCredentials(credentials, sender, settings) {
  if (sourceMode(settings) !== 'web' || settings.webConnected?.openaiCredits !== true ||
      sender.id !== chrome.runtime.id || sender.frameId !== 0 || !Number.isInteger(sender.tab?.id)) return false;
  try { if (new URL(sender.url).origin !== 'https://platform.openai.com') return false; } catch { return false; }
  const {pendingPlatformAuth} = await chrome.storage.session.get('pendingPlatformAuth');
  if (!pendingPlatformAuth || pendingPlatformAuth < nowSeconds() || !await permitted('openaiCredits') ||
      typeof credentials?.token !== 'string' || !/^sess-[A-Za-z0-9_-]{16,8192}$/.test(credentials.token) ||
      typeof credentials.organization !== 'string' || !/^org-[A-Za-z0-9_-]{1,200}$/.test(credentials.organization)) return false;
  // Verify the narrowly scoped read before saving the session; no credential is returned to the popup.
  const sample = await fetchWebService('openaiCredits', {credentials});
  const latest = await chrome.storage.local.get(null);
  if (sourceMode(latest) !== 'web' || latest.webConnected?.openaiCredits !== true || !await permitted('openaiCredits')) return false;
  const platformCredentials = {token: credentials.token, organization: credentials.organization};
  await chrome.storage.local.set({platformCredentials});
  const {webCaptures = {}} = await chrome.storage.session.get('webCaptures');
  webCaptures.openaiCredits = {...sample, last_attempt: nowSeconds()};
  await chrome.storage.session.set({webCaptures});
  await chrome.storage.session.remove('pendingPlatformAuth');
  await stopPlatformAuth();
  return true;
}

export async function readWebSnapshot(settings, refresh = false) {
  const {webCaptures = {}} = await chrome.storage.session.get('webCaptures');
  const now = nowSeconds(), samples = {}, states = {};
  await Promise.all(serviceIDs.map(async key => {
    if (settings.webConnected?.[key] !== true) {
      delete webCaptures[key];
      samples[key] = {status: 'unavailable'};
      return;
    }
    const allowed = await permitted(key);
    let current = webCaptures[key];
    const expired = current?.data?.expires_at > (current?.last_attempt || 0) && current.data.expires_at <= now;
    if (!allowed) {
      current = {error_reason: 'permission_required', error_message: 'Autorisez de nouveau ce service dans les connexions Chrome.'};
    } else if (refresh || expired || !current?.last_attempt || now - current.last_attempt >= 300) {
      try {
        current = {...await fetchWebService(key, {credentials: settings.platformCredentials}, now), last_attempt: now};
      } catch (error) {
        const reason = ['authentication_required', 'rate_limited', 'unavailable'].includes(error.reason) ? error.reason : 'unavailable';
        const messages = {authentication_required: 'Reconnectez ce compte dans Chrome.',
          rate_limited: 'Le service limite les lectures. Nouvelle tentative dans cinq minutes.',
          unavailable: 'Lecture indisponible. Réessayez dans quelques minutes.'};
        current = {...(reason === 'authentication_required' ? {} : current), last_attempt: now,
          error_reason: reason, error_message: messages[reason]};
        if (reason === 'authentication_required' && key === 'openaiCredits') await chrome.storage.local.remove('platformCredentials');
      }
    }
    webCaptures[key] = current;
    const old = current.data && (now - current.data.updated_at > 900 ||
      (Number.isFinite(current.data.expires_at) && current.data.expires_at <= now));
    const reason = current.error_reason || (old ? 'stale' : null);
    samples[key] = {...current.data, status: reason ? (current.data ? 'stale' : 'unavailable') : 'ok',
      error_reason: reason, error_message: current.error_message || (old ? 'Dernières données conservées. Actualisez les quotas.' : null)};
    states[key] = {status: samples[key].status, error_reason: reason, error_message: samples[key].error_message};
  }));
  await chrome.storage.session.set({webCaptures});
  return {version: 1, source_mode: 'web', timestamp: now,
    providers: {codex: {...samples.codex, api_credits: settings.webConnected?.openaiCredits ? samples.openaiCredits : null},
      claude: {...samples.claude, credits: settings.webConnected?.claudeCredits ? samples.claudeCredits : null}},
    web_services: states, display: {codex: settings.webDisplay?.codex !== false, claude: settings.webDisplay?.claude !== false},
    refresh: {enabled: true, active: false}};
}
