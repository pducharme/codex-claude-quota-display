/* Connection setup stays separate from the page document and its undo history. */
function renderSource() {
  const p = page(),
    box = $("source-settings");
  box.replaceChildren();
  box.hidden = !p.source;
  $("binding")
    .querySelectorAll("[data-source]")
    .forEach((el) => el.remove());
  if (!p.source) return;
  const spec = state.connections.modules[p.source.module];
  const title = document.createElement("h2");
  title.textContent = "Connecter cette page";
  const note = document.createElement("p");
  note.className = "hint";
  note.textContent = spec.requires;
  box.append(title, note);
  for (const [slot, name, domains] of spec.slots) {
    const label = document.createElement("label");
    label.className = "field";
    label.textContent = name;
    const select = document.createElement("select");
    select.id = "source-" + slot;
    const empty = document.createElement("option");
    empty.value = "";
    empty.textContent = "Choisir un appareil ou un service";
    select.append(empty);
    const current = p.source.entities[slot] || "";
    const candidates = state.connections.entities.filter((e) =>
      domains.includes(e.domain),
    );
    for (const e of candidates) {
      const option = document.createElement("option");
      option.value = e.id;
      option.textContent = e.name;
      select.append(option);
    }
    if (current && !candidates.some((e) => e.id === current)) {
      const option = document.createElement("option");
      option.value = current;
      option.textContent = "Introuvable : " + current;
      select.append(option);
    }
    select.value = current;
    select.onchange = () =>
      changed(() => {
        p.source.entities[slot] = select.value;
      });
    label.append(select);
    box.append(label);
  }
  box.append(button("Gérer les connexions", openConnections));
  const select = $("binding");
  select.querySelectorAll("[data-source]").forEach((el) => el.remove());
  for (const [field, label] of [
    ...spec.fields,
    ["status", "État de la connexion"],
    ...(spec.progress ? [["progress", "Progression (%)"]] : []),
  ]) {
    const option = document.createElement("option");
    option.value = "source." + field;
    option.textContent = spec.name + " — " + label;
    option.dataset.source = "true";
    select.append(option);
  }
}
function connectionStatus() {
  const c = state.connections.home_assistant;
  $("ha-status").textContent =
    c.status === "ok"
      ? "Connecté. Choisissez maintenant les appareils dans votre page."
      : c.connected
        ? "Connexion indisponible. Vérifiez l’adresse et le jeton."
        : "Home Assistant n’est pas encore connecté.";
}
function openConnections() {
  $("ha-url").value = state.connections.home_assistant.url || "";
  $("ha-token").value = "";
  connectionStatus();
  $("connections").showModal();
}
$("open-connections").onclick = openConnections;
$("close-connections").onclick = () => $("connections").close();
$("ha-connect").onsubmit = async (event) => {
  event.preventDefault();
  $("save-connection").disabled = true;
  $("ha-status").textContent = "Vérification de la connexion…";
  try {
    state.connections = await api("connect", {
      url: $("ha-url").value,
      token: $("ha-token").value,
    });
    $("ha-token").value = "";
    connectionStatus();
    render();
  } catch (e) {
    $("ha-status").textContent =
      "Connexion impossible. Vérifiez l’adresse, le jeton et l’accès réseau au Mac source.";
  } finally {
    $("save-connection").disabled = false;
  }
};
$("refresh-connections").onclick = async () => {
  try {
    state.connections = await api("connections", {});
    connectionStatus();
    render();
  } catch (e) {
    $("ha-status").textContent = e.message;
  }
};
