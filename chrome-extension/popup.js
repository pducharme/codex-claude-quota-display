import {connectionFrom, importedConnection, hostPermission, sleepSettings} from './api.js';
import {drawDashboard, dashboardSummary, hitTest} from './dashboard.js';
import {WEB_SERVICES} from './web-providers.js';

const $ = id => document.getElementById(id);
const canvas = $('dashboard');
let snapshot = null, online = false, detail = null, detailOffset = 0, frame = 0;
let connection = null, busy = false, sourceRevision = 0, lastRead = 0;
let sourceMode = 'web', webConnected = {};
const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)');
const detachedWindow = location.search.includes('window') || location.search.includes('settings');
document.body.classList.toggle('standalone', detachedWindow);
$('window').hidden = detachedWindow;

function status(message = '') {
  $('status').textContent = message;
  $('status').hidden = !message;
}

function paint() {
  if (detail && snapshot?.display?.[detail] === false) detail = null;
  const shown = snapshot || (sourceMode === 'web' ? {source_mode: 'web'} : null);
  drawDashboard(canvas, shown, {online, detail, frame, detailOffset});
  canvas.setAttribute('aria-label', dashboardSummary(shown, {online, detail}));
  const codex = snapshot?.display?.codex !== false, claude = snapshot?.display?.claude !== false;
  for (const [name, shown, x] of [['codex', codex, 16], ['claude', claude, codex ? 324 : 16]]) {
    const button = $(`${name}-details`);
    button.hidden = !!detail || !shown;
    Object.assign(button.style, {left: `${x / 6.4}%`, top: '5.6%', width: `${(codex && claude ? 300 : 608) / 6.4}%`, height: '63.2%'});
  }
  $('back').hidden = !detail;
  $('canvas-refresh').disabled = busy || (sourceMode === 'web' ? !Object.values(webConnected).some(Boolean) : !connection) || snapshot?.refresh?.active;
  $('refresh').disabled = $('canvas-refresh').disabled;
  $('show-codex').disabled = $('show-claude').disabled = busy || (sourceMode === 'mac' && !online);
  $('source-mode').disabled = busy;
  for (const key of Object.keys(WEB_SERVICES)) {
    $(`connect-${key}`).disabled = $(`disconnect-${key}`).disabled = busy;
  }
}

function applySettings() {
  const web = sourceMode === 'web';
  $('source-mode').value = sourceMode;
  $('web-connections').hidden = !web;
  $('source-form').hidden = web;
  $('sleep-settings').hidden = web;
  $('display-scope').textContent = web ? 'Ces choix s’appliquent uniquement à Chrome.' : 'Ces choix sont partagés avec le Mac source et ses mini-écrans.';
  for (const [key, service] of Object.entries(WEB_SERVICES)) {
    const enabled = webConnected[key] === true;
    $(`connect-${key}`).textContent = enabled ? 'Reconnecter' : 'Connecter';
    $(`connect-${key}`).setAttribute('aria-label', `${enabled ? 'Reconnecter' : 'Connecter'} ${service.label}`);
    $(`disconnect-${key}`).setAttribute('aria-label', `Déconnecter ${service.label}`);
    $(`disconnect-${key}`).hidden = !enabled;
    const state = snapshot?.web_services?.[key];
    $(`state-${key}`).textContent = !enabled ? 'Non connecté' : state?.status === 'ok' ? 'À jour' :
      state?.error_reason === 'authentication_required' ? 'Connexion requise' :
      state?.error_reason === 'permission_required' ? 'Accès à autoriser' :
      state?.status === 'stale' ? 'Dernières données conservées' : 'En attente de lecture';
  }
  $('about').textContent = `Quota Display Chrome ${chrome.runtime.getManifest().version}${web ? ' · sessions web' : `${snapshot?.app_version ? ` · Mac ${snapshot.app_version}` : ''} · client du Companion Mac`}`;
  $('show-codex').checked = snapshot?.display?.codex !== false;
  $('show-claude').checked = snapshot?.display?.claude !== false;
  const sleep = snapshot?.display?.sleep;
  $('sleep-enabled').checked = sleep?.enabled === true;
  function time(value) { return `${String(Math.floor(value / 60)).padStart(2, '0')}:${String(value % 60).padStart(2, '0')}`; }
  if (sleep) {
    $('sleep-start').value = time(sleep.start_minute);
    $('sleep-end').value = time(sleep.end_minute);
    $('timezone').value = sleep.timezone;
  }
  $('show-codex').disabled = $('show-claude').disabled = busy || (!web && !online);
}

async function message(type, value) {
  const result = await chrome.runtime.sendMessage({type, ...(value ? {value} : {})});
  if (!result) throw new Error('Le client Chrome ne répond pas. Rechargez l’extension.');
  return result;
}

async function read() {
  if (busy || (sourceMode === 'mac' && !connection)) return;
  busy = true; lastRead = Date.now();
  const revision = sourceRevision;
  paint();
  try {
    const result = await message('read');
    if (revision !== sourceRevision) return;
    snapshot = result.snapshot || null;
    online = result.online === true;
    const reasons = [];
    if (result.error) reasons.push(result.error);
    if (sourceMode === 'mac' && snapshot?.refresh?.enabled === false) reasons.push('Ce Companion est un client. Choisissez l’adresse du Mac qui collecte les quotas.');
    if (sourceMode === 'web') {
      for (const [key, state] of Object.entries(snapshot?.web_services || {})) {
        if (webConnected[key] !== true || !Object.hasOwn(WEB_SERVICES, key)) continue;
        if (typeof state.error_message === 'string') reasons.push(`${WEB_SERVICES[key].label} : ${state.error_message}`);
        else if (state.error_reason === 'authentication_required') reasons.push(`Reconnectez ${WEB_SERVICES[key].label} dans Chrome.`);
        else if (state.error_reason === 'permission_required') reasons.push(`Autorisez l’accès à ${WEB_SERVICES[key].label} dans les connexions ci-dessous.`);
      }
    } else {
      for (const [name, provider] of Object.entries(snapshot?.providers || {})) {
        if (provider.error_reason === 'authentication_required') reasons.push(`Reconnectez ${name === 'claude' ? 'Claude' : 'Codex'} sur le Mac source.`);
        else if (provider.error_reason === 'desktop_refresh_required') reasons.push('Ouvrez Claude Desktop sur le Mac source pour actualiser sa session.');
        else if (provider.status === 'stale' || provider.status === 'error') reasons.push(`${name === 'claude' ? 'Claude' : 'Codex'} : ${provider.status === 'stale' ? 'dernières données conservées' : 'quotas indisponibles'}. Vérifiez le Companion Mac.`);
      }
    }
    status(reasons.join(' '));
    if (!document.querySelector('form:focus-within')) applySettings();
  } catch (error) { online = false; status(error.message); }
  finally { busy = false; paint(); }
}

async function action(type, value) {
  if (busy || (sourceMode === 'mac' && !connection)) return;
  busy = true; paint();
  try {
    const result = await message(type, value);
    if (result.error) throw new Error(result.error);
    if (type === 'refresh') status(sourceMode === 'web' ? 'Actualisation des sessions web…' : 'Actualisation en cours sur le Mac source…');
  } catch (error) { busy = false; await read(); status(error.message); return; }
  busy = false;
  await read();
}

function details(name) {
  detail = name; detailOffset = 0; paint();
  (name ? $('back') : $('codex-details').hidden ? $('claude-details') : $('codex-details')).focus();
}
for (const name of ['codex', 'claude']) $(`${name}-details`).onclick = () => details(name);
$('back').onclick = () => details(null);
for (const id of ['refresh', 'canvas-refresh']) $(id).onclick = () => action('refresh');
document.addEventListener('keydown', event => {
  if (detail && event.key === 'Escape') { event.preventDefault(); details(null); }
  if (detail && ['ArrowDown', 'ArrowUp', 'PageDown', 'PageUp'].includes(event.key)) {
    event.preventDefault(); scrollDetails(event.key.endsWith('Down') ? 1 : -1);
  }
});
function scrollDetails(step) {
  const count = snapshot?.providers?.[detail]?.banked_resets?.expirations?.length || 0;
  detailOffset = Math.max(0, Math.min(Math.max(0, count - 4), detailOffset + step)); paint();
}
canvas.parentElement.addEventListener('wheel', event => {
  if (detail) { event.preventDefault(); scrollDetails(event.deltaY > 0 ? 1 : -1); }
}, {passive: false});
canvas.addEventListener('click', event => {
  const rect = canvas.getBoundingClientRect();
  const target = hitTest((event.clientX - rect.left) * 640 / rect.width, (event.clientY - rect.top) * 250 / rect.height, snapshot, detail);
  if (target === 'refresh') action('refresh');
  else if (target) details(target === 'back' ? null : target);
});

$('source-mode').onchange = async () => {
  if (busy) { $('source-mode').value = sourceMode; return; }
  const previous = sourceMode;
  sourceMode = $('source-mode').value === 'mac' ? 'mac' : 'web';
  sourceRevision++; snapshot = null; online = false; detail = null;
  try {
    await chrome.storage.local.set({sourceMode});
    applySettings(); paint();
    status(sourceMode === 'web' ? 'Connectez les services à lire dans ce profil Chrome.' : connection ? '' : 'Configurez l’adresse du Companion Mac.');
    await read();
  } catch (error) { sourceMode = previous; applySettings(); paint(); status(error.message); }
};
for (const [key, service] of Object.entries(WEB_SERVICES)) {
  $(`connect-${key}`).onclick = async () => {
    if (busy || sourceMode !== 'web') return;
    try {
      // Keep the permission request inside the button gesture.
      if (!await chrome.permissions.request({origins: service.origins, ...(service.permissions ? {permissions: service.permissions} : {})})) {
        throw new Error(`Chrome n’a pas autorisé l’accès à ${service.label}.`);
      }
      busy = true; sourceRevision++; snapshot = null; online = false; paint();
      const result = await message('connect-web', key);
      if (result.error) throw new Error(result.error);
      webConnected = (await chrome.storage.local.get('webConnected')).webConnected || {};
      applySettings(); paint();
      if (result.needsLogin === true) {
        await chrome.tabs.create({url: service.connectURL});
        status(`Connectez-vous à ${service.label}, puis fermez l’onglet. Les quotas seront actualisés en arrière-plan.`);
      } else {
        busy = false;
        await read();
      }
      lastRead = 0;
    } catch (error) { status(error.message); }
    finally { busy = false; paint(); }
  };
  $(`disconnect-${key}`).onclick = async () => {
    if (busy || sourceMode !== 'web') return;
    busy = true; sourceRevision++; paint();
    try {
      const result = await message('disconnect-web', key);
      if (result.error) throw new Error(result.error);
      webConnected = (await chrome.storage.local.get('webConnected')).webConnected || {};
      snapshot = null; online = false; applySettings();
      status(`Accès à ${service.label} retiré de l’extension. Votre session sur le site reste ouverte.`);
    } catch (error) { status(error.message); }
    finally { busy = false; paint(); lastRead = 0; }
  };
}

$('source-form').onsubmit = async event => {
  event.preventDefault();
  try {
    const candidate = $('import').value.trim() ? importedConnection($('import').value) : connectionFrom($('address').value, $('token').value);
    // Permission requests must start in the submit gesture, before any asynchronous work.
    if (!await chrome.permissions.request({origins: [hostPermission(candidate.baseURL)]})) throw new Error('Chrome n’a pas autorisé l’accès au Mac source.');
    if (busy) throw new Error('Une demande est en cours. Réessayez dans quelques secondes.');
    sourceRevision++;
    await chrome.storage.local.setAccessLevel({accessLevel: 'TRUSTED_CONTEXTS'});
    const previous = connection;
    const oldPermission = connection && hostPermission(connection.baseURL);
    connection = candidate; snapshot = null; online = false;
    try { await chrome.storage.local.set({connection: candidate, sourceMode: 'mac'}); }
    catch (error) { connection = previous; throw error; }
    $('address').value = candidate.baseURL; $('token').value = candidate.token; $('import').value = '';
    if (oldPermission && oldPermission !== hostPermission(candidate.baseURL) &&
        !Object.entries(WEB_SERVICES).some(([key, service]) => webConnected[key] && service.origins.includes(oldPermission))) {
      await chrome.permissions.remove({origins: [oldPermission]});
    }
    await read();
    if (online) { $('source-settings').open = false; status('Connecté au Mac source.'); }
  } catch (error) { status(error.message); }
};
$('copy').onclick = async () => {
  if (!connection) { status('Configurez d’abord le Mac source.'); return; }
  try { await navigator.clipboard.writeText(`Adresse: ${connection.baseURL}\nJeton: ${connection.token}`); status('Configuration API copiée.'); }
  catch { status('Chrome a refusé la copie. Sélectionnez la configuration dans le Companion Mac.'); }
};
$('disconnect').onclick = async () => {
  if (busy) { status('Une demande est en cours. Réessayez dans quelques secondes.'); return; }
  const old = connection; sourceRevision++; connection = null; snapshot = null; online = false;
  await chrome.storage.local.set({sourceMode: 'mac'});
  await chrome.storage.local.remove('connection');
  await chrome.storage.session.remove('cached');
  if (old && !Object.entries(WEB_SERVICES).some(([key, service]) => webConnected[key] && service.origins.includes(hostPermission(old.baseURL)))) {
    await chrome.permissions.remove({origins: [hostPermission(old.baseURL)]});
  }
  $('address').value = $('token').value = $('import').value = '';
  $('source-settings').open = true; applySettings(); paint(); status('Déconnecté.');
};
$('window').onclick = () => chrome.windows.create({url: chrome.runtime.getURL('popup.html?window'), type: 'popup', width: 660, height: 340});
for (const id of ['show-codex', 'show-claude']) $(id).onchange = () => {
  const codex = $('show-codex').checked, claude = $('show-claude').checked;
  if (!codex && !claude) { $(id).checked = true; status('Gardez au moins un fournisseur visible.'); return; }
  action('display', {codex, claude});
};
$('badge').onchange = () => chrome.storage.local.set({badge: $('badge').value});
$('sleep-form').onsubmit = event => {
  event.preventDefault();
  if (sourceMode === 'web') return;
  try { action('display', {sleep: sleepSettings($('sleep-enabled').checked, $('sleep-start').value, $('sleep-end').value, $('timezone').value.trim())}); }
  catch (error) { status(error.message); }
};

await chrome.storage.local.setAccessLevel({accessLevel: 'TRUSTED_CONTEXTS'});
const stored = await chrome.storage.local.get(['connection', 'badge', 'sourceMode', 'webConnected']);
connection = stored.connection || null;
sourceMode = stored.sourceMode === 'web' || stored.sourceMode === 'mac' ? stored.sourceMode : connection ? 'mac' : 'web';
webConnected = stored.webConnected || {};
$('badge').value = stored.badge || 'codex:five_hour';
$('timezone').value = Intl.DateTimeFormat().resolvedOptions().timeZone;
if (connection) {
  $('address').value = connection.baseURL; $('token').value = connection.token;
  const {cached} = await chrome.storage.session.get('cached');
  if (sourceMode === 'mac' && cached?.source === connection.baseURL) snapshot = cached.snapshot;
}
if (sourceMode === 'web' ? !Object.values(webConnected).some(Boolean) : !connection) {
  $('settings').open = $('source-settings').open = true;
  status(sourceMode === 'web' ? 'Connectez les services à lire dans ce profil Chrome.' : 'Connectez l’extension au Companion du Mac source.');
}
if (location.search.includes('settings')) $('settings').open = true;
applySettings(); paint(); await read();
chrome.storage.onChanged.addListener((changes, area) => {
  if (area !== 'local') return;
  if (changes.badge) $('badge').value = changes.badge.newValue || 'codex:five_hour';
  if (changes.sourceMode && changes.sourceMode.newValue !== sourceMode) location.reload();
  if (changes.webConnected) {
    webConnected = changes.webConnected.newValue || {};
    if (sourceMode === 'web') { sourceRevision++; snapshot = null; lastRead = 0; applySettings(); paint(); }
  }
  if (changes.connection && (changes.connection.newValue?.baseURL !== connection?.baseURL ||
      changes.connection.newValue?.token !== connection?.token)) location.reload();
});
setInterval(() => { if (!document.hidden) { if (!reduceMotion.matches) frame++; paint(); } }, 900);
// Read more often only while the selected source is collecting.
setInterval(() => {
  if (!document.hidden && Date.now() - lastRead >= (snapshot?.refresh?.active ? 2000 : 60000)) read();
}, 2000);
