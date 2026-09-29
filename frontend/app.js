"use strict";
const API = "/api"; // el proxy reenvia /api/* a la API (sin el prefijo)
const app = document.querySelector("#app");

/* ---------- utilidades ---------- */
function h(tag, props, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(props || {})) {
    if (v == null || v === false || k === "value") continue;
    if (k === "class") el.className = v;
    else if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
    else el.setAttribute(k, v === true ? "" : v);
  }
  for (const c of kids.flat()) if (c != null && c !== false) el.append(c.nodeType ? c : String(c));
  if (props && props.value !== undefined) el.value = props.value;
  return el;
}
const guardar = (k, v) => { try { localStorage.setItem(k, JSON.stringify(v)); } catch {} };
const leer = (k) => { try { return JSON.parse(localStorage.getItem(k)); } catch { return null; } };
const borrar = (k) => { try { localStorage.removeItem(k); } catch {} };
const dinero = (x) => "$ " + Number(x).toFixed(2);

/* ---------- registro de solicitudes HTTP (panel inferior) ---------- */
const peticiones = [];
function registrar(metodo, ruta, status, cuerpo) {
  peticiones.unshift({ metodo, ruta, status, cuerpo: String(cuerpo).slice(0, 500) });
  peticiones.length = Math.min(peticiones.length, 30);
  document.querySelector("#nlog").textContent = peticiones.length;
  document.querySelector("#logbody").replaceChildren(...peticiones.map((p) =>
    h("div", { class: "req " + (p.status >= 200 && p.status < 300 ? "ok" : "err") },
      h("b", {}, `${p.metodo} ${API}${p.ruta} → ${p.status}`), h("code", {}, p.cuerpo))));
}

async function api(metodo, ruta, { json, form } = {}) {
  const init = { method: metodo, headers: {} };
  if (json) { init.body = JSON.stringify(json); init.headers["Content-Type"] = "application/json"; }
  if (form) init.body = form;
  let res, texto;
  try { res = await fetch(API + ruta, init); texto = await res.text(); }
  catch { registrar(metodo, ruta, 0, "sin respuesta"); throw { status: 0, error: { paso: "red", detalle: "No se pudo contactar con la API" } }; }
  let datos = null;
  try { datos = JSON.parse(texto); } catch {}
  registrar(metodo, ruta, res.status, texto);
  if (!res.ok) throw { status: res.status, producto_id: datos?.producto_id, error: datos?.error || { paso: "http", detalle: texto.slice(0, 200) } };
  return datos;
}
const msgError = (e) => (e.error ? `Error ${e.status || ""} · paso: ${e.error.paso} · ${e.error.detalle}` : String(e));

function errorVista(titulo, e, reintentar) {
  app.replaceChildren(h("div", { class: "estado-box err" }, h("strong", {}, titulo), h("div", {}, msgError(e)),
    reintentar && h("button", { class: "btn", type: "button", onclick: () => reintentar() }, "Reintentar")));
}

/* ---------- vista: catalogo ---------- */
function tarjeta(p, cats) {
  return h("a", { class: "card", href: `#/producto/${p.producto_id}` },
    h("img", { src: `${API}/productos/${p.producto_id}/imagen`, alt: p.nombre, loading: "lazy" }),
    h("div", { class: "card-body" }, h("h3", {}, p.nombre), h("div", { class: "precio" }, dinero(p.precio)),
      h("span", { class: "tag" }, cats[p.categoria_id] || "Sin categoría")));
}

async function vistaCatalogo() {
  app.replaceChildren(h("p", { class: "muted" }, "Cargando catálogo…"));
  try {
    const [prods, cats] = await Promise.all([api("GET", "/productos"), api("GET", "/categorias")]);
    const nombreCat = Object.fromEntries(cats.map((c) => [c.categoria_id, c.nombre]));
    app.replaceChildren(h("h1", {}, "Catálogo"), h("p", { class: "muted" }, `${prods.length} productos publicados`),
      prods.length ? h("div", { class: "grid" }, prods.map((p) => tarjeta(p, nombreCat))) : h("p", {}, "Aún no hay productos publicados."));
  } catch (e) { errorVista("No se pudo cargar el catálogo", e, vistaCatalogo); }
}

/* ---------- vista: detalle ---------- */
async function vistaDetalle(id) {
  app.replaceChildren(h("p", { class: "muted" }, "Cargando producto…"));
  try {
    const [p, cats] = await Promise.all([api("GET", `/productos/${encodeURIComponent(id)}`), api("GET", "/categorias")]);
    const cat = (cats.find((c) => c.categoria_id === p.categoria_id) || {}).nombre || "Sin categoría";
    const attrs = Object.entries(p.atributos || {});
    app.replaceChildren(
      h("a", { href: "#/" }, "← Volver al catálogo"),
      h("div", { class: "detalle" },
        p.miniatura ? h("img", { src: `${API}/productos/${p.producto_id}/imagen`, alt: p.nombre }) : h("div", { class: "sinfoto" }, "Sin imagen (registro incompleto)"),
        h("div", {},
          h("h1", {}, p.nombre),
          h("span", { class: "estado " + String(p.estado).toLowerCase() }, p.estado),
          h("div", { class: "precio grande" }, dinero(p.precio)),
          h("span", { class: "tag" }, cat),
          h("p", {}, p.descripcion),
          h("h2", {}, "Atributos"),
          attrs.length ? h("table", {}, attrs.map(([k, v]) => h("tr", {}, h("th", {}, k), h("td", {}, typeof v === "object" ? JSON.stringify(v) : String(v)))))
                       : h("p", { class: "muted" }, "Sin atributos."),
          h("dl", { class: "meta" }, h("dt", {}, "producto_id"), h("dd", {}, p.producto_id), h("dt", {}, "Código"), h("dd", {}, p.codigo),
            h("dt", {}, "Registrado"), h("dd", {}, String(p.fecha).replace("T", " ").slice(0, 19))))));
  } catch (e) { errorVista(e.status === 404 ? "El producto no existe" : "No se pudo cargar el producto", e, () => vistaDetalle(id)); }
}

/* ---------- vista: registrar producto ---------- */
async function vistaNuevo() {
  app.replaceChildren(h("p", { class: "muted" }, "Cargando formulario…"));
  let cats;
  try { cats = await api("GET", "/categorias"); }
  catch (e) { return errorVista("No se pudieron cargar las categorías", e, vistaNuevo); }

  // Borrador y producto pendiente sobreviven a F5 (localStorage). La foto no se puede guardar: hay que elegirla de nuevo.
  const b = leer("lomax:borrador") || { codigo: "", nombre: "", descripcion: "", precio: "", categoria_id: "", attrs: [{ k: "", v: "" }] };
  let pendiente = leer("lomax:pendiente");
  const campos = {};
  const filas = h("div", {});
  const estado = h("div", { class: "estado-box", hidden: true, role: "status" });
  const mostrar = (tipo, ...contenido) => { estado.hidden = false; estado.className = "estado-box " + tipo; estado.replaceChildren(...contenido); };

  const leerAttrs = () => [...filas.children].map((f) => ({ k: f.querySelector("[data-k]").value.trim(), v: f.querySelector("[data-v]").value.trim() }));
  const atributos = () => Object.fromEntries(leerAttrs().filter((a) => a.k).map((a) => [a.k, a.v !== "" && !isNaN(a.v) ? Number(a.v) : a.v]));
  function guardarBorrador() {
    if (pendiente) return;
    guardar("lomax:borrador", { codigo: campos.codigo.value, nombre: campos.nombre.value, descripcion: campos.descripcion.value,
      precio: campos.precio.value, categoria_id: sel.value, attrs: leerAttrs() });
  }
  const inp = (id, props) => (campos[id] = h("input", { id, name: id, value: b[id], oninput: guardarBorrador, ...props }));
  const fila = (k = "", v = "") => {
    const f = h("div", { class: "attr" },
      h("input", { placeholder: "atributo (ej. color)", value: k, oninput: guardarBorrador, "data-k": true, maxlength: 40 }),
      h("input", { placeholder: "valor (ej. rojo)", value: v, oninput: guardarBorrador, "data-v": true, maxlength: 120 }),
      h("button", { type: "button", class: "btn sec", title: "Quitar atributo", onclick: () => { f.remove(); guardarBorrador(); } }, "✕"));
    return f;
  };
  b.attrs.forEach((a) => filas.append(fila(a.k, a.v)));

  const sel = h("select", { id: "categoria_id", required: true, onchange: guardarBorrador }, h("option", { value: "" }, "Selecciona…"),
    cats.map((c) => h("option", { value: c.categoria_id }, c.nombre)));
  sel.value = b.categoria_id;
  campos.descripcion = h("textarea", { id: "descripcion", rows: 3, required: true, maxlength: 500, oninput: guardarBorrador, value: b.descripcion });
  const foto = h("input", { type: "file", id: "foto", accept: "image/jpeg,image/png", required: !pendiente });

  const datos = h("fieldset", {},
    h("label", {}, "Código (único)", inp("codigo", { required: true, maxlength: 40, placeholder: "ej. LAP-DEL-021" })),
    h("label", {}, "Nombre", inp("nombre", { required: true, maxlength: 120 })),
    h("label", {}, "Descripción", campos.descripcion),
    h("label", {}, "Precio", inp("precio", { type: "number", min: "0", step: "0.01", required: true })),
    h("label", {}, "Categoría", sel),
    h("div", {}, h("strong", {}, "Atributos variables"), filas,
      h("button", { type: "button", class: "btn sec", onclick: () => filas.append(fila()) }, "+ Añadir atributo")));

  const btnEnviar = h("button", { type: "submit", class: "btn" }, "Registrar producto");
  const btnRe = h("button", { type: "button", class: "btn", onclick: () => subir() }, "Reintentar imagen");
  const btnNuevo = h("button", { type: "button", class: "btn sec", onclick: () => { borrar("lomax:pendiente"); borrar("lomax:borrador"); vistaNuevo(); } }, "Descartar y empezar de nuevo");
  const form = h("form", { novalidate: false }, datos, h("label", { style: "margin-top:14px" }, "Fotografía (JPEG o PNG, máx. 5 MB)", foto),
    h("div", { class: "acciones" }, btnEnviar, btnRe, btnNuevo), estado);

  function aplicarPendiente() {
    datos.disabled = !!pendiente;
    btnEnviar.hidden = !!pendiente; btnRe.hidden = !pendiente; btnNuevo.hidden = !pendiente;
  }

  async function subir() {
    const f = foto.files[0];
    btnEnviar.disabled = btnRe.disabled = true;
    try {
      let r;
      if (f) {
        const fd = new FormData(); fd.append("file", f);
        mostrar("info", "Subiendo imagen y generando miniatura…");
        r = await api("POST", `/productos/${pendiente.producto_id}/imagen`, { form: fd });
      } else {
        mostrar("info", "Reprocesando la imagen ya guardada…");
        r = await api("POST", `/productos/${pendiente.producto_id}/reprocesar`);
      }
      const id = pendiente.producto_id;
      borrar("lomax:pendiente"); borrar("lomax:borrador"); pendiente = null;
      foto.disabled = true; aplicarPendiente(); btnEnviar.hidden = true; datos.disabled = true;
      mostrar("ok", h("strong", {}, `Producto ${r.estado}`), h("div", {}, `producto_id: ${id}`),
        h("div", { class: "acciones" }, h("a", { href: `#/producto/${id}`, class: "btn" }, "Ver detalle"), h("a", { href: "#/", class: "btn sec" }, "Ver catálogo"),
          h("button", { class: "btn sec", type: "button", onclick: () => vistaNuevo() }, "Registrar otro")));
    } catch (e) {
      mostrar("err", h("strong", {}, "La imagen no se pudo procesar. El producto sigue PENDIENTE y no aparece en el catálogo."),
        h("div", {}, msgError(e)), h("div", {}, `producto_id: ${pendiente.producto_id}`),
        h("small", {}, "Elige otra foto (o deja el campo vacío para reprocesar la ya guardada) y pulsa «Reintentar imagen»."));
      aplicarPendiente();
    } finally { btnEnviar.disabled = btnRe.disabled = false; }
  }

  form.addEventListener("submit", async (ev) => {
    ev.preventDefault();
    if (pendiente) return subir();
    btnEnviar.disabled = true;
    mostrar("info", "Registrando producto…");
    const codigo = campos.codigo.value.trim();
    try {
      const r = await api("POST", "/productos", { json: { codigo, nombre: campos.nombre.value.trim(), descripcion: campos.descripcion.value.trim(),
        precio: Number(campos.precio.value), categoria_id: Number(sel.value), atributos: atributos() } });
      pendiente = { producto_id: r.producto_id, codigo };
      guardar("lomax:pendiente", pendiente); borrar("lomax:borrador"); aplicarPendiente();
      mostrar("info", `Registrado como ${r.estado} (producto_id ${r.producto_id}). Subiendo imagen…`);
      await subir();
    } catch (e) {
      if (e.producto_id) { // el registro base existe pero un servicio fallo: queda PENDIENTE
        pendiente = { producto_id: e.producto_id, codigo }; guardar("lomax:pendiente", pendiente); aplicarPendiente();
        mostrar("err", h("strong", {}, "Un servicio falló al completar el registro. El producto quedó PENDIENTE."), h("div", {}, msgError(e)), h("div", {}, `producto_id: ${e.producto_id}`));
      } else {
        mostrar("err", h("strong", {}, "No se pudo registrar el producto. No se creó ningún registro."), h("div", {}, msgError(e)));
      }
    } finally { btnEnviar.disabled = false; }
  });

  aplicarPendiente();
  app.replaceChildren(h("h1", {}, "Registrar producto"), h("p", { class: "muted" }, "El producto se publica cuando la imagen se procesa correctamente."), form);
  if (pendiente) mostrar("info", `Hay un registro pendiente (producto_id ${pendiente.producto_id}, código ${pendiente.codigo}). Selecciona la foto y pulsa «Reintentar imagen».`);
}

/* ---------- enrutador por hash: la vista sobrevive a F5 ---------- */
function render() {
  const [, ruta, id] = location.hash.split("/");
  document.querySelectorAll("nav a").forEach((a) => a.classList.toggle("activo", a.dataset.r === (ruta === "nuevo" ? "nuevo" : "catalogo")));
  window.scrollTo(0, 0);
  if (ruta === "nuevo") return vistaNuevo();
  if (ruta === "producto" && id) return vistaDetalle(decodeURIComponent(id));
  return vistaCatalogo();
}
window.addEventListener("hashchange", render);
render();
