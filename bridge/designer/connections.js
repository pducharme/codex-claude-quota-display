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
  for (const definition of spec.options || []) {
    if (
      p.source.module === "currency" &&
      definition.key === "base" &&
      (p.source.options?.asset || "Devises") !== "Devises"
    )
      continue;
    const label = document.createElement("label");
    label.className = "field";
    label.textContent = definition.label;
    const input = document.createElement(
      definition.choices ||
        ["shortcut", "remote_choice"].includes(definition.type)
        ? "select"
        : "input",
    );
    input.id = "source-option-" + definition.key;
    if (definition.type === "shortcut") {
      const names = state.shortcuts || [];
      const current = p.source.options?.[definition.key] || "";
      for (const name of [
        "",
        ...new Set([...names, ...(current ? [current] : [])]),
      ]) {
        const option = document.createElement("option");
        option.value = name;
        option.textContent = name || "Choisir un raccourci";
        input.append(option);
      }
    } else if (definition.type === "remote_choice") {
      const current = p.source.options?.[definition.key] || "";
      const choices =
        state.sourceChoices?.[JSON.stringify(p.source.entities)]?.[
          definition.key
        ] || [];
      for (const entry of [
        { value: "", label: "Choisir" },
        ...choices,
        ...(current && !choices.some((c) => c.value === current)
          ? [{ value: current, label: "À actualiser : " + current }]
          : []),
      ]) {
        const option = document.createElement("option");
        option.value = entry.value;
        option.textContent = entry.label;
        input.append(option);
      }
    } else if (definition.choices)
      for (const choice of definition.choices) {
        const option = document.createElement("option");
        option.value = choice;
        option.textContent = choice;
        input.append(option);
      }
    else {
      input.type = definition.type || "text";
      input.placeholder = definition.placeholder || "";
      input.maxLength = 120;
      if (definition.min !== undefined) {
        input.min = definition.min;
        input.max = definition.max;
      }
    }
    input.value = p.source.options?.[definition.key] ?? definition.default;
    input.oninput = input.onchange = () => {
      const value =
        definition.type === "number" ? Number(input.value) : input.value;
      if (p.source.options?.[definition.key] === value) return;
      snapshot();
      p.source.options ||= {};
      p.source.options[definition.key] = value;
      message("Modifications non envoyées.");
      if (p.source.module === "currency" && definition.key === "asset")
        renderSource();
    };
    label.append(input);
    box.append(label);
  }
  if ((spec.options || []).some((d) => d.type === "remote_choice"))
    box.append(
      button("Actualiser les appareils et favoris", async () => {
        try {
          const result = await api("source-preview", { source: p.source });
          state.sourceChoices ||= {};
          state.sourceChoices[JSON.stringify(p.source.entities)] =
            result.choices;
          renderSource();
          message(
            Object.values(result.choices).some((c) => c.length)
              ? "Choix actualisés."
              : "Aucun choix disponible. Vérifiez le lecteur et ses réglages dans Home Assistant.",
          );
        } catch (e) {
          message("Impossible de lire les appareils et favoris.", true);
        }
      }),
    );
  if (p.source.module === "mac_controls")
    box.append(
      button("Actualiser les raccourcis du Mac", async () => {
        try {
          const result = await api("mac-shortcuts", {});
          state.shortcuts = result.shortcuts;
          renderSource();
          message(
            result.shortcuts.length
              ? "Raccourcis chargés depuis le Mac source."
              : "Aucun raccourci disponible. Créez-en un dans l’application Raccourcis du Mac source.",
          );
        } catch (e) {
          message("Impossible de lire les raccourcis du Mac source.", true);
        }
      }),
    );
  const preview = document.createElement("div");
  preview.className = "source-reading";
  preview.setAttribute("role", "status");
  box.append(
    button("Vérifier les données", async () => {
      preview.textContent = "Lecture en cours…";
      try {
        const result = await api("source-preview", { source: p.source });
        preview.replaceChildren();
        for (const [key, name] of [...spec.fields, ["status", "État"]]) {
          const line = document.createElement("p");
          line.textContent =
            name + " : " + (result.values["source." + key] ?? "--");
          preview.append(line);
        }
      } catch (e) {
        preview.textContent =
          "Lecture impossible. Vérifiez les réglages de la page et ses connexions.";
      }
    }),
    preview,
  );
  if (
    !["local", "public"].includes(spec.provider) ||
    (p.source.module === "currency" &&
      (p.source.options?.asset || "Devises") !== "Devises")
  )
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
  renderServiceConnections();
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

function renderServiceConnections() {
  const box = $("service-connections");
  box.replaceChildren();
  for (const [provider, spec] of Object.entries(
    state.connections.services || {},
  )) {
    const section = document.createElement("details"),
      title = document.createElement("summary");
    title.textContent =
      spec.name + (spec.configured ? " — accès enregistrés" : "");
    section.append(title);
    const note = document.createElement("p");
    note.className = "hint";
    note.textContent = spec.note;
    section.append(note);
    const form = document.createElement("form");
    form.method = "post";
    const inputs = {};
    for (const field of spec.fields) {
      const label = document.createElement("label");
      label.className = "field";
      label.textContent = field.label;
      const input = document.createElement("input");
      input.type = field.secret ? "password" : "text";
      input.autocomplete = "off";
      input.required = true;
      input.maxLength = 4096;
      input.id = "service-" + provider + "-" + field.key;
      inputs[field.key] = input;
      label.append(input);
      form.append(label);
    }
    const save = document.createElement("button");
    save.type = "submit";
    save.textContent = "Enregistrer les accès";
    const status = document.createElement("p");
    status.className = "hint";
    status.setAttribute("role", "status");
    form.append(save, status);
    form.onsubmit = async (event) => {
      event.preventDefault();
      save.disabled = true;
      status.textContent = "Enregistrement dans le trousseau…";
      try {
        const credentials = Object.fromEntries(
          Object.entries(inputs).map(([key, input]) => [key, input.value]),
        );
        state.connections = await api("service-connect", {
          provider,
          credentials,
        });
        for (const input of Object.values(inputs)) input.value = "";
        title.textContent = spec.name + " — accès enregistrés";
        status.textContent =
          "Accès enregistrés. Utilisez Vérifier les données dans votre page pour valider la connexion.";
        render();
      } catch (e) {
        status.textContent =
          "Enregistrement impossible. Vérifiez les champs et l’accès au trousseau du Mac source.";
      } finally {
        save.disabled = false;
      }
    };
    section.append(form);
    box.append(section);
  }
}
