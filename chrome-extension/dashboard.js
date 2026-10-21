// Pixel glyphs, geometry and mascots match bridge/quota_menu.swift.
const GLYPHS = {" ":[0,0,0,0,0],"%":[35,19,8,100,98],"-":[8,8,8,8,8],"—":[8,8,8,8,8],".":[0,0,96,96,0],":":[0,0,20,0,0],"?":[2,1,89,9,6],"[":[0,127,65,65,65],"]":[0,65,65,65,127],"_":[64,64,64,64,64],"0":[62,81,73,69,62],"1":[0,66,127,64,0],"2":[114,73,73,73,70],"3":[33,65,73,77,51],"4":[24,20,18,127,16],"5":[39,69,69,69,57],"6":[60,74,73,73,49],"7":[65,33,17,9,7],"8":[54,73,73,73,54],"9":[70,73,73,41,30],"A":[124,18,17,18,124],"B":[127,73,73,73,54],"C":[62,65,65,65,34],"D":[127,65,65,65,62],"E":[127,73,73,73,65],"F":[127,9,9,9,1],"G":[62,65,65,81,115],"H":[127,8,8,8,127],"I":[0,65,127,65,0],"J":[32,64,65,63,1],"K":[127,8,20,34,65],"L":[127,64,64,64,64],"M":[127,2,28,2,127],"N":[127,4,8,16,127],"O":[62,65,65,65,62],"P":[127,9,9,9,6],"Q":[62,65,81,33,94],"R":[127,9,25,41,70],"S":[38,73,73,73,50],"T":[3,1,127,1,3],"U":[63,64,64,64,63],"V":[31,32,64,32,31],"W":[63,64,56,64,63],"X":[99,20,8,20,99],"Y":[3,4,120,4,3],"Z":[97,89,73,77,67],"a":[32,84,84,120,64],"b":[127,40,68,68,56],"c":[56,68,68,68,40],"d":[56,68,68,40,127],"e":[56,84,84,84,24],"è":[57,85,84,84,88],"f":[0,8,126,9,2],"g":[24,164,164,156,120],"h":[127,8,4,4,120],"i":[0,68,125,64,0],"j":[32,64,64,61,0],"k":[127,16,40,68,0],"l":[0,65,127,64,0],"m":[124,4,120,4,120],"n":[124,8,4,4,120],"o":[56,68,68,68,56],"p":[252,24,36,36,24],"q":[24,36,36,24,252],"r":[124,8,4,4,8],"s":[72,84,84,84,36],"t":[4,4,63,68,36],"u":[60,64,64,32,124],"v":[28,32,64,32,28],"w":[60,64,48,64,60],"x":[68,40,16,40,68],"y":[76,144,144,144,124],"z":[68,100,84,76,68]};

const C = {
  screen: "#070a12", cell: "#131b2b", track: "#232e42", text: "#e6edf5",
  muted: "#7c8da4", codex: "#38bdf8", claude: "#d97757",
  codexPanel: "#081d30", claudePanel: "#2b1815",
  green: "#34d399", amber: "#fbbf24", red: "#f87171",
};
const SYSTEM_FONT = '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif';
const MONO_FONT = 'ui-monospace, "SFMono-Regular", Consolas, monospace';
const finite = (value) => typeof value === "number" && Number.isFinite(value);
const clamp = (value, low, high) => Math.max(low, Math.min(high, value));
const remaining = (window) => finite(window?.used_percent) ? clamp(100 - Math.trunc(window.used_percent), 0, 100) : null;
const remainingText = (window) => remaining(window) == null ? "—%" : `${remaining(window)}%`;
const resetCount = (provider) => Number.isInteger(provider?.banked_resets?.available_count) && provider.banked_resets.available_count >= 0 ? provider.banked_resets.available_count : null;
const quotaColor = (percent) => percent == null ? C.muted : percent <= 20 ? C.red : percent <= 50 ? C.amber : C.green;

function panels(snapshot) {
  let codex = snapshot?.display?.codex !== false;
  let claude = snapshot?.display?.claude !== false;
  if (!codex && !claude) codex = claude = true;
  return {
    codex: codex ? [16, 14, claude ? 300 : 608, 158] : null,
    claude: claude ? [codex ? 324 : 16, 14, codex ? 300 : 608, 158] : null,
  };
}

function countdown(reset, now) {
  if (!finite(reset) || reset <= now) return "—";
  const seconds = Math.floor(reset - now);
  const days = Math.floor(seconds / 86400);
  const hours = Math.floor(seconds % 86400 / 3600);
  const minutes = Math.floor(seconds % 3600 / 60);
  return days ? `${days}j ${hours}h` : hours ? `${hours}h ${minutes}m` : `${minutes}m`;
}

function dateText(epoch, timeOnly = false, now = Math.floor(Date.now() / 1000)) {
  if (!finite(epoch)) return "—";
  const date = new Date(epoch * 1000);
  if (!finite(date.getTime())) return "—";
  const parts = Object.fromEntries(new Intl.DateTimeFormat("fr-CA", {
    year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23",
  }).formatToParts(date).map(({ type, value }) => [type, value]));
  const time = `${parts.hour}:${parts.minute}`;
  return timeOnly && date.toDateString() === new Date(now * 1000).toDateString()
    ? time : `${parts.year}-${parts.month}-${parts.day} ${time}`;
}

function resetRows(provider, now) {
  const count = resetCount(provider);
  if (count == null) return ["Resets en banque non disponibles"];
  if (!count) return ["Aucun reset en banque"];
  const expirations = Array.isArray(provider?.banked_resets?.expirations)
    ? provider.banked_resets.expirations.map((item) => item?.expires_at).filter((epoch) => finite(epoch) && epoch > 0 && finite(new Date(epoch * 1000).getTime())).sort((a, b) => a - b)
    : [];
  if (!expirations.length) return ["Dates d’expiration non fournies"];
  return expirations.map((epoch, index) => `#${index + 1}   ${dateText(epoch)}   ·   ${epoch > now ? `Dans ${countdown(epoch, now)}` : "Expiré"}`);
}

function roundRect(ctx, [x, y, width, height], radius, color) {
  if (width <= 0 || height <= 0) return;
  ctx.fillStyle = color;
  ctx.beginPath();
  ctx.roundRect(x, y, width, height, Math.min(radius, width / 2, height / 2));
  ctx.fill();
}

function clipped(ctx, [x, y, width, height], draw) {
  ctx.save();
  ctx.beginPath();
  ctx.rect(x, y, Math.max(0, width), Math.max(0, height));
  ctx.clip();
  draw();
  ctx.restore();
}

function text(ctx, value, rect, size, color, { align = "left", weight = 500, mono = false } = {}) {
  clipped(ctx, rect, () => {
    ctx.fillStyle = color;
    ctx.font = `${weight} ${size}px ${mono ? MONO_FONT : SYSTEM_FONT}`;
    ctx.textBaseline = "top";
    ctx.textAlign = align;
    const [x, y, width] = rect;
    ctx.fillText(String(value), align === "right" ? x + width : align === "center" ? x + width / 2 : x, y);
  });
}

function pixelText(ctx, value, rect, scale = 1, color = C.text, align = "left") {
  const characters = Array.from(value === "—%" ? "--" : String(value));
  const width = Math.max(0, characters.length * 6 - 1) * scale;
  const startX = align === "right" ? rect[0] + rect[2] - width : align === "center" ? rect[0] + (rect[2] - width) / 2 : rect[0];
  clipped(ctx, rect, () => {
    ctx.fillStyle = color;
    characters.forEach((character, index) => {
      (GLYPHS[character] || GLYPHS["?"]).forEach((bits, column) => {
        for (let row = 0; row < 8; row++) {
          if (bits & (1 << row)) ctx.fillRect(startX + (index * 6 + column) * scale, rect[1] + row * scale, scale, scale);
        }
      });
    });
  });
}

function circle(ctx, x, y, radius, color) {
  ctx.fillStyle = color;
  ctx.beginPath();
  ctx.arc(x, y, radius, 0, Math.PI * 2);
  ctx.fill();
}

function providerIcon(ctx, codex, left, top, frame, accent) {
  const x = left + 16, y = top + 13, bob = frame & 1;
  ctx.fillStyle = accent;
  if (codex) {
    const radius = 4 + bob;
    for (const [dx, dy] of [[0, -6], [5, -3], [5, 3], [0, 6], [-5, 3], [-5, -3]]) circle(ctx, x + dx, y + dy, radius, accent);
    circle(ctx, x, y, radius + 1, accent);
    ctx.strokeStyle = C.screen;
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(x - 5, y - 4);
    ctx.lineTo(x - 2, y);
    ctx.lineTo(x - 5, y + 4);
    ctx.stroke();
    ctx.fillStyle = C.screen;
    ctx.fillRect(x + 1, y + 4, 6, 1);
  } else {
    const bodyTop = y - 8 - bob;
    ctx.fillRect(x - 10, bodyTop, 20, 13);
    ctx.fillRect(x - 15, bodyTop + 5, 5, 5);
    ctx.fillRect(x + 10, bodyTop + 5, 5, 5);
    for (const [dx, height] of [[-9, 6 - bob], [-4, 5 + bob], [3, 5 + bob], [8, 6 - bob]]) ctx.fillRect(x + dx, bodyTop + 13, 3, height);
    ctx.fillStyle = C.screen;
    ctx.fillRect(x - 6, bodyTop + 3, 3, 3);
    ctx.fillRect(x + 4, bodyTop + 3, 3, 3);
  }
}

function bar(ctx, rect, percent, accent) {
  roundRect(ctx, rect, rect[3] / 2, C.track);
  if (percent > 0) roundRect(ctx, [rect[0], rect[1], rect[2] * percent / 100, rect[3]], rect[3] / 2, percent > 50 ? accent : quotaColor(percent));
}

function quotaCell(ctx, label, window, [x, y, width, height], accent, duration, segments, now) {
  const percent = remaining(window);
  roundRect(ctx, [x, y, width, height], 8, C.cell);
  text(ctx, label, [x + 8, y + 5, width - 16, 11], 7.5, C.muted, { weight: 700 });
  pixelText(ctx, remainingText(window), [x + 8, y + 19, width - 16, 25], 3, quotaColor(percent));
  text(ctx, percent == null ? "NON FOURNI" : "LIBRE", [x + 8, y + 42, width - 16, 10], 7, C.muted, { align: "right", weight: 600 });
  bar(ctx, [x + 8, y + 55, width - 16, 6], percent, accent);
  const segmentWidth = (width - 16 - (segments - 1) * 2) / segments;
  const filled = finite(window?.resets_at) ? clamp((window.resets_at - now) / duration, 0, 1) * segments : 0;
  for (let index = 0; index < segments; index++) {
    const segment = [x + 8 + index * (segmentWidth + 2), y + 65, segmentWidth, 4];
    roundRect(ctx, segment, 2, C.track);
    const fraction = clamp(filled - index, 0, 1);
    if (fraction > 0) {
      ctx.save();
      ctx.globalAlpha = 0.72;
      roundRect(ctx, [segment[0], segment[1], segmentWidth * fraction, 4], 2, accent);
      ctx.restore();
    }
  }
  text(ctx, `RESET ${countdown(window?.resets_at, now)}`, [x + 8, y + 73, width - 16, 14], 10.5, C.muted, { mono: true });
}

function providerCard(ctx, key, provider, [x, y, width, height], now, frame) {
  const codex = key === "codex", accent = C[key], title = key.toUpperCase();
  roundRect(ctx, [x, y, width, height], 10, C[`${key}Panel`]);
  roundRect(ctx, [x, y, width, 4], 2, accent);
  providerIcon(ctx, codex, x + 6, y + 8, frame, accent);
  pixelText(ctx, title, [x + 44, y + 12, title.length * 12, 14], 2);
  const plan = provider?.error_reason === "authentication_required" ? "À CONNECTER" : typeof provider?.plan === "string" ? provider.plan.toUpperCase() : "—";
  ctx.font = `700 9px ${SYSTEM_FONT}`;
  const planX = x + 52 + title.length * 12;
  const planWidth = Math.min(Math.ceil(ctx.measureText(plan).width) + 12, x + width - 26 - planX);
  roundRect(ctx, [planX, y + 11, planWidth, 18], 9, C.cell);
  text(ctx, plan, [planX + 5, y + 14, planWidth - 10, 12], 9, accent, { align: "center", weight: 700 });
  circle(ctx, x + width - 13.5, y + 20.5, 3.5, provider?.status === "ok" ? C.green : provider?.status === "stale" ? C.amber : C.red);
  const cellWidth = (width - 28) / 2;
  quotaCell(ctx, "5 HEURES", provider?.five_hour, [x + 10, y + 38, cellWidth, 90], accent, 5 * 3600, 5, now);
  quotaCell(ctx, "SEMAINE", provider?.weekly, [x + 18 + cellWidth, y + 38, cellWidth, 90], accent, 7 * 86400, 7, now);
  const count = resetCount(provider), bottom = y + 139;
  if (codex) {
    text(ctx, "RESETS:", [x + 10, bottom, 46, 12], 8, C.muted, { weight: 700 });
    text(ctx, count ?? "—", [x + 57, bottom - 1, 18, 13], 8, accent, { mono: true, weight: 700 });
    for (let index = 0; index < Math.min(count ?? 0, 6); index++) roundRect(ctx, [x + 79 + index * 14, bottom + 2, 10, 7], 3.5, accent);
    text(ctx, "Voir les dates ›", [x + width - 112, bottom, 102, 12], 9, accent, { align: "right" });
  } else {
    const compactWidth = width - 100;
    text(ctx, "FABLE:", [x + 10, bottom, 42, 12], 8, C.muted, { weight: 700 });
    bar(ctx, [x + 53, bottom + 2, compactWidth - 93, 7], remaining(provider?.fable_weekly), accent);
    pixelText(ctx, remainingText(provider?.fable_weekly), [x + compactWidth - 38, bottom - 1, 28, 13], 1, quotaColor(remaining(provider?.fable_weekly)), "right");
    text(ctx, `RESETS: ${count ?? "—"} ›`, [x + width - 100, y + 138, 90, 14], 9, accent, { align: "right", mono: true, weight: 700 });
  }
}

function bankedDetail(ctx, key, provider, now, frame, detailOffset) {
  const accent = C[key], x = 16, y = 14, width = 608;
  roundRect(ctx, [x, y, width, 158], 10, C[`${key}Panel`]);
  roundRect(ctx, [x, y, width, 4], 2, accent);
  providerIcon(ctx, key === "codex", x + 6, y + 8, frame, accent);
  pixelText(ctx, "RESETS EN BANQUE", [x + 44, y + 12, 250, 14], 2);
  text(ctx, "Cliquer pour revenir", [x + width - 130, y + 12, 116, 16], 11, accent, { align: "right" });
  pixelText(ctx, resetCount(provider) ?? "—", [x + 24, y + 58, 98, 40], 5, accent, "center");
  text(ctx, "DISPONIBLES", [x + 14, y + 111, 118, 12], 9, C.muted, { align: "center", weight: 700 });
  const rows = resetRows(provider, now), maxOffset = Math.max(0, rows.length - 4);
  const offset = clamp(finite(detailOffset) ? Math.trunc(detailOffset) : 0, 0, maxOffset);
  clipped(ctx, [x + 146, y + 48, width - 158, 100], () => {
    rows.slice(offset, offset + 4).forEach((row, index) => text(ctx, row, [x + 146, y + 48 + index * 25, width - 158, 25], 12, C.text, { mono: true }));
  });
  if (maxOffset) {
    roundRect(ctx, [x + width - 8, y + 48, 3, 100], 1.5, C.track);
    const thumbHeight = 100 * 4 / rows.length;
    roundRect(ctx, [x + width - 8, y + 48 + (100 - thumbHeight) * offset / maxOffset, 3, thumbHeight], 1.5, C.muted);
  }
}

export function drawDashboard(canvas, snapshot, { online = true, detail = null, now = Math.floor(Date.now() / 1000), frame = 0, detailOffset = 0 } = {}) {
  const ctx = canvas.getContext("2d");
  if (!ctx) return;
  if (!finite(now)) now = Math.floor(Date.now() / 1000);
  const ratio = finite(globalThis.devicePixelRatio) ? clamp(globalThis.devicePixelRatio, 1, 4) : 1;
  const pixelWidth = Math.round(640 * ratio), pixelHeight = Math.round(250 * ratio);
  if (canvas.width !== pixelWidth) canvas.width = pixelWidth;
  if (canvas.height !== pixelHeight) canvas.height = pixelHeight;
  ctx.setTransform(canvas.width / 640, 0, 0, canvas.height / 250, 0, 0);
  ctx.clearRect(0, 0, 640, 250);
  roundRect(ctx, [8, 6, 624, 238], 12, C.screen);
  const visible = panels(snapshot);
  if (detail === "codex" || detail === "claude") bankedDetail(ctx, detail, snapshot?.providers?.[detail], now, frame, detailOffset);
  else for (const key of ["codex", "claude"]) if (visible[key]) providerCard(ctx, key, snapshot?.providers?.[key], visible[key], now, frame);
  ctx.fillStyle = C.track;
  ctx.fillRect(20, 180, 600, 1);
  pixelText(ctx, `Dernière actualisation : ${dateText(snapshot?.refresh?.completed_at, true, now)}`, [20, 187, 569, 12], 1.5, C.muted, "right");
  ctx.fillStyle = C.track;
  ctx.fillRect(20, 208, 600, 1);
  const statusColor = online ? C.green : C.red;
  circle(ctx, 25.5, 226.5, 3.5, statusColor);
  const status = `  -  ${online ? "En ligne" : "Hors ligne"}`;
  const rawAddress = typeof snapshot?.api?.address === "string" ? snapshot.api.address : "port 8788";
  const address = `[${rawAddress}]`, maxLength = Math.max(3, Math.floor((640 - 118 - status.length * 12) / 9));
  const endpoint = address.length > maxLength ? `${address.slice(0, maxLength - 3)}...` : address;
  let apiX = 36;
  for (const [value, scale, color] of [["API  ", 2, C.muted], [endpoint, 1.5, C.muted], [status, 2, statusColor]]) {
    ctx.save();
    if (scale < 2) ctx.globalAlpha = 0.72;
    pixelText(ctx, value, [apiX, 219 + (scale < 2 ? 2 : 0), 640 - apiX - 22, 16], scale, color);
    ctx.restore();
    apiX += value.length * 6 * scale;
  }
  ctx.strokeStyle = C.muted;
  ctx.lineWidth = 1.5;
  ctx.beginPath();
  ctx.arc(607, 193, 5.5, -Math.PI * 0.65, Math.PI * 0.9);
  ctx.stroke();
  ctx.fillStyle = C.muted;
  ctx.beginPath();
  ctx.moveTo(612, 186.5);
  ctx.lineTo(612, 192);
  ctx.lineTo(607, 190);
  ctx.closePath();
  ctx.fill();
}

export function hitTest(x, y, snapshot, detail = null) {
  if (!finite(x) || !finite(y) || x < 0 || x >= 640 || y < 0 || y >= 250) return null;
  if (x >= 597 && x < 617 && y >= 183 && y < 203) return "refresh";
  if (detail === "codex" || detail === "claude") return "back";
  for (const [key, rect] of Object.entries(panels(snapshot))) {
    if (rect && x >= rect[0] && x < rect[0] + rect[2] && y >= rect[1] && y < rect[1] + rect[3]) return key;
  }
  return null;
}

export function dashboardSummary(snapshot, { online = true, detail = null } = {}) {
  if (!snapshot) return `Chargement des quotas. API ${online ? "en ligne" : "hors ligne"}.`;
  const parts = [], visible = panels(snapshot), now = Math.floor(Date.now() / 1000);
  for (const key of ["codex", "claude"]) {
    if (detail ? detail !== key : !visible[key]) continue;
    const provider = snapshot.providers?.[key], name = key === "codex" ? "Codex" : "Claude";
    if (detail) parts.push(`${name}, ${resetCount(provider) ?? "—"} resets en banque. ${resetRows(provider, now).join(". ")}.`);
    else parts.push(`${name}, forfait ${typeof provider?.plan === "string" ? provider.plan : "inconnu"}, 5 heures ${remainingText(provider?.five_hour)}, semaine ${remainingText(provider?.weekly)}${key === "claude" ? `, Fable ${remainingText(provider?.fable_weekly)}` : ""}, ${resetCount(provider) ?? "—"} resets en banque.`);
    if (provider?.error_reason === "authentication_required") parts.push(`${name} : connexion requise sur le Mac source.`);
  }
  const address = typeof snapshot.api?.address === "string" ? snapshot.api.address : "port 8788";
  parts.push(`API ${address}, ${online ? "en ligne" : "hors ligne"}. Dernière actualisation ${dateText(snapshot.refresh?.completed_at, true, now)}.`);
  return parts.join(" ");
}
