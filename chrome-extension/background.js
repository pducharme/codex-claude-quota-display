import {requestAPI, badgeState} from './api.js';

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
  const {connection} = await chrome.storage.local.get('connection');
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
  if (sender.id !== chrome.runtime.id || !sender.url?.startsWith(chrome.runtime.getURL('popup.html')) ||
      !['read', 'refresh', 'display'].includes(message?.type)) return;
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
  if (area === 'local' && (changes.connection || changes.badge)) enqueue().catch(() => {});
});
