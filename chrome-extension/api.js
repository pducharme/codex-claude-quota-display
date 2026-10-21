export function connectionFrom(baseURL, token) {
  const address = String(baseURL || '').trim();
  let url;
  try { url = new URL(address.includes('://') ? address : `http://${address}`); } catch {}
  if (!address || !url || !['http:', 'https:'].includes(url.protocol) || !url.hostname ||
      url.username || url.password || url.search || url.hash || url.pathname !== '/') {
    throw new Error('Saisissez l’adresse HTTP(S) du Mac source, sans chemin ni identifiants.');
  }
  token = String(token || '').trim();
  if (!/^[\x21-\x7e]{16,256}$/.test(token)) {
    throw new Error('La clé API doit contenir de 16 à 256 caractères ASCII, sans espaces.');
  }
  return {baseURL: url.origin, token};
}

export function hostPermission(baseURL) {
  const url = new URL(baseURL);
  return `${url.protocol}//${url.hostname}/*`;
}

export function importedConnection(text) {
  const address = text.match(/^Adresse:\s*(.+)$/mi)?.[1];
  const token = text.match(/^Jeton:\s*(.+)$/mi)?.[1];
  if (!address || !token) throw new Error('Collez les deux lignes « Adresse: » et « Jeton: » copiées depuis le Companion Mac.');
  return connectionFrom(address, token);
}

export async function requestAPI(connection, path, body, fetcher = fetch) {
  if (!['/v1/quotas', '/v1/refresh', '/v1/display'].includes(path)) throw new Error('Action API inconnue.');
  connection = connectionFrom(connection.baseURL, connection.token);
  let response;
  try {
    response = await fetcher(connection.baseURL + path, {
      method: path === '/v1/quotas' ? 'GET' : 'POST',
      headers: {Authorization: `Bearer ${connection.token}`, ...(body ? {'Content-Type': 'application/json'} : {})},
      ...(body ? {body: JSON.stringify(body)} : {}),
      cache: 'no-store', credentials: 'omit', redirect: 'error', signal: AbortSignal.timeout(12000),
    });
  } catch {
    throw new Error('Mac source injoignable. Vérifiez son adresse, le réseau et que le Companion fonctionne.');
  }
  if (response.status === 401) throw new Error('Clé API refusée. Recopiez la configuration API depuis le Mac source.');
  if (!response.ok) throw new Error(`Le Mac source a refusé la demande (HTTP ${response.status}).`);
  let payload;
  try { payload = await response.json(); } catch { throw new Error('Réponse API invalide. Vérifiez l’adresse du Companion.'); }
  const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
  if (payload?.version !== 1 || (path === '/v1/quotas' &&
      (!object(payload.providers?.codex) || !object(payload.providers?.claude)))) {
    throw new Error('Cette réponse ne correspond pas à l’API Quota Display v1.');
  }
  return payload;
}

export function remaining(window) {
  const used = window?.used_percent;
  return typeof used === 'number' && Number.isFinite(used) ? Math.max(0, Math.min(100, 100 - used)) : null;
}

export function badgeState(snapshot, selection = 'codex:five_hour', online = true) {
  if (!online) return {text: '!', color: '#f87171', title: 'Quota Display — Mac source hors ligne'};
  if (selection === 'none') return {text: '', color: '#232e42', title: 'Quota Display'};
  const [name, limit] = selection.split(':');
  const provider = snapshot?.providers?.[name];
  const value = remaining(provider?.[limit]);
  const label = `${name === 'claude' ? 'Claude' : 'Codex'} · ${limit === 'weekly' ? 'semaine' : limit === 'fable_weekly' ? 'Fable' : '5 h'}`;
  const stale = provider?.status !== 'ok';
  return {
    text: value === null ? '—' : `${Math.round(value)}%`,
    color: stale || value === null ? '#7c8da4' : value <= 20 ? '#f87171' : value <= 50 ? '#fbbf24' : '#34d399',
    title: `Quota Display — ${label} : ${value === null ? 'non fourni' : `${Math.round(value)} % libre`}${stale ? ' (données non actualisées)' : ''}`,
  };
}

export function sleepSettings(enabled, start, end, timezone) {
  if (typeof enabled !== 'boolean') throw new Error('Réglage de veille invalide.');
  if (typeof timezone !== 'string' || !timezone.trim()) throw new Error('Fuseau horaire invalide.');
  function minutes(value) {
    if (!/^([01]\d|2[0-3]):[0-5]\d$/.test(value)) throw new Error('Heure de veille invalide.');
    const [h, m] = value.split(':').map(Number);
    return h * 60 + m;
  }
  const start_minute = minutes(start), end_minute = minutes(end);
  if (start_minute === end_minute) throw new Error('Le début et la fin de la veille doivent être différents.');
  try { new Intl.DateTimeFormat('fr', {timeZone: timezone}).format(); } catch { throw new Error('Fuseau horaire invalide.'); }
  return {enabled, start_minute, end_minute, timezone};
}
