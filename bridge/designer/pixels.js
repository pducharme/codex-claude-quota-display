function drawPixels(context, b, accent) {
  const pixels = b.pixels || "0".repeat(256);
  context.fillStyle = accent;
  for (let row = 0; row < 16; row++)
    for (let col = 0; col < 16; col++)
      if (pixels[row * 16 + col] === "1") {
        const x = Math.floor((col * b.w) / 16),
          y = Math.floor((row * b.h) / 16);
        context.fillRect(
          b.x + x,
          b.y + y,
          Math.floor(((col + 1) * b.w) / 16) - x,
          Math.floor(((row + 1) * b.h) / 16) - y,
        );
      }
}
function renderPixelEditor() {
  const b = element(),
    panel = $("pixel-settings");
  panel.hidden = b?.type !== "pixels";
  if (panel.hidden) return;
  b.pixels ||= "0".repeat(256);
  const grid = $("pixel-grid");
  grid.replaceChildren();
  for (let i = 0; i < 256; i++) {
    const cell = button("", () => {
      changed(() => {
        b.pixels =
          b.pixels.slice(0, i) +
          (b.pixels[i] === "1" ? "0" : "1") +
          b.pixels.slice(i + 1);
      });
      $("pixel-grid").children[i].focus();
    });
    cell.setAttribute(
      "aria-label",
      `Pixel, rangée ${Math.floor(i / 16) + 1}, colonne ${(i % 16) + 1}`,
    );
    cell.setAttribute("aria-pressed", b.pixels[i] === "1");
    cell.tabIndex = i === 0 ? 0 : -1;
    cell.onkeydown = (e) => {
      const step = {
        ArrowLeft: -1,
        ArrowRight: 1,
        ArrowUp: -16,
        ArrowDown: 16,
      }[e.key];
      if (step) {
        e.preventDefault();
        grid.children[Math.max(0, Math.min(255, i + step))].focus();
      }
    };
    grid.append(cell);
  }
}
$("pixel-clear").onclick = () =>
  changed(() => {
    element().pixels = "0".repeat(256);
  });
$("pixel-invert").onclick = () =>
  changed(() => {
    element().pixels = Array.from(element().pixels, (c) =>
      c === "1" ? "0" : "1",
    ).join("");
  });
$("pixel-import").onchange = async () => {
  const file = $("pixel-import").files[0],
    target = element();
  if (!file) return;
  if (
    !["image/png", "image/jpeg", "image/webp"].includes(file.type) ||
    file.size > 5 * 1024 * 1024
  ) {
    message("Choisissez une image PNG, JPEG ou WebP de moins de 5 Mo.", true);
    return;
  }
  try {
    const dataURL = await new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(reader.result);
      reader.onerror = reject;
      reader.readAsDataURL(file);
    });
    const image = new Image();
    image.src = dataURL;
    await image.decode();
    if (element() !== target || target.type !== "pixels") return;
    const buffer = document.createElement("canvas");
    buffer.width = 16;
    buffer.height = 16;
    const context = buffer.getContext("2d");
    context.drawImage(image, 0, 0, 16, 16);
    const data = context.getImageData(0, 0, 16, 16).data;
    let pixels = "";
    for (let i = 0; i < data.length; i += 4)
      pixels +=
        data[i + 3] > 127 &&
        0.2126 * data[i] + 0.7152 * data[i + 1] + 0.0722 * data[i + 2] < 160
          ? "1"
          : "0";
    changed(() => {
      target.pixels = pixels;
    });
    message(
      "Image convertie en 16 × 16 pixels. Vous pouvez la retoucher ou inverser les couleurs.",
    );
  } catch (e) {
    message("Cette image ne peut pas être importée.", true);
  } finally {
    $("pixel-import").value = "";
  }
};
