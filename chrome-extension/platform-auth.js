(() => {
  const origin = 'https://platform.openai.com';
  const endpoint = 'https://api.openai.com/v1/dashboard/billing/credit_grants';
  if (location.origin !== origin || window.top !== window || window.fetch.quotaPlatformAuth) return;
  const originalFetch = window.fetch, deadline = Date.now() + 600000;
  let active = true, timer;

  function stop() {
    active = false;
    clearTimeout(timer);
    window.removeEventListener('message', onMessage);
    if (window.fetch === captureFetch) window.fetch = originalFetch;
  }

  function onMessage(event) {
    if (event.source === window && event.origin === origin && event.data?.type === 'quota-platform-stop') stop();
  }

  function captureFetch(input, init) {
    let credentials;
    try {
      const url = new URL(input instanceof Request ? input.url : input, location.href);
      const method = init?.method ?? (input instanceof Request ? input.method : 'GET');
      if (active && Date.now() < deadline && url.href === endpoint && method.toUpperCase() === 'GET') {
        const headers = new Headers(init?.headers ?? (input instanceof Request ? input.headers : undefined));
        const match = /^Bearer (sess-[A-Za-z0-9_-]{1,8192})$/i.exec(headers.get('Authorization') ?? '');
        const organization = headers.get('OpenAI-Organization');
        if (match && /^org-[A-Za-z0-9]{1,124}$/.test(organization ?? '')) {
          credentials = {token: match[1], organization};
        }
      }
    } catch {}
    const pending = originalFetch.apply(this, arguments);
    if (credentials) pending.then(response => {
      if (!active || Date.now() >= deadline || response.status !== 200 || response.redirected ||
          (response.url && response.url !== endpoint)) return;
      window.postMessage({type: 'quota-platform-auth', ...credentials}, origin);
      stop();
    }).catch(() => {});
    return pending;
  }

  Object.defineProperty(captureFetch, 'quotaPlatformAuth', {value: true});
  window.fetch = captureFetch;
  window.addEventListener('message', onMessage);
  timer = setTimeout(stop, 600000);
})();
