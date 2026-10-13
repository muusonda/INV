const STORAGE_KEY = "inv.web.invoices.v1";
const PROFILE_KEY = "inv.web.books.profile.v1";

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
    senderName: "", senderAddress: "", clientName: "", clientContact: "", clientAddress: "",
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
  try { return { legalName: "", vatNumber: "", address: "", ...JSON.parse(localStorage.getItem(PROFILE_KEY) || "{}") }; }
  catch { return { legalName: "", vatNumber: "", address: "" }; }
}

let invoice = normalizeInvoice();
let savedInvoices = readSavedInvoices();
let booksProfile = readProfile();
let hasUnsavedChanges = false;
let autosaveTimer = null;

const FIELD_PATHS = {
  "document-number": "documentNumber", "issue-date": "issueDate", "due-date": "dueDate",
  "due-date-mode": "dueDateMode", "final-due-date": "finalDueDate", "final-due-date-mode": "finalDueDateMode",
  "payment-plan": "paymentPlan", "payment-stage": "paymentStage", currency: "currency", "tax-rate": "taxRate",
  "sender-name": "senderName", "sender-address": "senderAddress", "client-name": "clientName",
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

function currentTitle() {
  if (invoice.documentType === "QUOTE") return "QUOTE";
  if (String(booksProfile.vatNumber || "").trim()) return "TAX INVOICE";
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
  if (!silent) { $("saved-label")?.remove(); setStatus(invoice.status === "Draft" ? "Saved" : "Saved and Books updated"); }
  renderDocuments();
  renderClientList();
  renderBooks();
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
  renderBooks();
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
    <section class="document-heading"><div class="heading-meta"><span class="paper-label">STATUS</span><span class="paper-status">${escapeHTML(draft.status.toUpperCase())}</span><span class="paper-label">DOCUMENT NUMBER</span><span class="paper-input small-input">${escapeHTML(draft.documentNumber || "")}</span></div><h1>${escapeHTML(currentTitle())}</h1></section>
    <section class="schedule-row"><div class="paper-field"><span class="paper-label">ISSUE DATE</span><span class="paper-input">${escapeHTML(draft.issueDate)}</span></div><div class="paper-field"><span class="paper-label">PAYMENT SCHEDULE</span><span class="paper-input">${escapeHTML(draft.paymentPlan)} · ${escapeHTML(dueText(stage))}</span></div><div class="paper-field"><span class="paper-label">PAYMENT STAGE</span><span class="paper-input">${escapeHTML(draft.paymentStage || stage.label)}</span></div><div class="paper-field"><span class="paper-label">CURRENCY</span><span class="paper-input">${escapeHTML(draft.currency)}</span></div></section>
    <section class="document-section parties-grid"><div class="party-column"><h2 class="section-label">FROM</h2><span class="paper-label">NAME</span><span class="paper-input">${escapeHTML(draft.senderName)}</span><p class="paper-textarea">${multiline(draft.senderAddress)}</p></div><div class="party-column"><h2 class="section-label">BILL TO</h2><span class="paper-label">CLIENT</span><span class="paper-input">${escapeHTML(draft.clientName)}</span><span class="paper-label">ATTENTION</span><span class="paper-input">${escapeHTML(draft.clientContact)}</span><p class="paper-textarea">${multiline(draft.clientAddress)}</p></div></section>
    <section class="document-section"><h2 class="section-label">PROJECT</h2><span class="paper-label">PROJECT NAME</span><span class="paper-input">${escapeHTML(draft.projectName)}</span><p class="paper-textarea">${multiline(draft.projectDescription)}</p></section>
    <section class="document-section line-items-section"><div class="line-headings"><span>DESCRIPTION</span><span>QTY</span><span>RATE</span><span>AMOUNT</span><span></span></div><div>${rows}</div></section>
    <section class="document-section totals-section"><div></div><div class="totals-list"><div class="amount-row"><span>SUBTOTAL</span><strong>${escapeHTML(money(result.subtotal * stage.fraction, draft.currency))}</strong></div><div class="amount-row"><span>VAT</span><strong>${draft.taxRate > 0 ? escapeHTML(money(result.tax * stage.fraction, draft.currency)) : "N/A"}</strong></div><hr><div class="amount-row total-row"><span>TOTAL</span><strong>${escapeHTML(money(amount, draft.currency))}</strong></div></div></section>
    <section class="document-section terms-section"><div class="section-label">${draft.documentType === "QUOTE" ? "QUOTE TERMS & ACCEPTANCE" : "PAYMENT TERMS"}</div><p class="paper-textarea large-textarea">${multiline(terms || "Add payment terms")}</p><div class="section-label banking-label">BANKING DETAILS</div><p class="paper-textarea">${multiline(draft.bankingDetails)}</p><div class="reference-block"><span class="paper-label">PAYMENT REFERENCE</span><strong>${escapeHTML(draft.documentNumber || "ASSIGNED ON ISSUE")}</strong></div></section>
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
  invoice = blankInvoice();
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
  setStatus("Issued and saved to Books");
}

function loadInvoice(id) {
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
  renderDocuments(); renderClientList(); renderBooks(); setStatus("Document deleted");
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

function importText(text, fileName = "") {
  try {
    const parsed = JSON.parse(text);
    invoice = normalizeInvoice({ ...parsed, status: "Draft", amountPaid: 0, payments: [] });
    renderDocument(); markDirty(); setStatus("Invoice imported and editable. Review every field before issuing."); return;
  } catch { /* Continue with labelled text parsing. */ }
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

function importFile(event) {
  const file = event.target.files[0];
  if (!file) return;
  if (/\.pdf$|^image\//i.test(file.name) || file.type === "application/pdf" || file.type.startsWith("image/")) {
    invoice = blankInvoice(); invoice.projectName = file.name.replace(/\.[^.]+$/, ""); invoice.lines = [{ ...blankLine(), itemDescription: "Imported invoice total — review and replace with itemised lines" }];
    renderDocument(); markDirty(); setStatus("PDF/image imported as an editable draft. Check each field against the original.");
  } else {
    file.text().then((text) => importText(text, file.name)).catch(() => setStatus("The selected file could not be opened."));
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
  closeModal("payment-modal"); markDirty(); persistInvoice(false); renderDocument(); setStatus("Payment saved and Books updated");
}

function renderBooks() {
  const outstanding = savedInvoices.reduce((sum, saved) => sum + Math.max(totals(saved).total - (Number(saved.amountPaid) || 0), 0), 0);
  const paid = savedInvoices.reduce((sum, saved) => sum + (Number(saved.amountPaid) || 0), 0);
  $("books-outstanding").textContent = money(outstanding);
  $("books-invoices").textContent = String(savedInvoices.length);
  $("books-paid").textContent = money(paid);
  $("books-company-name").value = booksProfile.legalName || invoice.senderName || "";
  $("books-vat-number").value = booksProfile.vatNumber || "";
  $("books-company-address").value = booksProfile.address || invoice.senderAddress || "";
}

function saveBooksProfile() {
  booksProfile = { legalName: $("books-company-name").value, vatNumber: $("books-vat-number").value, address: $("books-company-address").value };
  localStorage.setItem(PROFILE_KEY, JSON.stringify(booksProfile));
  closeModal("books-modal"); updateDerived(); setStatus("Books company details saved");
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
$("books-button").onclick = () => { renderBooks(); openModal("books-modal"); };
$("add-line").onclick = () => { invoice.lines.push(blankLine()); markDirty(); renderLines(); updateDerived(); };
$("import-file").onchange = importFile;
$("save-payment").onclick = savePayment;
$("save-books-profile").onclick = saveBooksProfile;
$("document-search").oninput = renderDocuments;
$("status-filter").onchange = renderDocuments;
document.querySelectorAll("[data-close-modal]").forEach((button) => button.addEventListener("click", () => closeModal(button.dataset.closeModal)));
document.querySelectorAll(".modal-backdrop").forEach((backdrop) => backdrop.addEventListener("click", (event) => { if (event.target === backdrop) closeModal(backdrop.id); }));
document.addEventListener("keydown", handleShortcuts);
window.addEventListener("beforeunload", () => { if (hasUnsavedChanges) persistInvoice(true); });

bindFields();
renderDocument();
