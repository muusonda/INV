const STORAGE_KEY = "inv.web.invoices.v1";

const $ = (id) => document.getElementById(id);
const today = () => new Date().toISOString().slice(0, 10);
const afterDays = (days) => {
  const date = new Date();
  date.setDate(date.getDate() + days);
  return date.toISOString().slice(0, 10);
};
const makeId = () => `${Date.now()}-${Math.random().toString(16).slice(2)}`;
const blankLine = () => ({ description: "", quantity: 1, rate: 0 });

function blankInvoice() {
  return {
    id: makeId(), documentNumber: "", issueDate: today(), dueDate: afterDays(7),
    currency: "ZAR", taxRate: 0, paymentPlan: "Single", paymentTerms: "",
    sender: { name: "", email: "", phone: "", address: "", bankingDetails: "" },
    client: { name: "", email: "", phone: "", address: "", description: "" },
    lines: [blankLine()]
  };
}

let invoice = blankInvoice();
let savedInvoices = readSavedInvoices();

function readSavedInvoices() {
  try {
    const parsed = JSON.parse(localStorage.getItem(STORAGE_KEY) || "[]");
    return Array.isArray(parsed) ? parsed : [];
  } catch { return []; }
}

function setStatus(message) { $("status").textContent = message; }
function money(value) {
  const currency = (invoice.currency || "ZAR").toUpperCase();
  try { return new Intl.NumberFormat(undefined, { style: "currency", currency }).format(value); }
  catch { return `${currency} ${value.toFixed(2)}`; }
}
function escapeHTML(value) {
  return String(value ?? "").replace(/[&<>'"]/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" }[char]));
}
function pathValue(path) {
  return path.split(".").reduce((value, key) => value?.[key], invoice) ?? "";
}
function setPath(path, value) {
  const parts = path.split(".");
  const last = parts.pop();
  const target = parts.reduce((object, key) => object[key], invoice);
  target[last] = value;
}

function bindFields() {
  const fields = {
    "document-number": "documentNumber", "issue-date": "issueDate", "due-date": "dueDate",
    currency: "currency", "tax-rate": "taxRate", "payment-plan": "paymentPlan",
    "payment-terms": "paymentTerms", "sender-name": "sender.name", "sender-email": "sender.email",
    "sender-phone": "sender.phone", "sender-address": "sender.address", "banking-details": "sender.bankingDetails",
    "client-name": "client.name", "client-email": "client.email", "client-phone": "client.phone",
    "client-address": "client.address", "project-description": "client.description"
  };
  Object.entries(fields).forEach(([id, path]) => {
    const element = $(id);
    element.value = pathValue(path);
    element.oninput = () => { setPath(path, element.value); renderPreview(); };
    element.onchange = () => { setPath(path, element.value); renderPreview(); };
  });
}

function renderLines() {
  $("line-items").innerHTML = invoice.lines.map((line, index) => `
    <div class="line-row" data-index="${index}">
      <label>Description<input data-line="description" value="${escapeHTML(line.description)}" placeholder="Service or item"></label>
      <label>Qty<input data-line="quantity" type="number" min="0" step="0.01" value="${line.quantity}"></label>
      <label>Rate<input data-line="rate" type="number" min="0" step="0.01" value="${line.rate}"></label>
      <label>Total<input value="${escapeHTML(money(line.quantity * line.rate))}" disabled></label>
      <button type="button" data-remove-line="${index}" aria-label="Remove line">×</button>
    </div>`).join("");
  document.querySelectorAll("[data-line]").forEach((field) => field.addEventListener("input", (event) => {
    const row = event.target.closest(".line-row");
    const index = Number(row.dataset.index);
    const key = event.target.dataset.line;
    invoice.lines[index][key] = key === "description" ? event.target.value : Number(event.target.value) || 0;
    renderLines(); renderPreview();
  }));
  document.querySelectorAll("[data-remove-line]").forEach((button) => button.addEventListener("click", () => {
    if (invoice.lines.length > 1) invoice.lines.splice(Number(button.dataset.removeLine), 1);
    renderLines(); renderPreview();
  }));
}

function totals(draft) {
  const subtotal = draft.lines.reduce((sum, line) => sum + (Number(line.quantity) || 0) * (Number(line.rate) || 0), 0);
  const tax = subtotal * (Number(draft.taxRate) || 0) / 100;
  return { subtotal, tax, total: subtotal + tax };
}

function stages(draft) {
  if (draft.paymentPlan !== "50/50") return [{ label: "Invoice", fraction: 1, due: draft.dueDate, isDeposit: false }];
  return [
    { label: "Invoice 1 of 2 — 50% deposit", fraction: .5, due: draft.dueDate, isDeposit: true },
    { label: "Invoice 2 of 2 — final 50% balance", fraction: .5, due: draft.dueDate, isDeposit: false }
  ];
}

function invoicePage(draft, stage) {
  const total = totals(draft);
  const amount = total.total * stage.fraction;
  const paymentTerms = [
    stage.label,
    draft.paymentTerms.trim(),
    draft.paymentPlan === "50/50" ? (stage.isDeposit ? "Payment is due before work begins." : "Payment is due on final delivery.") : ""
  ].filter(Boolean).join("\n");
  const rows = draft.lines.map((line) => `<tr><td>${escapeHTML(line.description || "Item")}</td><td>${line.quantity}</td><td>${escapeHTML(money(line.rate))}</td><td>${escapeHTML(money(line.quantity * line.rate * stage.fraction))}</td></tr>`).join("");
  return `<article class="invoice-page">
    <div class="invoice-top"><div><h3>INVOICE</h3><strong>${escapeHTML(draft.sender.name || "Your name or business")}</strong></div>
      <div class="invoice-meta"><p><strong>${escapeHTML(draft.documentNumber || "Draft")}</strong></p><p>Issued ${escapeHTML(draft.issueDate || "")}</p><p>Due ${escapeHTML(stage.due || "")}</p></div></div>
    <div class="invoice-columns"><div><h4>From</h4><p>${escapeHTML(draft.sender.name)}${draft.sender.address ? `\n${escapeHTML(draft.sender.address)}` : ""}${draft.sender.email ? `\n${escapeHTML(draft.sender.email)}` : ""}${draft.sender.phone ? `\n${escapeHTML(draft.sender.phone)}` : ""}</p></div>
      <div><h4>Bill to</h4><p>${escapeHTML(draft.client.name)}${draft.client.address ? `\n${escapeHTML(draft.client.address)}` : ""}${draft.client.email ? `\n${escapeHTML(draft.client.email)}` : ""}${draft.client.phone ? `\n${escapeHTML(draft.client.phone)}` : ""}</p></div></div>
    ${draft.client.description ? `<div class="invoice-section"><h4>Project</h4><p>${escapeHTML(draft.client.description)}</p></div>` : ""}
    <table class="invoice-table"><thead><tr><th>Description</th><th>Qty</th><th>Rate</th><th>Total</th></tr></thead><tbody>${rows}</tbody></table>
    <div class="invoice-total"><span>Total due</span><span>${escapeHTML(money(amount))}</span></div>
    <div class="invoice-section"><h4>Payment terms</h4><p>${escapeHTML(paymentTerms || "Add payment terms")}</p></div>
    ${draft.sender.bankingDetails ? `<div class="invoice-section"><h4>Payment details</h4><p>${escapeHTML(draft.sender.bankingDetails)}</p></div>` : ""}
  </article>`;
}

function renderPreview() { $("invoice-preview").innerHTML = stages(invoice).map((stage) => invoicePage(invoice, stage)).join(""); }

function renderSavedInvoices() {
  const container = $("saved-invoices");
  if (!savedInvoices.length) { container.innerHTML = '<p class="muted">No saved invoices yet.</p>'; return; }
  container.innerHTML = savedInvoices.slice().reverse().map((saved) => `<div class="saved-invoice"><div><strong>${escapeHTML(saved.documentNumber || "Draft")}</strong><span class="muted">${escapeHTML(saved.client.name || "No client")} · ${escapeHTML(saved.issueDate || "")}</span></div><div class="saved-actions"><button class="small" data-load="${saved.id}">Edit</button><button class="small" data-delete="${saved.id}">Delete</button></div></div>`).join("");
  document.querySelectorAll("[data-load]").forEach((button) => button.addEventListener("click", () => loadInvoice(button.dataset.load)));
  document.querySelectorAll("[data-delete]").forEach((button) => button.addEventListener("click", () => deleteInvoice(button.dataset.delete)));
}

function saveInvoice() {
  const copy = JSON.parse(JSON.stringify(invoice));
  const index = savedInvoices.findIndex((saved) => saved.id === copy.id);
  if (index >= 0) savedInvoices[index] = copy; else savedInvoices.push(copy);
  localStorage.setItem(STORAGE_KEY, JSON.stringify(savedInvoices));
  $("saved-label").textContent = "Saved just now";
  setStatus("Invoice saved in this browser."); renderSavedInvoices();
}
function loadInvoice(id) {
  const found = savedInvoices.find((saved) => saved.id === id);
  if (!found) return;
  invoice = JSON.parse(JSON.stringify(found)); bindFields(); renderLines(); renderPreview(); setStatus("Invoice loaded and editable.");
}
function deleteInvoice(id) {
  savedInvoices = savedInvoices.filter((saved) => saved.id !== id);
  localStorage.setItem(STORAGE_KEY, JSON.stringify(savedInvoices)); renderSavedInvoices(); setStatus("Saved invoice deleted.");
}

function importText(text) {
  try {
    const parsed = JSON.parse(text);
    invoice = { ...blankInvoice(), ...parsed, sender: { ...blankInvoice().sender, ...(parsed.sender || {}) }, client: { ...blankInvoice().client, ...(parsed.client || {}) }, lines: parsed.lines?.length ? parsed.lines : [blankLine()] };
    bindFields(); renderLines(); renderPreview(); setStatus("Invoice imported and editable."); return;
  } catch { /* Try a simple labelled text invoice below. */ }
  const next = blankInvoice();
  const pick = (label) => text.match(new RegExp(`^\\s*${label}\\s*:\\s*(.+)$`, "im"))?.[1]?.trim() || "";
  next.documentNumber = pick("(?:invoice|document)\\s*(?:number|no\\.)?") || next.documentNumber;
  next.client.name = pick("client(?: name)?") || next.client.name;
  next.client.address = pick("client address") || next.client.address;
  next.sender.name = pick("sender(?: name)?") || next.sender.name;
  next.paymentTerms = pick("payment terms") || next.paymentTerms;
  invoice = next; bindFields(); renderLines(); renderPreview(); setStatus("Text invoice imported. Check each field before saving.");
}

$("new-invoice").onclick = () => { invoice = blankInvoice(); bindFields(); renderLines(); renderPreview(); setStatus("New invoice ready."); };
$("save-invoice").onclick = saveInvoice;
$("export-invoice").onclick = () => { setStatus("Use the print dialog to choose Save as PDF."); window.print(); };
$("add-line").onclick = () => { invoice.lines.push(blankLine()); renderLines(); renderPreview(); };
$("import-file").onchange = async (event) => { const file = event.target.files[0]; if (!file) return; importText(await file.text()); event.target.value = ""; };

bindFields(); renderLines(); renderPreview(); renderSavedInvoices();
