import {requestAPI, badgeState} from './api.js';
import {sourceMode, connectWebService, disconnectWebService, acceptPlatformCredentials, readWebSnapshot, syncPlatformAuth} from './web-source.js';

async function setBadge(snapshot, online) {
  const {badge} = await chrome.storage.local.get('badge');
  const state = badgeState(snapshot, badge, online);
  await Promise.all([
    chrome.action.setBadgeText({text: state.text}),
    chrome.action.setBadgeBackgroundColor({color: state.color}),
    chrome.action.setTitle({title: state.title}),
  ]);
}

// Serialize API operations so changing sources cannot mix snapshots or credentials.
let pending = Promise.resolve();
async function execute(message) {
  await chrome.storage.local.setAccessLevel({accessLevel: 'TRUSTED_CONTEXTS'});
  await chrome.storage.session.setAccessLevel({accessLevel: 'TRUSTED_CONTEXTS'});
  const settings = await chrome.storage.local.get(null);
  const {connection} = settings;
  if (message.type === 'connect-web') return connectWebService(message.value, settings);
  if (message.type === 'disconnect-web') return disconnectWebService(message.value, settings);
  if (message.type === 'platform-auth') {
    const accepted = await acceptPlatformCredentials(message.credentials, message.sender, settings);
    return {accepted};
  }
  if (message.type === 'cookie-change') {
    const {webCaptures = {}} = await chrome.storage.session.get('webCaptures');
    for (const key of message.services) delete webCaptures[key];
    await chrome.storage.session.set({webCaptures});
  }
  if (message.type === 'permissions-change' && settings.platformCredentials &&
      !await chrome.permissions.contains({origins: ['https://platform.openai.com/*', 'https://api.openai.com/*'], permissions: ['scripting']})) {
    await chrome.storage.local.remove('platformCredentials');
    delete settings.platformCredentials;
  }
  await syncPlatformAuth(settings);
  if (sourceMode(settings) === 'web') {
    if (message.type === 'display') {
      const value = message.value;
      if (!value || Object.keys(value).some(key => !['codex', 'claude'].includes(key)) ||
          Object.values(value).some(shown => typeof shown !== 'boolean')) throw new Error('Réglage invalide. La veille nécessite un Companion Mac.');
      const webDisplay = {...settings.webDisplay, ...value};
      if (webDisplay.codex === false && webDisplay.claude === false) throw new Error('Gardez au moins un fournisseur visible.');
      await chrome.storage.local.set({webDisplay});
      settings.webDisplay = webDisplay;
    }
    const snapshot = await readWebSnapshot(settings, message.type === 'refresh');
    const cached = {snapshot, source: 'web', online: true};
    await chrome.storage.session.set({cached});
    await setBadge(snapshot, true);
    return cached;
  }
  if (!connection) {
    await chrome.storage.session.remove('cached');
    await chrome.action.setBadgeText({text: ''});
    await chrome.action.setTitle({title: 'Quota Display — configurez le Mac source'});
    return {snapshot: null};
  }
  if (message.type === 'refresh') {
    const result = await requestAPI(connection, '/v1/refresh');
    if (result.refresh?.enabled === false) throw new Error('Ce Companion est un client. Configurez l’adresse du Mac qui collecte réellement les quotas.');
    return result;
  }
  if (message.type === 'display') {
    const value = message.value;
    if (!value || Object.keys(value).some(key => !['codex', 'claude', 'sleep'].includes(key))) throw new Error('Réglage invalide.');
    await requestAPI(connection, '/v1/display', value);
  }
  try {
    const snapshot = await requestAPI(connection, '/v1/quotas');
    const cached = {snapshot, source: connection.baseURL, online: true};
    await chrome.storage.session.set({cached});
    await setBadge(snapshot, true);
    return cached;
  } catch (error) {
    const {cached} = await chrome.storage.session.get('cached');
    const snapshot = cached?.source === connection.baseURL ? cached.snapshot : null;
    const result = {snapshot, source: connection.baseURL, online: false, error: error.message};
    await chrome.storage.session.set({cached: result});
    await setBadge(snapshot, false);
    return result;
  }
}

function enqueue(message = {type: 'read'}) {
  const result = pending.then(() => execute(message));
  pending = result.catch(() => {});
  return result;
}

chrome.runtime.onMessage.addListener((message, sender, respond) => {
  if (sender.id !== chrome.runtime.id) return;
  if (message?.type === 'platform-auth') {
    enqueue({type: 'platform-auth', credentials: message.credentials, sender}).then(respond, () => respond({accepted: false}));
    return true;
  }
  let senderURL;
  try { senderURL = new URL(sender.url); } catch { return; }
  if (senderURL.protocol !== 'chrome-extension:' || senderURL.host !== chrome.runtime.id || senderURL.pathname !== '/popup.html' ||
      !['read', 'refresh', 'display', 'connect-web', 'disconnect-web'].includes(message?.type)) return;
  enqueue(message).then(respond, error => respond({error: error.message}));
  return true;
});

async function start() {
  await chrome.alarms.create('quota-read', {periodInMinutes: 1});
  await enqueue();
}
chrome.runtime.onInstalled.addListener(() => { start().catch(() => {}); });
chrome.runtime.onStartup.addListener(() => { start().catch(() => {}); });
chrome.alarms.onAlarm.addListener(alarm => {
  if (alarm.name === 'quota-read') enqueue().catch(() => {});
});
chrome.storage.onChanged.addListener((changes, area) => {
  if (area === 'local' && (changes.connection || changes.badge || changes.sourceMode || changes.webConnected || changes.webDisplay)) enqueue().catch(() => {});
});

function sessionChanged(change) {
  const {cookie, removed, cause} = change;
  const metadata = ['_account', 'lastActiveOrg', '__Secure-1PSID', 'sso'].includes(cookie.name);
  const loggedOut = removed && cause !== 'overwrite' && /session|auth/i.test(cookie.name);
  if (!metadata && !loggedOut) return;
  const domain = cookie.domain.replace(/^\./, '');
  const services = domain === 'chatgpt.com' ? ['codex'] : domain === 'claude.ai' ? ['claude'] :
    domain === 'platform.claude.com' ? ['claudeCredits'] :
    domain === 'google.com' || domain === 'gemini.google.com' ? ['gemini'] : domain === 'grok.com' ? ['grok'] : [];
  if (services.length) enqueue({type: 'cookie-change', services}).catch(() => {});
}
let watchingCookies = false;
function watchCookies() {
  if (!watchingCookies && chrome.cookies?.onChanged) {
    chrome.cookies.onChanged.addListener(sessionChanged);
    watchingCookies = true;
  }
}
watchCookies();
chrome.permissions.onAdded.addListener(() => { watchCookies(); enqueue().catch(() => {}); });
chrome.permissions.onRemoved.addListener(() => { enqueue({type: 'permissions-change'}).catch(() => {}); });
