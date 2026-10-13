const STORAGE_KEY = "inv.web.invoices.v1";
const PROFILE_KEY = "inv.web.setup.profile.v1";
const LEGACY_PROFILE_KEY = "inv.web.books.profile.v1";
const TESSERACT_URL = "https://cdn.jsdelivr.net/npm/tesseract.js@5.1.1/dist/tesseract.min.js";
const PDFJS_URL = "https://cdnjs.cloudflare.com/ajax/libs/pdf.js/4.10.38/pdf.min.mjs";
const PDFJS_WORKER_URL = "https://cdnjs.cloudflare.com/ajax/libs/pdf.js/4.10.38/pdf.worker.min.mjs";
const MAX_OCR_PAGES = 12;

let tesseractPromise = null;
let pdfjsPromise = null;
const PDF_JS_WORKER = "https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.worker.min.js";
const TESSERACT_WORKER = "https://cdn.jsdelivr.net/npm/tesseract.js@5.1.1/dist/worker.min.js";
const TESSERACT_CORE = "https://cdn.jsdelivr.net/npm/tesseract.js-core@5.1.0";
const TESSDATA = "https://tessdata.projectnaptha.com/4.0.0";

const $ = (id) => document.getElementById(id);
const localDate = (date = new Date()) => {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
};
const today = () => localDate();
const afterDays = (days, from = new Date()) => {
  const date = new Date(from);
  date.setDate(date.getDate() + days);
  return localDate(date);
};
const makeId = () => `${Date.now()}-${Math.random().toString(16).slice(2)}`;
const blankLine = () => ({ id: makeId(), itemDescription: "", quantity: 1, rate: 0 });
const emptyPayment = () => ({ id: makeId(), date: today(), amount: 0, type: "Payment", method: "Bank transfer", reference: "", notes: "" });

function blankInvoice() {
  return {
    id: makeId(), documentType: "INVOICE", documentNumber: "", status: "Draft",
    issueDate: today(), dueDate: afterDays(7), dueDateMode: "Specific date",
    finalDueDate: afterDays(21), finalDueDateMode: "On delivery", paymentPlan: "Single", paymentStage: "",
    senderName: "", senderAddress: "", senderVatNumber: "", clientName: "", clientContact: "", clientAddress: "",
    projectName: "", projectDescription: "", lines: [blankLine()], currency: "ZAR", taxRate: 0,
    paymentTerms: "", bankingDetails: "", amountPaid: 0, payments: []
  };
}

function normalizeInvoice(raw = {}) {
  const base = blankInvoice();
  const sender = raw.sender || {};
  const client = raw.client || {};
  const lines = Array.isArray(raw.lines) && raw.lines.length ? raw.lines : [blankLine()];
  const payments = Array.isArray(raw.payments) ? raw.payments : [];
  const normalized = {
    ...base, ...raw,
    id: raw.id || base.id,
    documentType: raw.documentType || "INVOICE",
    status: raw.status || "Draft",
    senderName: raw.senderName ?? sender.name ?? "",
    senderAddress: raw.senderAddress ?? sender.address ?? [sender.email, sender.phone].filter(Boolean).join("\n"),
    senderVatNumber: String(raw.senderVatNumber ?? sender.vatNumber ?? ""),
    clientName: raw.clientName ?? client.name ?? "",
    clientContact: raw.clientContact ?? client.contact ?? "",
    clientAddress: raw.clientAddress ?? client.address ?? [client.email, client.phone].filter(Boolean).join("\n"),
    projectName: raw.projectName ?? "",
    projectDescription: raw.projectDescription ?? client.description ?? "",
    bankingDetails: raw.bankingDetails ?? sender.bankingDetails ?? "",
    currency: String(raw.currency || "ZAR").toUpperCase(),
    taxRate: Number(raw.taxRate) || 0,
    amountPaid: Number(raw.amountPaid) || payments.reduce((sum, payment) => sum + (Number(payment.amount) || 0), 0),
    payments,
    lines: lines.map((line) => ({
      id: line.id || makeId(),
      itemDescription: line.itemDescription ?? line.description ?? "",
      quantity: Number(line.quantity) || 0,
      rate: Number(line.rate) || 0
    }))
  };
  if (!normalized.issueDate) normalized.issueDate = today();
  if (!normalized.dueDate) normalized.dueDate = afterDays(7);
  if (!normalized.finalDueDate) normalized.finalDueDate = afterDays(21);
  return normalized;
}

function readSavedInvoices() {
  try {
    const parsed = JSON.parse(localStorage.getItem(STORAGE_KEY) || "[]");
    return Array.isArray(parsed) ? parsed.map(normalizeInvoice) : [];
  } catch { return []; }
}

function readProfile() {
  try {
    const saved = localStorage.getItem(PROFILE_KEY) || localStorage.getItem(LEGACY_PROFILE_KEY) || "{}";
    return { legalName: "", vatNumber: "", address: "", ...JSON.parse(saved) };
  }
  catch { return { legalName: "", vatNumber: "", address: "" }; }
}

let invoice = normalizeInvoice();
let savedInvoices = readSavedInvoices();
let setupProfile = readProfile();
let hasUnsavedChanges = false;
let autosaveTimer = null;
let importGeneration = 0;

const FIELD_PATHS = {
  "document-number": "documentNumber", "issue-date": "issueDate", "due-date": "dueDate",
  "due-date-mode": "dueDateMode", "final-due-date": "finalDueDate", "final-due-date-mode": "finalDueDateMode",
  "payment-plan": "paymentPlan", "payment-stage": "paymentStage", currency: "currency", "tax-rate": "taxRate",
  "sender-name": "senderName", "sender-address": "senderAddress", "sender-vat-number": "senderVatNumber", "client-name": "clientName",
  "client-contact": "clientContact", "client-address": "clientAddress", "project-name": "projectName",
  "project-description": "projectDescription", "payment-terms": "paymentTerms", "banking-details": "bankingDetails"
};

function setStatus(message) {
  $("status").textContent = message;
}

function setPath(path, value) {
  const keys = path.split(".");
  const last = keys.pop();
  const target = keys.reduce((object, key) => object[key], invoice);
  target[last] = value;
}

function money(value, currency = invoice.currency) {
  const code = String(currency || "ZAR").toUpperCase();
  try {
    const formatter = new Intl.NumberFormat(undefined, { style: "currency", currency: code, minimumFractionDigits: 2, maximumFractionDigits: 2 });
    return formatter.format(Number(value) || 0).replace(/^ZAR\s?/, "R");
  } catch { return `${code} ${(Number(value) || 0).toFixed(2)}`; }
}

function escapeHTML(value) {
  return String(value ?? "").replace(/[&<>'"]/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" }[char]));
}

function multiline(value) {
  return escapeHTML(value || "").replace(/\n/g, "<br>");
}

function totals(draft = invoice) {
  const subtotal = draft.lines.reduce((sum, line) => sum + (Number(line.quantity) || 0) * (Number(line.rate) || 0), 0);
  const tax = subtotal * (Number(draft.taxRate) || 0) / 100;
  return { subtotal, tax, total: subtotal + tax };
}

function stages(draft = invoice) {
  if (draft.paymentPlan !== "50/50") return [{ label: "Invoice", fraction: 1, due: draft.dueDate, dueMode: draft.dueDateMode, isDeposit: false }];
  return [
    { label: "Invoice 1 of 2 — 50% deposit", fraction: .5, due: draft.dueDate, dueMode: draft.dueDateMode, isDeposit: true },
    { label: "Invoice 2 of 2 — final 50% balance", fraction: .5, due: draft.finalDueDate, dueMode: draft.finalDueDateMode, isDeposit: false }
  ];
}

function dueText(stage) {
  if (stage.dueMode === "At project start") return "At project start";
  if (stage.dueMode === "On delivery") return "On delivery";
  return stage.due || "";
}

function currentTitle(draft = invoice) {
  if (draft.documentType === "QUOTE") return "QUOTE";
  if (String(draft.senderVatNumber || "").trim()) return "TAX INVOICE";
  return "INVOICE";
}

function syncFields() {
  Object.entries(FIELD_PATHS).forEach(([id, path]) => {
    const element = $(id);
    if (!element) return;
    element.value = invoice[path] ?? "";
  });
}

function bindFields() {
  Object.entries(FIELD_PATHS).forEach(([id, path]) => {
    const element = $(id);
    if (!element || element.dataset.bound === "true") return;
    element.dataset.bound = "true";
    const update = () => {
      const numeric = id === "tax-rate";
      setPath(path, numeric ? Number(element.value) || 0 : element.value);
      markDirty();
      updateDerived();
    };
    element.addEventListener("input", update);
    element.addEventListener("change", update);
  });
}

function markDirty() {
  hasUnsavedChanges = true;
  $("status-icon").classList.add("unsaved");
  $("unsaved-label").textContent = invoice.status === "Draft" ? "Unsaved changes · autosaving…" : "Unsaved issued changes · press Save";
  clearTimeout(autosaveTimer);
  autosaveTimer = setTimeout(() => persistInvoice(true), 1200);
}

function persistInvoice(silent = false) {
  clearTimeout(autosaveTimer);
  const copy = normalizeInvoice(JSON.parse(JSON.stringify(invoice)));
  const index = savedInvoices.findIndex((saved) => saved.id === copy.id);
  if (index >= 0) savedInvoices[index] = copy; else savedInvoices.push(copy);
  try { localStorage.setItem(STORAGE_KEY, JSON.stringify(savedInvoices)); } catch { setStatus("This browser could not save the invoice."); return; }
  hasUnsavedChanges = false;
  $("status-icon").classList.remove("unsaved");
  $("unsaved-label").textContent = "";
  $("save-invoice").innerHTML = `<span>⇩</span><span>${invoice.status === "Draft" ? "Save" : "Save Changes"}</span>`;
  if (!silent) { $("saved-label")?.remove(); setStatus("Saved in this browser"); }
  renderDocuments();
  renderClientList();
}

function saveInvoice() {
  persistInvoice(false);
}

function renderLines() {
  const container = $("line-items");
  container.innerHTML = invoice.lines.map((line, index) => `
    <div class="line-row" data-index="${index}">
      <input class="paper-input line-description" data-line="itemDescription" value="${escapeHTML(line.itemDescription)}" placeholder="Description" aria-label="Description">
      <input class="paper-input line-number" data-line="quantity" type="number" min="0" step="0.01" value="${line.quantity}" aria-label="Quantity">
      <input class="paper-input line-number" data-line="rate" type="number" min="0" step="0.01" value="${line.rate}" aria-label="Rate">
      <span class="line-amount">${escapeHTML(money(line.quantity * line.rate))}</span>
      <button type="button" class="remove-line" data-remove-line="${index}" aria-label="Remove line">×</button>
    </div>`).join("");
  container.querySelectorAll("[data-line]").forEach((field) => field.addEventListener("input", (event) => {
    const row = event.target.closest(".line-row");
    const index = Number(row.dataset.index);
    const key = event.target.dataset.line;
    invoice.lines[index][key] = key === "itemDescription" ? event.target.value : Number(event.target.value) || 0;
    row.querySelector(".line-amount").textContent = money(invoice.lines[index].quantity * invoice.lines[index].rate);
    markDirty();
    updateDerived();
  }));
  container.querySelectorAll("[data-remove-line]").forEach((button) => button.addEventListener("click", () => {
    if (invoice.lines.length > 1) invoice.lines.splice(Number(button.dataset.removeLine), 1);
    markDirty(); renderLines(); updateDerived();
  }));
}

function updateDerived() {
  const result = totals(invoice);
  $("subtotal-value").textContent = money(result.subtotal);
  $("tax-value").textContent = Number(invoice.taxRate) > 0 ? money(result.tax) : "N/A";
  $("total-value").textContent = money(result.total);
  const paid = Number(invoice.amountPaid) || 0;
  $("paid-row").classList.toggle("hidden", paid <= 0);
  $("balance-row").classList.toggle("hidden", paid <= 0);
  $("paid-value").textContent = money(paid);
  $("balance-value").textContent = money(Math.max(result.total - paid, 0));
  $("document-status").textContent = (invoice.status || "Draft").toUpperCase();
  $("toolbar-status").textContent = invoice.status || "Draft";
  $("toolbar-type").textContent = invoice.documentType === "QUOTE" ? "Quote" : "Invoice";
  $("document-title").textContent = currentTitle();
  $("terms-heading").textContent = invoice.documentType === "QUOTE" ? "QUOTE TERMS & ACCEPTANCE" : "PAYMENT TERMS";
  $("invoice-document").classList.toggle("quote", invoice.documentType === "QUOTE");
  $("invoice-document").classList.toggle("is-half", invoice.paymentPlan === "50/50");
  $("payment-reference").textContent = invoice.documentNumber || "ASSIGNED ON ISSUE";
  $("issue-invoice").disabled = invoice.status !== "Draft";
  $("payment-button").disabled = invoice.status === "Draft" || paid + 0.005 >= result.total;
  $("save-invoice").innerHTML = `<span>⇩</span><span>${invoice.status === "Draft" ? "Save" : "Save Changes"}</span>`;
  renderExportPages();
}

function renderClientList() {
  const names = [...new Set(savedInvoices.map((saved) => saved.clientName).filter(Boolean))];
  $("saved-clients").innerHTML = names.map((name) => `<option value="${escapeHTML(name)}"></option>`).join("");
}

function exportPage(draft, stage) {
  const result = totals(draft);
  const amount = result.total * stage.fraction;
  const terms = [
    stage.label,
    draft.paymentTerms.trim(),
    draft.paymentPlan === "50/50" ? (stage.isDeposit ? "Payment is due before work begins." : "Payment is due on final delivery.") : ""
  ].filter(Boolean).join("\n");
  const rows = draft.lines.map((line) => `<tr><td>${escapeHTML(line.itemDescription || "Item")}</td><td>${escapeHTML(line.quantity)}</td><td>${escapeHTML(money(line.rate, draft.currency))}</td><td>${escapeHTML(money(line.quantity * line.rate * stage.fraction, draft.currency))}</td></tr>`).join("");
  return `<article class="export-page">
    <section class="document-heading"><div class="heading-meta"><span class="paper-label">STATUS</span><span class="paper-status">${escapeHTML(draft.status.toUpperCase())}</span><span class="paper-label">DOCUMENT NUMBER</span><span class="paper-input small-input">${escapeHTML(draft.documentNumber || "")}</span></div><h1>${escapeHTML(currentTitle(draft))}</h1></section>
    <section class="schedule-row"><div class="paper-field"><span class="paper-label">ISSUE DATE</span><span class="paper-input">${escapeHTML(draft.issueDate)}</span></div><div class="paper-field"><span class="paper-label">PAYMENT SCHEDULE</span><span class="paper-input">${escapeHTML(draft.paymentPlan)} · ${escapeHTML(dueText(stage))}</span></div><div class="paper-field"><span class="paper-label">PAYMENT STAGE</span><span class="paper-input">${escapeHTML(draft.paymentStage || stage.label)}</span></div><div class="paper-field"><span class="paper-label">CURRENCY</span><span class="paper-input">${escapeHTML(draft.currency)}</span></div></section>
    <section class="document-section parties-grid"><div class="party-column"><h2 class="section-label">FROM</h2><span class="paper-label">NAME</span><span class="paper-input">${escapeHTML(draft.senderName)}</span><p class="paper-textarea">${multiline(draft.senderAddress)}</p>${draft.senderVatNumber ? `<p class="paper-label">VAT number: ${escapeHTML(draft.senderVatNumber)}</p>` : ""}</div><div class="party-column"><h2 class="section-label">BILL TO</h2><span class="paper-label">CLIENT</span><span class="paper-input">${escapeHTML(draft.clientName)}</span><span class="paper-label">ATTENTION</span><span class="paper-input">${escapeHTML(draft.clientContact)}</span><p class="paper-textarea">${multiline(draft.clientAddress)}</p></div></section>
    <section class="document-section"><h2 class="section-label">PROJECT</h2><span class="paper-label">PROJECT NAME</span><span class="paper-input">${escapeHTML(draft.projectName)}</span><p class="paper-textarea">${multiline(draft.projectDescription)}</p></section>
    <section class="document-section line-items-section"><div class="line-headings"><span>DESCRIPTION</span><span>QTY</span><span>RATE</span><span>AMOUNT</span><span></span></div><div>${rows}</div></section>
    <section class="document-section totals-section"><div></div><div class="totals-list"><div class="amount-row"><span>SUBTOTAL</span><strong>${escapeHTML(money(result.subtotal * stage.fraction, draft.currency))}</strong></div><div class="amount-row"><span>VAT</span><strong>${draft.taxRate > 0 ? escapeHTML(money(result.tax * stage.fraction, draft.currency)) : "N/A"}</strong></div><hr><div class="amount-row total-row"><span>TOTAL</span><strong>${escapeHTML(money(amount, draft.currency))}</strong></div></div></section>
    <section class="document-section terms-section"><div class="section-label">${draft.documentType === "QUOTE" ? "QUOTE TERMS & ACCEPTANCE" : "PAYMENT TERMS"}</div><p class="paper-textarea large-textarea">${multiline(terms || "Add payment terms")}</p><div class="banking-block"><div class="section-label banking-label">BANKING DETAILS</div><p class="paper-textarea">${multiline(draft.bankingDetails)}</p><div class="reference-block"><span class="paper-label">PAYMENT REFERENCE</span><strong>${escapeHTML(draft.documentNumber || "ASSIGNED ON ISSUE")}</strong></div></div></section>
  </article>`;
}

function renderExportPages() {
  const container = $("export-pages");
  if (!container) return;
  container.innerHTML = stages(invoice).map((stage) => exportPage(invoice, stage)).join("");
}

function renderDocument() {
  syncFields();
  renderLines();
  renderClientList();
  updateDerived();
}

function saveNewDocument(type = "INVOICE") {
  if (hasUnsavedChanges) persistInvoice(true);
  clearTimeout(autosaveTimer);
  invoice = blankInvoice();
  applySetupToInvoice();
  invoice.documentType = type;
  hasUnsavedChanges = false;
  $("status-icon").classList.remove("unsaved");
  $("unsaved-label").textContent = "";
  syncFields(); renderLines(); updateDerived();
  setStatus(type === "QUOTE" ? "New quote" : "New invoice");
}

function nextDocumentNumber() {
  const prefix = invoice.documentType === "QUOTE" ? "QUO" : "INV";
  const existing = savedInvoices.map((saved) => saved.documentNumber).filter(Boolean);
  let count = existing.length + 1;
  let candidate = `${prefix}-${new Date().getFullYear()}-${String(count).padStart(3, "0")}`;
  while (existing.includes(candidate)) { count += 1; candidate = `${prefix}-${new Date().getFullYear()}-${String(count).padStart(3, "0")}`; }
  return candidate;
}

function issueInvoice() {
  if (invoice.documentType === "INVOICE" && invoice.paymentPlan === "50/50") {
    setStatus("50/50 invoices are issued together when you choose Export.");
    return;
  }
  const result = totals(invoice);
  const problems = [];
  if (!invoice.clientName.trim()) problems.push("add a client");
  if (result.total <= 0) problems.push("add a line item with a value");
  if (!/^[A-Z]{3}$/.test(invoice.currency.trim().toUpperCase())) problems.push("use a 3-letter currency");
  if (Number(invoice.taxRate) < 0 || Number(invoice.taxRate) > 100) problems.push("use a VAT rate between 0 and 100");
  if (invoice.dueDateMode === "Specific date" && invoice.dueDate && invoice.issueDate && invoice.dueDate < invoice.issueDate) problems.push("set a due date on or after the issue date");
  invoice.lines.forEach((line, index) => { if (!line.itemDescription.trim()) problems.push(`describe line ${index + 1}`); if (Number(line.quantity) <= 0) problems.push(`set a quantity for line ${index + 1}`); if (Number(line.rate) < 0) problems.push(`set a valid rate for line ${index + 1}`); });
  if (problems.length) { setStatus(`Before issuing, ${problems.join(", ")}.`); return; }
  if (!window.confirm(`Issue this ${invoice.documentType.toLowerCase()}? A permanent number will be assigned.`)) return;
  invoice.documentNumber = invoice.documentNumber.trim() || nextDocumentNumber();
  invoice.status = "Issued";
  markDirty();
  persistInvoice(false);
  updateDerived();
  setStatus("Issued and saved");
}

function loadInvoice(id) {
  if (hasUnsavedChanges) persistInvoice(true);
  clearTimeout(autosaveTimer);
  const found = savedInvoices.find((saved) => saved.id === id);
  if (!found) return;
  invoice = normalizeInvoice(JSON.parse(JSON.stringify(found)));
  hasUnsavedChanges = false;
  closeModal("documents-modal");
  renderDocument();
  setStatus(invoice.status === "Draft" ? "Draft opened and editable" : "Issued invoice opened and editable");
}

function deleteInvoice(id) {
  const found = savedInvoices.find((saved) => saved.id === id);
  if (!found || !window.confirm(`Delete ${found.documentNumber || "this document"}?`)) return;
  savedInvoices = savedInvoices.filter((saved) => saved.id !== id);
  localStorage.setItem(STORAGE_KEY, JSON.stringify(savedInvoices));
  renderDocuments(); renderClientList(); renderSetup(); setStatus("Document deleted");
}

function displayStatus(saved) {
  if ((saved.status === "Issued" || saved.status === "Partially Paid") && saved.dueDate < today() && (Number(saved.amountPaid) || 0) < totals(saved).total) return "Overdue";
  if (saved.status === "Issued" && Number(saved.amountPaid) > 0 && Number(saved.amountPaid) + .005 < totals(saved).total) return "Partially Paid";
  if (saved.status === "Issued" && Number(saved.amountPaid) + .005 >= totals(saved).total) return "Paid";
  return saved.status || "Draft";
}

function renderDocuments() {
  const container = $("documents-list");
  if (!container) return;
  const query = ($("document-search")?.value || "").trim().toLowerCase();
  const filter = $("status-filter")?.value || "All";
  const documents = savedInvoices.slice().reverse().filter((saved) => {
    const searchText = [saved.documentNumber, saved.clientName, saved.projectName, saved.projectDescription, saved.documentType, saved.status].join(" ").toLowerCase();
    return (!query || searchText.includes(query)) && (filter === "All" || displayStatus(saved) === filter);
  });
  if (!documents.length) { container.innerHTML = '<p class="muted">There are no saved documents matching these filters.</p>'; return; }
  container.innerHTML = documents.map((saved) => `<div class="document-list-row"><div class="document-list-main"><strong>${escapeHTML(saved.documentNumber || saved.documentType || "Draft")}</strong><span>${escapeHTML(saved.projectName || saved.clientName || "No client")} · ${escapeHTML(saved.issueDate || "")}</span></div><div class="document-list-side"><div><strong>${escapeHTML(money(totals(saved).total, saved.currency))}</strong><span>${escapeHTML(displayStatus(saved))}</span></div><div class="document-list-actions"><button class="secondary-action" data-load="${escapeHTML(saved.id)}">${saved.status === "Draft" ? "Open" : "Open & Edit"}</button><button class="secondary-action" data-delete="${escapeHTML(saved.id)}">Delete</button></div></div></div>`).join("");
  container.querySelectorAll("[data-load]").forEach((button) => button.addEventListener("click", () => loadInvoice(button.dataset.load)));
  container.querySelectorAll("[data-delete]").forEach((button) => button.addEventListener("click", () => deleteInvoice(button.dataset.delete)));
}

function openModal(id) { $(id).classList.remove("hidden"); }
function closeModal(id) { $(id).classList.add("hidden"); }

function loadTesseract() {
  if (window.Tesseract) return Promise.resolve(window.Tesseract);
  if (tesseractPromise) return tesseractPromise;
  tesseractPromise = new Promise((resolve, reject) => {
    const script = document.createElement("script");
    script.src = TESSERACT_URL;
    script.async = true;
    script.onload = () => window.Tesseract ? resolve(window.Tesseract) : reject(new Error("Tesseract.js did not load."));
    script.onerror = () => reject(new Error("The OCR engine could not be loaded. Check the network connection and try again."));
    document.head.appendChild(script);
  });
  return tesseractPromise;
}

function loadPDFJS() {
  if (window.pdfjsLib) {
    window.pdfjsLib.GlobalWorkerOptions.workerSrc = PDF_JS_WORKER;
    return Promise.resolve(window.pdfjsLib);
  }
  if (pdfjsPromise) return pdfjsPromise;
  pdfjsPromise = import(PDFJS_URL).then((module) => {
    const pdfjs = module.default || module;
    if (pdfjs.GlobalWorkerOptions) pdfjs.GlobalWorkerOptions.workerSrc = PDFJS_WORKER_URL;
    return pdfjs;
  });
  return pdfjsPromise;
}

function ocrLogger(label) {
  return (event) => {
    if (!event || !event.status) return;
    const progress = Number.isFinite(event.progress) ? ` ${Math.round(event.progress * 100)}%` : "";
    setStatus(`Reading ${label}…${progress}`);
  };
}

async function recognizeCanvas(canvas, label, Tesseract) {
  if (typeof Tesseract.createWorker === "function") {
    const worker = await Tesseract.createWorker("eng", 1, {
      workerPath: TESSERACT_WORKER,
      corePath: TESSERACT_CORE,
      langPath: TESSDATA,
      logger: ocrLogger(label)
    });
    try {
      const result = await worker.recognize(canvas);
      return result?.data?.text || "";
    } finally {
      await worker.terminate();
    }
  }
  const result = await Tesseract.recognize(canvas, "eng", {
    workerPath: TESSERACT_WORKER,
    corePath: TESSERACT_CORE,
    langPath: TESSDATA,
    logger: ocrLogger(label)
  });
  return result?.data?.text || "";
}

async function recognizeImage(file) {
  const Tesseract = await loadTesseract();
  return recognizeCanvas(file, file.name, Tesseract);
}

async function recognizePDF(file) {
  const [pdfjs, Tesseract] = await Promise.all([loadPDFJS(), loadTesseract()]);
  const bytes = new Uint8Array(await file.arrayBuffer());
  const pdf = await pdfjs.getDocument({ data: bytes }).promise;
  const pageCount = Math.min(pdf.numPages, MAX_OCR_PAGES);
  const text = [];
  for (let pageNumber = 1; pageNumber <= pageCount; pageNumber += 1) {
    setStatus(`Preparing PDF page ${pageNumber} of ${pageCount} for OCR…`);
    const page = await pdf.getPage(pageNumber);
    const viewport = page.getViewport({ scale: 2 });
    const canvas = document.createElement("canvas");
    canvas.width = Math.ceil(viewport.width);
    canvas.height = Math.ceil(viewport.height);
    await page.render({ canvasContext: canvas.getContext("2d", { willReadFrequently: true }), viewport }).promise;
    text.push(await recognizeCanvas(canvas, `PDF page ${pageNumber} of ${pageCount}`, Tesseract));
  }
  if (pdf.numPages > MAX_OCR_PAGES) text.push(`\n[OCR stopped after ${MAX_OCR_PAGES} pages. Review the remaining pages manually.]`);
  return text.join("\n\n");
}

function numericValue(value) {
  const cleaned = String(value || "").replace(/[^0-9,.-]/g, "").replace(/,(?=\d{3}(?:\D|$))/g, "").replace(/,/g, ".");
  const parsed = Number(cleaned);
  return Number.isFinite(parsed) ? parsed : 0;
}

function dateValue(value) {
  const raw = String(value || "").trim();
  let match = raw.match(/\b(20\d{2})[-/.](\d{1,2})[-/.](\d{1,2})\b/);
  if (match) return `${match[1]}-${String(match[2]).padStart(2, "0")}-${String(match[3]).padStart(2, "0")}`;
  match = raw.match(/\b(\d{1,2})[-/.](\d{1,2})[-/.](20\d{2})\b/);
  if (match) return `${match[3]}-${String(match[2]).padStart(2, "0")}-${String(match[1]).padStart(2, "0")}`;
  return "";
}

function sectionFromOCR(lines, labels, stopLabels) {
  const labelPattern = new RegExp(`^(?:${labels.join("|")})\\s*[:#-]?\\s*(.*)$`, "i");
  const stopPattern = new RegExp(`^(?:${stopLabels.join("|")})\\s*[:#-]?`, "i");
  for (let index = 0; index < lines.length; index += 1) {
    const match = lines[index].match(labelPattern);
    if (!match) continue;
    const values = match[1] ? [match[1].trim()] : [];
    for (let next = index + 1; next < lines.length && values.length < 3; next += 1) {
      if (!lines[next] || stopPattern.test(lines[next])) break;
      values.push(lines[next]);
    }
    return values.join("\n").trim();
  }
  return "";
}

function parseOCRInvoice(text, fileName = "") {
  const lines = String(text || "").split(/\r?\n/).map((line) => line.replace(/\s+/g, " ").trim()).filter(Boolean);
  const joined = lines.join(" ");
  const invoiceNumber = joined.match(/\b(?:invoice|inv(?:oice)?|document)\s*(?:number|no\.?|#)?\s*[:#-]?\s*([A-Z0-9][A-Z0-9/-]{2,})\b/i)?.[1] || "";
  const issueDate = dateValue(joined.match(/(?:issue|invoice|date)\s*(?:date)?\s*[:#-]?\s*([^|,;]+)/i)?.[1] || "") || today();
  const dueDate = dateValue(joined.match(/(?:due|payment due|due date)\s*[:#-]?\s*([^|,;]+)/i)?.[1] || "") || afterDays(7);
  const currency = (joined.match(/\b(ZAR|USD|EUR|GBP|AUD|CAD|CHF|BWP|NAD|KES|NGN|GHS)\b/i)?.[1] || "ZAR").toUpperCase();
  const stopLabels = ["bill to", "billed to", "client", "customer", "from", "seller", "supplier", "project", "description", "subtotal", "total", "vat", "tax", "payment terms", "banking details", "bank details"];
  const senderAddress = sectionFromOCR(lines, ["from", "seller", "supplier"], stopLabels);
  const clientAddress = sectionFromOCR(lines, ["bill to", "billed to", "customer", "client"], stopLabels);
  const clientName = clientAddress.split("\n")[0] || lines.find((line) => /^(?:client|customer)\s*:/i.test(line))?.replace(/^(?:client|customer)\s*:/i, "").trim() || "";
  const projectDescription = sectionFromOCR(lines, ["project", "description", "scope"], stopLabels);
  const paymentTerms = sectionFromOCR(lines, ["payment terms", "terms", "notes"], ["banking details", "bank details", "subtotal", "total"]);
  const bankingDetails = sectionFromOCR(lines, ["banking details", "bank details", "bank"], ["payment terms", "terms", "subtotal", "total"]);
  const taxRate = Number(joined.match(/(?:vat|tax)\s*(?:rate|%)?\s*[:#-]?\s*(\d{1,2}(?:\.\d+)?)\s*%/i)?.[1] || 0);
  const total = numericValue(joined.match(/(?:grand\s+)?total\s*(?:due)?\s*[:#-]?\s*(?:[A-Z]{3}\s*)?([\d,]+(?:\.\d{1,2})?)/i)?.[1] || 0);
  const subtotal = numericValue(joined.match(/subtotal\s*[:#-]?\s*(?:[A-Z]{3}\s*)?([\d,]+(?:\.\d{1,2})?)/i)?.[1] || total);
  const itemLines = [];
  const itemPattern = /^(.+?)\s+(\d+(?:[.,]\d+)?)\s+(?:[A-Z]{3}\s*)?([\d,]+(?:\.\d{1,2})?)\s+(?:[A-Z]{3}\s*)?([\d,]+(?:\.\d{1,2})?)$/i;
  lines.forEach((line) => {
    if (/subtotal|total|vat|tax|amount due|balance/i.test(line)) return;
    const match = line.match(itemPattern);
    if (!match || itemLines.length >= 20) return;
    itemLines.push({ ...blankLine(), itemDescription: match[1].trim(), quantity: numericValue(match[2]) || 1, rate: numericValue(match[3]) });
  });
  if (!itemLines.length) itemLines.push({ ...blankLine(), itemDescription: "Imported invoice line — review OCR result", quantity: 1, rate: subtotal || total });
  const senderName = senderAddress.split("\n")[0] || "";
  return normalizeInvoice({
    ...blankInvoice(), documentNumber: invoiceNumber, issueDate, dueDate, currency, taxRate,
    senderName, senderAddress: senderAddress.split("\n").slice(senderName ? 1 : 0).join("\n"),
    clientName, clientAddress: clientAddress.split("\n").slice(clientName ? 1 : 0).join("\n"),
    projectName: fileName.replace(/\.[^.]+$/, "") || "Imported invoice", projectDescription,
    paymentTerms, bankingDetails, lines: itemLines, status: "Draft", amountPaid: 0, payments: []
  });
}

function parseOcrNumber(value) {
  let cleaned = String(value || "").replace(/[R$€£]|\s/g, "").replace(/'/g, "");
  if (!cleaned) return 0;
  const comma = cleaned.lastIndexOf(",");
  const dot = cleaned.lastIndexOf(".");
  if (comma >= 0 && dot >= 0) {
    cleaned = comma > dot ? cleaned.replace(/\./g, "").replace(",", ".") : cleaned.replace(/,/g, "");
  } else if (comma >= 0) {
    cleaned = cleaned.length - comma - 1 <= 2 ? cleaned.replace(",", ".") : cleaned.replace(/,/g, "");
  }
  const number = Number(cleaned.replace(/[^0-9.-]/g, ""));
  return Number.isFinite(number) ? number : 0;
}

function ocrLabelValue(lines, labels) {
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    const lower = line.toLowerCase();
    const label = labels.find((candidate) => lower === candidate || lower.startsWith(`${candidate}:`) || lower.startsWith(`${candidate} `));
    if (!label) continue;
    const remainder = line.slice(lower.indexOf(label) + label.length).replace(/^[\s:#-]+/, "").trim();
    return remainder || lines[index + 1] || "";
  }
  return "";
}

function ocrLabelBlock(lines, labels, stops = []) {
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    const lower = line.toLowerCase();
    const label = labels.find((candidate) => lower === candidate || lower.startsWith(`${candidate}:`) || lower.startsWith(`${candidate} `));
    if (!label) continue;
    const values = [];
    const remainder = line.slice(lower.indexOf(label) + label.length).replace(/^[\s:#-]+/, "").trim();
    if (remainder) values.push(remainder);
    for (let next = index + 1; next < lines.length && values.length < 4; next += 1) {
      const nextLower = lines[next].toLowerCase();
      if (stops.some((stop) => nextLower === stop || nextLower.startsWith(`${stop}:`) || nextLower.startsWith(`${stop} `))) break;
      if (/^(invoice|tax invoice|quote|subtotal|vat|total|amount due|balance due)\b/i.test(lines[next])) break;
      values.push(lines[next]);
    }
    return values.join("\n");
  }
  return "";
}

function ocrDateValue(value) {
  const match = String(value || "").match(/\b(\d{1,4})[\/.-](\d{1,2})[\/.-](\d{1,4})\b/);
  if (!match) return "";
  let year; let month; let day;
  if (match[1].length === 4) { year = Number(match[1]); month = Number(match[2]); day = Number(match[3]); }
  else { day = Number(match[1]); month = Number(match[2]); year = Number(match[3]); if (year < 100) year += 2000; }
  const date = new Date(year, month - 1, day);
  return date.getFullYear() === year && date.getMonth() === month - 1 && date.getDate() === day ? localDate(date) : "";
}

function ocrDateList(text) {
  const values = [];
  (String(text || "").match(/\b\d{1,4}[\/.-]\d{1,2}[\/.-]\d{1,4}\b/g) || []).forEach((value) => { const date = ocrDateValue(value); if (date) values.push(date); });
  return [...new Set(values)];
}

function ocrCurrencyValue(text) {
  const upper = String(text || "").toUpperCase();
  if (upper.includes("ZAR") || /R\s*[0-9]/.test(text)) return "ZAR";
  if (upper.includes("EUR") || String(text).includes("€")) return "EUR";
  if (upper.includes("GBP") || String(text).includes("£")) return "GBP";
  if (upper.includes("USD") || String(text).includes("$")) return "USD";
  return "ZAR";
}

function ocrTotalValue(text, lines) {
  const values = [];
  lines.forEach((line) => {
    if (!/(?:amount\s+due|balance\s+due|grand\s+total|invoice\s+total|total(?:\s+due)?)/i.test(line)) return;
    (line.match(/(?:ZAR|USD|EUR|GBP|R|\$|€|£)?\s*[0-9][0-9 ,.']*(?:[.,][0-9]{1,2})?/gi) || []).forEach((value) => { const number = parseOcrNumber(value); if (number > 0) values.push(number); });
  });
  if (values.length) return values[values.length - 1];
  const fallback = String(text || "").match(/(?:ZAR|USD|EUR|GBP|R|\$|€|£)\s*[0-9][0-9 ,.']*(?:[.,][0-9]{2})/i);
  return fallback ? parseOcrNumber(fallback[0]) : 0;
}

function importOcrResult(text, fileName = "") {
  const cleaned = String(text || "").replace(/\u00a0/g, " ").trim();
  const lines = cleaned.split(/\r?\n/).map((line) => line.replace(/\s+/g, " ").trim()).filter(Boolean);
  const next = blankInvoice();
  next.documentNumber = cleaned.match(/(?:invoice|tax invoice|document|reference|ref\.)\s*(?:number|no\.?|#)?\s*[:#-]?\s*([A-Z0-9][A-Z0-9\-/]*)/i)?.[1] || "";
  next.clientName = ocrLabelValue(lines, ["bill to", "invoice to", "customer", "client"]);
  next.clientContact = ocrLabelValue(lines, ["attention", "contact", "contact person"]);
  next.clientAddress = ocrLabelBlock(lines, ["client address", "billing address", "bill to", "invoice to"], ["attention", "contact", "project", "from", "seller", "supplier"]);
  next.senderName = ocrLabelValue(lines, ["from", "seller", "supplier", "vendor", "company"]);
  next.senderAddress = ocrLabelBlock(lines, ["sender address", "business address", "from", "seller", "supplier"], ["bill to", "invoice to", "client", "customer", "project", "invoice date", "date"]);
  next.paymentTerms = ocrLabelBlock(lines, ["payment terms", "terms"], ["bank", "banking", "subtotal", "vat", "total"]);
  next.bankingDetails = ocrLabelBlock(lines, ["banking details", "bank details", "payment details", "bank"], ["subtotal", "vat", "total", "payment terms"]);
  next.projectName = ocrLabelValue(lines, ["project", "project name"]) || fileName.replace(/\.[^.]+$/, "");
  next.projectDescription = ocrLabelBlock(lines, ["description", "scope", "work description"], ["subtotal", "vat", "total", "payment terms"]);
  const dates = ocrDateList(cleaned);
  next.issueDate = ocrDateValue(ocrLabelValue(lines, ["invoice date", "issue date"])) || dates[0] || today();
  next.dueDate = ocrDateValue(ocrLabelValue(lines, ["due date", "payment due"])) || dates[1] || afterDays(7, new Date(`${next.issueDate}T00:00:00`));
  next.currency = ocrCurrencyValue(cleaned);
  const taxMatch = cleaned.match(/(?:VAT|tax)[^\n%]{0,30}?([0-9]+(?:[.,][0-9]+)?)\s*%/i);
  next.taxRate = Math.min(Math.max(taxMatch ? parseOcrNumber(taxMatch[1]) : 0, 0), 100);
  const total = ocrTotalValue(cleaned, lines);
  next.lines = [{ ...blankLine(), itemDescription: "Imported invoice total — review and replace with itemised lines", quantity: 1, rate: next.taxRate > 0 ? total / (1 + next.taxRate / 100) : total }];
  next.projectDescription = next.projectDescription || `Imported locally from ${fileName || "uploaded invoice"}. Review all converted fields against the original before issuing.`;
  next.status = "Draft"; next.amountPaid = 0; next.payments = [];
  invoice = next;
  renderDocument(); markDirty();
}

function importText(text, fileName = "") {
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch { /* Continue with labelled text parsing. */ }
  if (parsed && (parsed.format || parsed.invoices)) {
    restoreBackup(parsed);
    return;
  }
  if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
    invoice = normalizeInvoice({ ...parsed, status: "Draft", amountPaid: 0, payments: [] });
    renderDocument(); markDirty(); setStatus("Invoice imported and editable. Review every field before issuing."); return;
  }
  if (/\.json$/i.test(fileName)) { setStatus("This JSON file is not a valid invoice or INV backup."); return; }
  const pick = (label) => text.match(new RegExp(`^\\s*${label}\\s*:\\s*(.+)$`, "im"))?.[1]?.trim() || "";
  const next = blankInvoice();
  next.documentNumber = pick("(?:invoice|document)\\s*(?:number|no\\.)?");
  next.clientName = pick("client(?: name)?");
  next.clientAddress = pick("client address");
  next.senderName = pick("sender(?: name)?");
  next.paymentTerms = pick("payment terms");
  next.projectName = fileName.replace(/\.[^.]+$/, "");
  next.lines = [{ ...blankLine(), itemDescription: "Imported invoice total — review and replace with itemised lines" }];
  invoice = next; renderDocument(); markDirty(); setStatus("Invoice text imported. Review the converted fields before issuing.");
}

async function importVisualFile(file, generation) {
  setStatus("Starting local OCR…");
  const text = file.type === "application/pdf" || /\.pdf$/i.test(file.name)
    ? await recognizePDF(file)
    : await recognizeImage(file);
  if (generation !== importGeneration) return;
  if (!text.trim()) throw new Error("No readable text was found in the uploaded file.");
  invoice = parseOCRInvoice(text, file.name);
  renderDocument(); markDirty();
  setStatus("OCR complete. Review every field before issuing.");
}

async function importFile(event) {
  const file = event.target.files[0];
  if (!file) return;
  if (hasUnsavedChanges) persistInvoice(true);
  clearTimeout(autosaveTimer);
  const generation = ++importGeneration;
  if (/\.pdf$/i.test(file.name) || file.type === "application/pdf" || file.type.startsWith("image/")) {
    try { await importVisualFile(file, generation); }
    catch (error) { if (generation === importGeneration) setStatus(error?.message || "OCR could not read this file. You can still enter the invoice manually."); }
  } else {
    try { const text = await file.text(); if (generation === importGeneration) importText(text, file.name); }
    catch { if (generation === importGeneration) setStatus("The selected file could not be opened."); }
  }
  event.target.value = "";
}

function openPayment() {
  if (invoice.status === "Draft") { setStatus("Issue the invoice before recording a payment."); return; }
  $("payment-date").value = today();
  $("payment-amount").value = Math.max(totals(invoice).total - (Number(invoice.amountPaid) || 0), 0).toFixed(2);
  $("payment-reference-input").value = invoice.documentNumber || "";
  $("payment-notes").value = "";
  openModal("payment-modal");
}

function savePayment() {
  const amount = Number($("payment-amount").value) || 0;
  if (amount <= 0) { setStatus("Enter a payment amount greater than zero."); return; }
  const remaining = Math.max(totals(invoice).total - (Number(invoice.amountPaid) || 0), 0);
  if (amount > remaining + 0.005) { setStatus(`Payment cannot exceed the remaining balance of ${money(remaining)}.`); return; }
  invoice.payments = Array.isArray(invoice.payments) ? invoice.payments : [];
  invoice.payments.push({ id: makeId(), date: $("payment-date").value || today(), amount, type: $("payment-type").value, method: $("payment-method").value, reference: $("payment-reference-input").value, notes: $("payment-notes").value });
  invoice.amountPaid = invoice.payments.reduce((sum, payment) => sum + (payment.type === "Refund" ? -(Number(payment.amount) || 0) : (Number(payment.amount) || 0)), 0);
  const result = totals(invoice);
  invoice.status = invoice.amountPaid + .005 >= result.total ? "Paid" : "Partially Paid";
  closeModal("payment-modal"); markDirty(); persistInvoice(false); renderDocument(); setStatus("Payment saved");
}

function renderSetup() {
  $("setup-company-name").value = setupProfile.legalName || "";
  $("setup-vat-number").value = setupProfile.vatNumber || "";
  $("setup-company-address").value = setupProfile.address || "";
}

function applySetupToInvoice() {
  invoice.senderName = setupProfile.legalName;
  invoice.senderAddress = setupProfile.address;
  invoice.senderVatNumber = setupProfile.vatNumber;
}

function saveSetupProfile() {
  const previousProfile = setupProfile;
  const nextProfile = {
    legalName: $("setup-company-name").value.trim(),
    vatNumber: $("setup-vat-number").value.trim(),
    address: $("setup-company-address").value.trim()
  };
  try { localStorage.setItem(PROFILE_KEY, JSON.stringify(nextProfile)); }
  catch { setStatus("This browser could not save company details. Download a backup before leaving."); return; }
  // Existing documents keep their own sender details; only populate an empty draft.
  const emptySender = invoice.status === "Draft" && (!invoice.senderName && !invoice.senderAddress && !invoice.senderVatNumber
    || (invoice.senderName === previousProfile.legalName && invoice.senderAddress === previousProfile.address && invoice.senderVatNumber === previousProfile.vatNumber));
  setupProfile = nextProfile;
  if (emptySender) { applySetupToInvoice(); markDirty(); }
  closeModal("setup-modal"); renderDocument(); setStatus("Company details saved for new invoices");
}

function downloadBackup() {
  const current = normalizeInvoice(JSON.parse(JSON.stringify(invoice)));
  const backupInvoices = savedInvoices.filter((saved) => saved.id !== current.id).concat(current);
  const payload = {
    format: "INV editable backup",
    version: 1,
    exportedAt: new Date().toISOString(),
    currentInvoiceId: invoice.id,
    profile: setupProfile,
    invoices: backupInvoices
  };
  const blob = new Blob([JSON.stringify(payload, null, 2)], { type: "application/json" });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = `INV-backup-${today()}.json`;
  document.body.appendChild(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
  setStatus("Editable backup downloaded");
}

function restoreBackup(payload) {
  if (payload.format !== "INV editable backup" || payload.version !== 1 || !Array.isArray(payload.invoices)
      || !payload.invoices.every((item) => item && typeof item === "object" && !Array.isArray(item)
        && Array.isArray(item.lines) && item.lines.every((line) => line && typeof line === "object"))
      || !payload.profile || typeof payload.profile !== "object" || Array.isArray(payload.profile)) {
    setStatus("This is not a supported INV editable backup. Your Documents have not changed."); return;
  }
  const profile = {
    legalName: String(payload.profile.legalName || ""),
    vatNumber: String(payload.profile.vatNumber || ""),
    address: String(payload.profile.address || "")
  };
  const merged = savedInvoices.slice();
  let selected;
  for (const raw of payload.invoices) {
    const restored = normalizeInvoice(raw);
    const existing = merged.find((item) => item.id === restored.id);
    if (existing && JSON.stringify(existing) !== JSON.stringify(restored)) restored.id = makeId();
    if (!existing || existing.id !== restored.id) merged.push(restored);
    if (raw.id === payload.currentInvoiceId || !selected) selected = restored;
  }
  try { localStorage.setItem(STORAGE_KEY, JSON.stringify(merged)); }
  catch { setStatus("The backup could not be restored: browser storage is full or unavailable."); return; }
  savedInvoices = merged;
  setupProfile = profile;
  let profileSaved = true;
  try { localStorage.setItem(PROFILE_KEY, JSON.stringify(profile)); } catch { profileSaved = false; }
  clearTimeout(autosaveTimer);
  hasUnsavedChanges = false;
  $("status-icon").classList.remove("unsaved");
  $("unsaved-label").textContent = "";
  invoice = selected || blankInvoice();
  if (!selected) applySetupToInvoice();
  renderDocument(); renderDocuments();
  setStatus(profileSaved ? "Backup restored. Existing Documents were kept; different versions are separate copies." : "Documents restored, but company details could not be saved. Keep your backup.");
}

function clearLocalData() {
  if (!window.confirm("Clear all INV invoices, the current draft and company details from this browser? Download an editable backup first if you need them. This cannot be undone.")) return;
  clearTimeout(autosaveTimer);
  importGeneration += 1;
  try {
    localStorage.removeItem(STORAGE_KEY);
    localStorage.removeItem(PROFILE_KEY);
    localStorage.removeItem(LEGACY_PROFILE_KEY);
  } catch { setStatus("This browser could not clear local data. Use your browser's site-data settings."); return; }
  savedInvoices = [];
  setupProfile = { legalName: "", vatNumber: "", address: "" };
  invoice = normalizeInvoice();
  hasUnsavedChanges = false;
  $("status-icon").classList.remove("unsaved");
  $("unsaved-label").textContent = "";
  $("document-search").value = "";
  $("status-filter").value = "All";
  closeModal("setup-modal");
  renderDocument(); renderDocuments();
  setStatus("Local data cleared");
}

function handleShortcuts(event) {
  if (!(event.metaKey || event.ctrlKey)) return;
  const key = event.key.toLowerCase();
  if (key === "s") { event.preventDefault(); saveInvoice(); }
  if (key === "n") { event.preventDefault(); saveNewDocument(event.shiftKey ? "QUOTE" : "INVOICE"); }
  if (key === "o") { event.preventDefault(); renderDocuments(); openModal("documents-modal"); }
  if (key === "e" && event.shiftKey) { event.preventDefault(); window.print(); }
}

$("new-invoice").onclick = () => saveNewDocument("INVOICE");
$("documents-button").onclick = () => { renderDocuments(); openModal("documents-modal"); };
$("save-invoice").onclick = saveInvoice;
$("issue-invoice").onclick = issueInvoice;
$("export-invoice").onclick = () => { renderExportPages(); setStatus("Use the print dialog to choose Save as PDF."); window.print(); };
$("payment-button").onclick = openPayment;
$("setup-button").onclick = () => { renderSetup(); openModal("setup-modal"); };
$("add-line").onclick = () => { invoice.lines.push(blankLine()); markDirty(); renderLines(); updateDerived(); };
$("import-file").onchange = importFile;
$("save-payment").onclick = savePayment;
$("save-setup-profile").onclick = saveSetupProfile;
$("download-backup").onclick = downloadBackup;
$("clear-local-data").onclick = clearLocalData;
$("document-search").oninput = renderDocuments;
$("status-filter").onchange = renderDocuments;
document.querySelectorAll("[data-close-modal]").forEach((button) => button.addEventListener("click", () => closeModal(button.dataset.closeModal)));
document.querySelectorAll(".modal-backdrop").forEach((backdrop) => backdrop.addEventListener("click", (event) => { if (event.target === backdrop) closeModal(backdrop.id); }));
document.addEventListener("keydown", handleShortcuts);
window.addEventListener("beforeunload", () => { if (hasUnsavedChanges) persistInvoice(true); });

bindFields();
applySetupToInvoice();
renderDocument();
