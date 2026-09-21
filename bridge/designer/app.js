"use strict";
const $ = (id) => document.getElementById(id),
  clone = (x) => JSON.parse(JSON.stringify(x));
let state,
  config,
  fonts,
  pageIndex = 0,
  selected = -1,
  history = [],
  future = [],
  dirty = false,
  drag = null;
const chosen = new Set(),
  canvas = $("preview"),
  ctx = canvas.getContext("2d");
const examples = {
  clock: "12:48",
  date: "20 / 09 / 2026",
  "codex.5h": 82,
  "codex.week": 68,
  "claude.5h": 91,
  "claude.week": 74,
  "weather.temperature": "21 °C",
  "weather.condition": "Éclaircies",
  "weather.rain": "Pluie prévue · 14 h–15 h",
  "focus.remaining": "25:00",
  "focus.phase": "Focus · 0 terminé(s)",
  "source.title": "Votre morceau",
  "source.artist": "Artiste",
  "source.volume": "45 %",
  "source.primary": "72",
  "source.secondary": "18",
  "source.third": "23",
  "source.status": "Données d’exemple",
  "source.start": "14:30",
  "source.remaining": "25 min",
  "source.progress": 72,
  "source.cpu": "24 %",
  "source.memory": "16 Go",
  "source.network": "120 / 45 Ko/s",
  "source.muted": "Non",
  "source.shortcut": "Ambiance bureau",
  "source.build": "Déployer le site",
  "source.result": "Réussi",
  "source.branch": "main",
  "source.subscribers": "12 300",
  "source.views": "840 000",
  "source.goal": "15 000",
  "source.latest": "Votre dernière vidéo",
  "source.viewers": "248",
  "source.duration": "1 h 23",
  "source.rate": "0.7148 USD",
  "source.change": "+0.2 %",
  "source.date": "21/09/2026",
  "source.team": "MTL",
  "source.opponent": "TOR",
  "source.score": "2 - 1",
  "source.period": "Période 3 · 05:10",
};
const descriptions = [
  "Les quotas restants, à votre façon.",
  "La température et les conditions du moment.",
  "Une grande heure, sans distraction.",
  "Travail, pauses et compteur de cycles. Commande tactile.",
  "Le vol qui passe, son trajet et son appareil.",
  "Composez avec des textes, valeurs et jauges.",
];
function message(text, error = false) {
  $("message").textContent = text;
  $("message").classList.toggle("error", error);
}
async function api(path, body) {
  const response = await fetch("/designer/api/" + path, {
    method: body ? "POST" : "GET",
    headers: body
      ? {
          "Content-Type": "application/json",
          "X-Designer-CSRF": document.querySelector("meta[name=designer-csrf]")
            .content,
        }
      : {},
    body: body ? JSON.stringify(body) : undefined,
  });
  let data = await response.json();
  if (!response.ok) throw Error(data.error || "Connexion indisponible.");
  return data;
}
function snapshot() {
  history.push(clone(config));
  history = history.slice(-40);
  future = [];
  dirty = true;
  $("undo").disabled = false;
  $("redo").disabled = true;
}
function page() {
  return config.pages[pageIndex];
}
function element() {
  return page().blocks[selected];
}
function changed(fn) {
  snapshot();
  fn();
  render();
  message("Modifications non envoyées.");
}
function text(value, x, y, w, h, size, font, color) {
  ctx.fillStyle = color;
  let cursor = x;
  for (const original of String(value)
    .replace(/[’‘]/g, "'")
    .replace(/[—–]/g, "-")) {
    let c = original.codePointAt(0);
    if (c < 32 || c > 255) c = 63;
    const glyph = fonts[font][c - 32],
      advance = glyph[0] * size;
    if (cursor + advance > x + w) break;
    for (let row = 0; row < 16; row++)
      for (let col = 0; col < glyph[0]; col++)
        if (glyph[row + 1] & (1 << col)) {
          if (row * size + size <= h)
            ctx.fillRect(cursor + col * size, y + row * size, size, size);
        }
    cursor += advance;
  }
}
function draw() {
  if (!fonts || !config) return;
  const p = page(),
    fg = "#e6edf5",
    muted = "#a5b8ca";
  ctx.fillStyle = p.background;
  ctx.fillRect(0, 0, 640, 180);
  if (p.kind === "sky") {
    text("Vol d’exemple", 18, 12, 370, 20, 1, p.font, muted);
    text("À proximité · 8 km", 408, 12, 218, 20, 1, p.font, muted);
    text("YUL", 18, 55, 130, 40, 2, p.font, fg);
    text("Montréal", 18, 101, 145, 20, 1, p.font, muted);
    text("CDG", 520, 55, 114, 40, 2, p.font, fg);
    text("Paris", 520, 101, 114, 20, 1, p.font, muted);
    ctx.strokeStyle = p.accent;
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.moveTo(165, 111);
    ctx.quadraticCurveTo(320, 14, 475, 111);
    ctx.stroke();
    const x = 295,
      y = 64;
    ctx.fillStyle = p.accent;
    ctx.fillRect(x - 12, y - 2, 24, 4);
    ctx.beginPath();
    ctx.moveTo(x + 5, y);
    ctx.lineTo(x - 5, y - 12);
    ctx.lineTo(x - 1, y);
    ctx.lineTo(x - 5, y + 12);
    ctx.closePath();
    ctx.fill();
    ctx.beginPath();
    ctx.moveTo(x - 8, y);
    ctx.lineTo(x - 14, y - 6);
    ctx.lineTo(x - 12, y);
    ctx.lineTo(x - 14, y + 6);
    ctx.closePath();
    ctx.fill();
    text("Trajet estimé", 231, 111, 232, 20, 1, p.font, muted);
    text("Airbus A330", 18, 150, 228, 22, 1, p.font, fg);
    text("870 km/h", 280, 150, 150, 22, 1, p.font, fg);
    text("10 700 m", 493, 150, 143, 22, 1, p.font, fg);
    return;
  }
  if (p.kind.startsWith("native-")) {
    text(p.name, 20, 20, 600, 32, 2, "pixel", fg);
    text("Présentation actuelle conservée", 20, 90, 600, 24, 1, "pixel", muted);
    text(
      "Ajoutez un modèle pour le personnaliser.",
      20,
      126,
      600,
      24,
      1,
      "pixel",
      muted,
    );
    return;
  }
  p.blocks.forEach((b, i) => {
    let value = examples[b.binding],
      label = b.binding
        ? (
            b.text +
            " " +
            String(value ?? "--") +
            (/^(codex|claude)\./.test(b.binding) ? " %" : "")
          ).trim()
        : b.text;
    ctx.save();
    ctx.beginPath();
    ctx.rect(b.x, b.y, b.w, b.h);
    ctx.clip();
    if (b.type === "artwork") {
      ctx.fillStyle = "#26364a";
      ctx.fillRect(b.x, b.y, b.w, b.h);
      ctx.fillStyle = p.accent;
      ctx.beginPath();
      ctx.arc(
        b.x + b.w / 2,
        b.y + b.h / 2,
        Math.min(b.w, b.h) * 0.3,
        0,
        Math.PI * 2,
      );
      ctx.fill();
      ctx.fillStyle = "#26364a";
      ctx.beginPath();
      ctx.arc(
        b.x + b.w / 2,
        b.y + b.h / 2,
        Math.min(b.w, b.h) * 0.06,
        0,
        Math.PI * 2,
      );
      ctx.fill();
    } else if (b.type === "pixels") {
      drawPixels(ctx, b, p.accent);
    } else if (b.type === "bar") {
      ctx.fillStyle = "#26364a";
      ctx.fillRect(b.x, b.y, b.w, b.h);
      ctx.fillStyle = p.accent;
      ctx.fillRect(
        b.x,
        b.y,
        (b.w * Math.max(0, Math.min(100, Number(value) || 0))) / 100,
        b.h,
      );
    } else {
      if (b.type === "button") {
        ctx.fillStyle = "#26364a";
        ctx.fillRect(b.x, b.y, b.w, b.h);
      }
      text(
        label,
        b.x + (b.type === "button" ? 8 : 0),
        b.y + (b.type === "button" ? Math.max(0, (b.h - 16 * b.size) / 2) : 0),
        b.w - (b.type === "button" ? 16 : 0),
        b.h,
        b.size,
        p.font,
        b.type === "value" ? p.accent : fg,
      );
    }
    ctx.restore();
    if (i === selected) {
      ctx.strokeStyle = "#ffcc66";
      ctx.lineWidth = 1;
      ctx.setLineDash([4, 3]);
      ctx.strokeRect(b.x + 0.5, b.y + 0.5, b.w - 1, b.h - 1);
      ctx.setLineDash([]);
    }
  });
}
function button(label, fn, cls = "") {
  const b = document.createElement("button");
  b.textContent = label;
  b.className = cls;
  b.onclick = fn;
  return b;
}
function deviceList() {
  const wrap = $("devices");
  wrap.replaceChildren();
  const title = document.createElement("h2");
  title.textContent = "Écrans";
  wrap.append(title);
  if (!state.devices.length) {
    const p = document.createElement("p");
    p.className = "hint";
    p.textContent =
      "Les écrans apparaîtront après leur première mise à jour et connexion au nouveau moteur.";
    wrap.append(p);
  }
  for (const d of state.devices) {
    const label = document.createElement("label");
    label.className = "check";
    const check = document.createElement("input");
    check.type = "checkbox";
    check.checked = chosen.has(d.id);
    check.onchange = () => {
      check.checked ? chosen.add(d.id) : chosen.delete(d.id);
      $("publish").disabled = !chosen.size;
    };
    const text = document.createElement("span");
    text.textContent = "Écran " + d.id.slice(-6).toUpperCase();
    const status = document.createElement("span");
    status.className = "device-status";
    status.textContent = !d.online
      ? "Hors ligne — envoi en attente"
      : d.desired && d.applied === d.desired
        ? "Publication appliquée"
        : d.desired
          ? "Publication en attente"
          : "Connecté";
    text.append(status);
    label.append(check, text);
    wrap.append(label);
  }
  $("publish").disabled = !chosen.size;
}
function render() {
  pageIndex = Math.min(pageIndex, config.pages.length - 1);
  const p = page();
  $("pages").replaceChildren();
  config.pages.forEach((p, i) => {
    let b = button(
      p.name || "Sans titre",
      () => {
        pageIndex = i;
        selected = -1;
        render();
      },
      "page",
    );
    b.setAttribute("aria-pressed", i === pageIndex);
    $("pages").append(b);
  });
  $("preview-name").textContent = p.name;
  $("page-name").value = p.name;
  $("font").value = p.font;
  $("accent").value = p.accent;
  $("background").value = p.background;
  $("weather-city").value = config.city;
  $("rotation").value = String(config.rotation);
  const custom = p.kind === "custom";
  for (const id of ["add-block", "new-type"]) $(id).disabled = !custom;
  $("font").disabled = p.kind.startsWith("native-");
  $("accent").disabled = p.kind.startsWith("native-");
  $("background").disabled = p.kind.startsWith("native-");
  $("hint").textContent = custom
    ? "Cliquez sur un élément pour le modifier. Glissez-le dans l’aperçu ou utilisez ses réglages."
    : p.kind === "sky"
      ? "Le trajet et l’avion sont placés automatiquement. Choisissez votre police, vos couleurs et votre zone."
      : "Cette page conserve le rendu actuel. Ajoutez un modèle Quotas ou Météo pour une page personnalisable.";
  renderSource();
  $("blocks").replaceChildren();
  p.blocks.forEach((b, i) => {
    const item = button(
      b.type === "pixels"
        ? "Pixel art"
        : b.text ||
            (b.binding
              ? Array.from($("binding").options).find(
                  (o) => o.value === b.binding,
                )?.textContent
              : "Élément") ||
            "Élément",
      () => {
        selected = i;
        render();
      },
      "block",
    );
    item.setAttribute("aria-pressed", i === selected);
    item.onkeydown = (e) => {
      if (["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"].includes(e.key)) {
        e.preventDefault();
        changed(() => {
          b.x = Math.max(
            0,
            Math.min(
              640 - b.w,
              b.x + ({ ArrowLeft: -8, ArrowRight: 8 }[e.key] || 0),
            ),
          );
          b.y = Math.max(
            0,
            Math.min(
              180 - b.h,
              b.y + ({ ArrowUp: -8, ArrowDown: 8 }[e.key] || 0),
            ),
          );
        });
      }
    };
    $("blocks").append(item);
  });
  const b = element();
  $("element-settings").hidden = !b;
  if (b)
    for (const key of ["text", "binding", "size", "x", "y", "w", "h"])
      $(key).value = b[key];
  $("remove-page").disabled = config.pages.length <= 1;
  $("undo").disabled = !history.length;
  $("redo").disabled = !future.length;
  $("rollback").disabled = !state.rollback;
  $("sky-settings").hidden = !config.pages.some((p) => p.kind === "sky");
  $("sky-enabled").checked = config.sky.enabled;
  $("auto-sky").checked = config.auto_sky;
  $("latitude").value = config.sky.lat ?? "";
  $("longitude").value = config.sky.lon ?? "";
  $("radius").value = config.sky.radius;
  renderPixelEditor();
  draw();
}
for (const [id, key] of [
  ["page-name", "name"],
  ["font", "font"],
  ["accent", "accent"],
  ["background", "background"],
])
  $(id).onchange = () => changed(() => (page()[key] = $(id).value));
$("weather-city").onchange = () =>
  changed(() => (config.city = $("weather-city").value));
$("rotation").onchange = () =>
  changed(() => (config.rotation = Number($("rotation").value)));
for (const key of ["text", "binding", "size", "x", "y", "w", "h"])
  $(key).onchange = () =>
    changed(() => {
      const b = element();
      b[key] = ["text", "binding"].includes(key)
        ? $(key).value
        : Number($(key).value);
      b.x = Math.max(0, Math.min(632, b.x));
      b.y = Math.max(0, Math.min(172, b.y));
      b.w = Math.max(8, Math.min(640 - b.x, b.w));
      b.h = Math.max(8, Math.min(180 - b.y, b.h));
    });
$("text").oninput = $("text").onchange;
$("page-name").oninput = $("page-name").onchange;
$("remove-block").onclick = () =>
  changed(() => {
    page().blocks.splice(selected, 1);
    selected = -1;
  });
$("remove-page").onclick = () =>
  changed(() => {
    config.pages.splice(pageIndex, 1);
    pageIndex = Math.max(0, pageIndex - 1);
    selected = -1;
    if (!config.pages.some((p) => p.kind === "sky")) {
      config.auto_sky = false;
      config.sky.enabled = false;
    }
  });
$("add-block").onclick = () => {
  if (page().blocks.length >= 16)
    return message("Maximum de seize éléments par page.", true);
  changed(() => {
    const type = $("new-type").value;
    page().blocks.push({
      type,
      x: 16 + (page().blocks.length % 2) * 312,
      y:
        type === "pixels"
          ? 16
          : 16 + (Math.floor(page().blocks.length / 2) % 4) * 40,
      w: type === "pixels" ? 128 : 280,
      h: type === "pixels" ? 128 : 32,
      size: 1,
      text:
        type === "text"
          ? "Votre texte"
          : type === "button"
            ? "Démarrer / pause"
            : "",
      binding: type === "value" ? "clock" : type === "bar" ? "codex.week" : "",
      action: type === "button" ? "focus.toggle" : "",
    });
    selected = page().blocks.length - 1;
  });
};
$("add-page").onclick = () => {
  $("gallery").showModal();
};
$("close-gallery").onclick = () => $("gallery").close();
$("undo").onclick = () => {
  if (history.length) {
    future.push(clone(config));
    config = history.pop();
    selected = -1;
    dirty = true;
    render();
  }
};
$("redo").onclick = () => {
  if (future.length) {
    history.push(clone(config));
    config = future.pop();
    selected = -1;
    dirty = true;
    render();
  }
};
for (const [id, key] of [
  ["latitude", "lat"],
  ["longitude", "lon"],
  ["radius", "radius"],
])
  $(id).onchange = () =>
    changed(
      () => (config.sky[key] = $(id).value === "" ? null : Number($(id).value)),
    );
$("sky-enabled").onchange = () =>
  changed(() => (config.sky.enabled = $("sky-enabled").checked));
$("auto-sky").onchange = () =>
  changed(() => {
    config.auto_sky = $("auto-sky").checked;
    if (config.auto_sky) config.sky.enabled = true;
  });
$("find-place").onclick = async () => {
  try {
    const data = await api("places", { query: $("place-query").value });
    $("places").replaceChildren();
    const placeholder = document.createElement("option");
    placeholder.textContent = "Choisir le lieu";
    placeholder.value = "";
    $("places").append(placeholder);
    for (const place of data.places) {
      const option = document.createElement("option");
      option.textContent = place.name;
      option.value = JSON.stringify(place);
      $("places").append(option);
    }
    $("places").hidden = false;
    if (!data.places.length)
      message("Aucun lieu trouvé. Essayez une autre municipalité.", true);
  } catch (e) {
    message(e.message, true);
  }
};
$("places").onchange = () => {
  if ($("places").value)
    changed(() => {
      const p = JSON.parse($("places").value);
      config.sky.lat = p.lat;
      config.sky.lon = p.lon;
    });
};
$("publish").onclick = async () => {
  const button = $("publish");
  button.disabled = true;
  try {
    state = await api("publish", {
      config,
      targets: [...chosen],
      base_revision: state.revision,
    });
    dirty = false;
    history = [];
    future = [];
    render();
    deviceList();
    message("Publication envoyée. En attente de confirmation des écrans.");
  } catch (e) {
    message(e.message, true);
  } finally {
    button.disabled = !chosen.size;
  }
};
$("rollback").onclick = async () => {
  try {
    state = await api("rollback", { base_revision: state.revision });
    config = clone(state.config);
    selected = -1;
    dirty = false;
    history = [];
    future = [];
    render();
    deviceList();
    message("Version précédente envoyée.");
  } catch (e) {
    message(e.message, true);
  }
};
function point(e) {
  const r = canvas.getBoundingClientRect();
  return {
    x: ((e.clientX - r.left) * 640) / r.width,
    y: ((e.clientY - r.top) * 180) / r.height,
  };
}
canvas.onpointerdown = (e) => {
  if (page().kind !== "custom") return;
  const pos = point(e);
  selected = page().blocks.findLastIndex
    ? page().blocks.findLastIndex(
        (b) =>
          pos.x >= b.x &&
          pos.x <= b.x + b.w &&
          pos.y >= b.y &&
          pos.y <= b.y + b.h,
      )
    : (page()
        .blocks.map((b, i) => ({ b, i }))
        .reverse()
        .find(
          ({ b }) =>
            pos.x >= b.x &&
            pos.x <= b.x + b.w &&
            pos.y >= b.y &&
            pos.y <= b.y + b.h,
        )?.i ?? -1);
  const b = element();
  if (b) {
    drag = { x: pos.x - b.x, y: pos.y - b.y, saved: false };
    canvas.setPointerCapture(e.pointerId);
  }
  render();
};
canvas.onpointermove = (e) => {
  if (!drag) return;
  const pos = point(e),
    b = element();
  if (!drag.saved) {
    snapshot();
    drag.saved = true;
  }
  b.x = Math.max(0, Math.min(640 - b.w, Math.round((pos.x - drag.x) / 8) * 8));
  b.y = Math.max(0, Math.min(180 - b.h, Math.round((pos.y - drag.y) / 8) * 8));
  draw();
};
canvas.onpointerup = () => {
  if (drag?.saved) message("Modifications non envoyées.");
  drag = null;
  render();
};
canvas.onpointercancel = () => {
  drag = null;
  render();
};
window.addEventListener("beforeunload", (e) => {
  if (dirty) {
    e.preventDefault();
    e.returnValue = "";
  }
});
async function init() {
  try {
    [state, fonts] = await Promise.all([
      api("state"),
      fetch("/designer/fonts.json").then((r) => {
        if (!r.ok) throw Error("Polices indisponibles.");
        return r.json();
      }),
    ]);
    config = clone(state.config);
    for (const d of state.devices) if (d.online) chosen.add(d.id);
    state.templates.forEach((p, i) => {
      const b = button(
        "",
        () => {
          if (config.pages.length >= 8)
            return message("Maximum de huit pages.", true);
          changed(() => {
            const next = clone(p);
            next.id = Array.from(
              crypto.getRandomValues(new Uint8Array(8)),
              (v) => v.toString(16).padStart(2, "0"),
            ).join("");
            config.pages.push(next);
            pageIndex = config.pages.length - 1;
            selected = -1;
          });
          $("gallery").close();
        },
        "template",
      );
      const name = document.createElement("strong"),
        desc = document.createElement("span");
      name.textContent = p.name;
      desc.textContent = p.description || descriptions[i];
      if (p.requires) {
        const requires = document.createElement("small");
        requires.textContent = p.requires;
        b.append(requires);
      }
      b.dataset.search = [p.name, p.category || "", p.description || ""]
        .join(" ")
        .toLocaleLowerCase("fr");
      b.prepend(name, desc);
      $("templates").append(b);
    });
    $("template-search").oninput = () => {
      const query = $("template-search").value.toLocaleLowerCase("fr").trim();
      for (const card of $("templates").children)
        card.hidden = !card.dataset.search.includes(query);
    };
    render();
    deviceList();
    message(
      state.load_error
        ? "La configuration enregistrée est illisible. Vos pages classiques restent disponibles."
        : "Choisissez une page ou ajoutez un modèle.",
      state.load_error,
    );
    setInterval(async () => {
      try {
        const fresh = await api("state");
        if (fresh.revision !== state.revision) {
          message(
            "Une autre publication est disponible. Rouvrez le Designer pour la charger.",
            true,
          );
          return;
        }
        state.devices = fresh.devices;
        deviceList();
        if (
          !dirty &&
          $("message").textContent.startsWith("Publication envoyée") &&
          [...chosen].every((id) =>
            fresh.devices.some(
              (d) =>
                d.id === id &&
                d.online &&
                d.desired > 0 &&
                d.applied === d.desired,
            ),
          )
        )
          message("Publication appliquée sur les écrans sélectionnés.");
        const status = fresh.flights;
        $("flight-state").textContent =
          status.status === "ok"
            ? `${status.flights.filter((f) => f.inside).length} avion(s) dans la zone publiée.`
            : status.status === "disabled"
              ? "Surveillance désactivée."
              : status.status === "loading"
                ? "Première recherche en cours."
                : "Données de vol momentanément indisponibles.";
      } catch (e) {
        message(e.message, true);
      }
    }, 4000);
  } catch (e) {
    message(e.message, true);
  }
}
document.addEventListener("DOMContentLoaded", init);
