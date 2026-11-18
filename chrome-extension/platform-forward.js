(() => {
  const origin = 'https://platform.openai.com';
  if (location.origin !== origin || window.top !== window || globalThis.quotaPlatformForward) return;
  globalThis.quotaPlatformForward = true;
  const deadline = Date.now() + 600000;
  let active = true, timer;

  function stop() {
    active = false;
    clearTimeout(timer);
    window.removeEventListener('message', onMessage);
    chrome.runtime.onMessage.removeListener(onRuntimeMessage);
    delete globalThis.quotaPlatformForward;
    window.postMessage({type: 'quota-platform-stop'}, origin);
  }

  function onRuntimeMessage(message, sender, respond) {
    if (sender.id === chrome.runtime.id && message?.type === 'quota-platform-stop') {
      stop();
      respond?.({ok: true});
    }
  }

  function onMessage(event) {
    if (!active || Date.now() >= deadline || event.source !== window || event.origin !== origin) return;
    const value = event.data;
    if (!value || typeof value !== 'object' || Array.isArray(value) ||
        Object.keys(value).length !== 3 || value.type !== 'quota-platform-auth' ||
        typeof value.token !== 'string' || !/^sess-[A-Za-z0-9_-]{1,8192}$/.test(value.token) ||
        typeof value.organization !== 'string' || !/^org-[A-Za-z0-9]{1,124}$/.test(value.organization)) return;
    try {
      chrome.runtime.sendMessage({type: 'platform-auth', credentials: {
        token: value.token, organization: value.organization,
      }}).catch(() => {});
    } catch {}
    stop();
  }

  window.addEventListener('message', onMessage);
  chrome.runtime.onMessage.addListener(onRuntimeMessage);
  timer = setTimeout(stop, 600000);
})();
