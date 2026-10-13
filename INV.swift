import SwiftUI
import AppKit
import CoreData
import PDFKit
import UniformTypeIdentifiers
import Vision

// MARK: - Formatting

private let invDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .long
    formatter.timeStyle = .none
    return formatter
}()

private let csvDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

private let timestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter
}()

private let decimalFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = 2
    return formatter
}()

private func money(_ value: Double, currency: String) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = currency

    if currency == "ZAR" {
        formatter.currencySymbol = "R"
    }

    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    return formatter.string(from: NSNumber(value: value))
        ?? "\(currency) \(String(format: "%.2f", value))"
}

private func csvEscape(_ value: String) -> String {
    "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
}

// Payment details are intentionally blank in the source repository.
// Configure them in the app before issuing an invoice.
private let invDefaultBankingDetails = ""
private let invLegacyBankingDetails = ""


// MARK: - Draft models

struct LineDraft: Identifiable, Hashable {
    var id = UUID()
    var itemDescription = ""
    var quantity = 1.0
    var rate = 0.0

    var total: Double {
        quantity * rate
    }
}

enum SouthAfricanSampleNames {
    private static let names = [
        "Lethabo Mokoena",
        "Lubanzi Dlamini",
        "Nkazimulo Ndlovu",
        "Onalerona Molefe",
        "Zanokuhle Nkosi",
        "Melokuhle Baloyi",
        "Lisakhanya Jacobs",
        "Omphile Mokoena",
        "Enzokuhle Dlamini",
        "Lethokuhle Ndlovu",
        "Amahle Nkosi",
        "Lesedi Molefe"
    ]

    static func randomName() -> String {
        names.randomElement()
            ?? "Lethabo Mokoena"
    }
}


struct InvoiceDraft: Equatable {
    var id = UUID()
    var documentType = "INVOICE"
    var documentNumber = ""
    var status = "Draft"
    var sampleClientName = SouthAfricanSampleNames.randomName()

    var issueDate = Date()
    var dueDate = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()

    var dueDateMode = "Specific date"

    var finalDueDate =
        Calendar.current.date(
            byAdding: .day,
            value: 21,
            to: Date()
        ) ?? Date()

    var finalDueDateMode = "On delivery"
    var paymentPlan = "Single"
    var paymentStage = ""

    var senderName = ""
    var senderAddress = ""

    var clientName = ""
    var clientAddress = ""
    var clientContact = ""

    var projectName = ""
    var projectDescription = ""

    var lines: [LineDraft] = [LineDraft()]

    var currency = "ZAR"
    var taxRate = 0.0

    var paymentTerms = ""
    var bankingDetails = invDefaultBankingDetails

    var subtotal: Double {
        lines.reduce(0) { $0 + $1.total }
    }

    var tax: Double {
        subtotal * taxRate / 100
    }

    var total: Double {
        subtotal + tax
    }

    var isIssued: Bool {
        status != "Draft"
    }

    static func blank() -> InvoiceDraft {
        InvoiceDraft()
    }
}


private func invoiceDueDateText(
    mode: String,
    date: Date
) -> String {
    switch mode {
    case "At project start":
        return "At project start"

    case "On delivery":
        return "On delivery"

    default:
        return invDateFormatter.string(
            from: date
        )
    }
}



private func invoiceBaseNumber(
    _ number: String
) -> String {
    number.replacingOccurrences(
        of: #"-[12]$"#,
        with: "",
        options: .regularExpression
    )
}


// MARK: - Invoice import

enum InvoiceImportError: LocalizedError {
    case unreadableFile
    case noText

    var errorDescription: String? {
        switch self {
        case .unreadableFile:
            return "The selected file could not be opened."
        case .noText:
            return "No readable invoice text was found. Try a clearer PDF or image."
        }
    }
}


enum InvoiceImporter {
    static func draft(from url: URL) throws -> InvoiceDraft {
        let text: String

        if url.pathExtension.lowercased() == "pdf" {
            text = try pdfText(from: url)
        } else {
            guard let image = NSImage(contentsOf: url) else {
                throw InvoiceImportError.unreadableFile
            }
            text = try recognisedText(in: image)
        }

        let cleaned = text
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard cleaned.count >= 8 else {
            throw InvoiceImportError.noText
        }

        return convertedDraft(from: cleaned, sourceURL: url)
    }

    private static func pdfText(from url: URL) throws -> String {
        guard let document = PDFDocument(url: url) else {
            throw InvoiceImportError.unreadableFile
        }

        var pages: [String] = []

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }

            if let pageText = page.string,
               pageText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 8 {
                pages.append(pageText)
            } else {
                let image = page.thumbnail(
                    of: NSSize(width: 2000, height: 2800),
                    for: .mediaBox
                )
                pages.append(try recognisedText(in: image))
            }
        }

        return pages.joined(separator: "\n")
    }

    private static func recognisedText(in image: NSImage) throws -> String {
        var rect = NSRect(origin: .zero, size: image.size)

        guard let cgImage = image.cgImage(
            forProposedRect: &rect,
            context: nil,
            hints: nil
        ) else {
            throw InvoiceImportError.unreadableFile
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        try VNImageRequestHandler(
            cgImage: cgImage,
            options: [:]
        ).perform([request])

        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    private static func convertedDraft(
        from text: String,
        sourceURL: URL
    ) -> InvoiceDraft {
        var draft = InvoiceDraft.blank()
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        draft.documentNumber = firstCapture(
            in: text,
            patterns: [
                #"(?i)invoice\s*(?:number|no\.?|#)\s*[:#-]?\s*([A-Z0-9][A-Z0-9\-/]*)"#,
                #"(?i)(?:reference|ref\.?)\s*[:#-]\s*([A-Z0-9][A-Z0-9\-/]*)"#
            ]
        ) ?? ""

        draft.clientName = valueAfterLabel(
            in: lines,
            labels: ["bill to", "invoice to", "customer", "client"]
        ) ?? ""

        let dates = detectedDates(in: text)
        draft.issueDate = labelledDate(
            in: lines,
            labels: ["invoice date", "issue date", "date"]
        ) ?? dates.first ?? Date()
        draft.dueDate = labelledDate(
            in: lines,
            labels: ["due date", "payment due"]
        ) ?? dates.dropFirst().first ??
            Calendar.current.date(byAdding: .day, value: 7, to: draft.issueDate) ?? draft.issueDate

        draft.currency = detectedCurrency(in: text)

        let taxRate = capturedNumber(
            in: text,
            pattern: #"(?i)(?:VAT|tax)[^\n%]{0,20}?([0-9]+(?:[.,][0-9]+)?)\s*%"#
        ) ?? 0
        draft.taxRate = min(max(taxRate, 0), 100)

        let total = detectedTotal(in: text)
        let subtotal = draft.taxRate > 0
            ? total / (1 + draft.taxRate / 100)
            : total

        draft.lines = [
            LineDraft(
                itemDescription: "Imported invoice total — review and replace with itemised lines",
                quantity: 1,
                rate: subtotal
            )
        ]
        draft.projectName = sourceURL.deletingPathExtension().lastPathComponent
        draft.projectDescription =
            "Imported locally from \(sourceURL.lastPathComponent). Review all converted fields against the original before issuing."
        draft.status = "Draft"

        return draft
    }

    private static func firstCapture(
        in text: String,
        patterns: [String]
    ) -> String? {
        for pattern in patterns {
            if let value = capture(in: text, pattern: pattern) {
                return value
            }
        }
        return nil
    }

    private static func capture(in text: String, pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }

        return String(text[range])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func capturedNumber(
        in text: String,
        pattern: String
    ) -> Double? {
        capture(in: text, pattern: pattern).flatMap(parseNumber)
    }

    private static func parseNumber(_ value: String) -> Double? {
        var cleaned = value
            .replacingOccurrences(of: " ", with: "")

        if cleaned.contains(",") && cleaned.contains(".") {
            cleaned = cleaned.replacingOccurrences(of: ",", with: "")
        } else if cleaned.contains(",") {
            cleaned = cleaned.replacingOccurrences(of: ",", with: ".")
        }

        return Double(
            cleaned.filter { $0.isNumber || $0 == "." || $0 == "-" }
        )
    }

    private static func detectedTotal(in text: String) -> Double {
        let pattern =
            #"(?i)(?:amount\s+due|balance\s+due|grand\s+total|invoice\s+total|total)\s*[:\-]?\s*(?:ZAR|USD|EUR|GBP|R|\$|€|£)?\s*([0-9][0-9 ,.]*[.,][0-9]{2})"#

        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return 0
        }

        let matches = expression.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        )

        return matches.compactMap { match in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text)
            else { return nil }
            return parseNumber(String(text[range]))
        }.last ?? 0
    }

    private static func detectedCurrency(in text: String) -> String {
        let upper = text.uppercased()
        if upper.contains("ZAR") || text.range(of: #"R\s*[0-9]"#, options: .regularExpression) != nil {
            return "ZAR"
        }
        if upper.contains("EUR") || text.contains("€") { return "EUR" }
        if upper.contains("GBP") || text.contains("£") { return "GBP" }
        if upper.contains("USD") || text.contains("$") { return "USD" }
        return "ZAR"
    }

    private static func valueAfterLabel(
        in lines: [String],
        labels: [String]
    ) -> String? {
        for (index, line) in lines.enumerated() {
            let lower = line.lowercased()
            guard let label = labels.first(where: { lower.hasPrefix($0) }) else {
                continue
            }

            let remainder = line.dropFirst(label.count)
                .trimmingCharacters(in: CharacterSet(charactersIn: ":- "))
            if !remainder.isEmpty { return remainder }
            if lines.indices.contains(index + 1) { return lines[index + 1] }
        }
        return nil
    }

    private static func detectedDates(in text: String) -> [Date] {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.date.rawValue
        ) else { return [] }

        return detector.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ).compactMap(\.date)
    }

    private static func labelledDate(
        in lines: [String],
        labels: [String]
    ) -> Date? {
        for line in lines where labels.contains(where: { line.lowercased().contains($0) }) {
            if let date = detectedDates(in: line).first { return date }
        }
        return nil
    }
}


struct SavedClient: Identifiable, Hashable {
    let id: UUID
    let name: String
    let contactName: String
    let billingAddress: String
}


private func invoiceEmailDraftText(
    for draft: InvoiceDraft,
    amountPaid: Double
) -> String {
    let number =
        draft.documentNumber
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            .isEmpty
        ? "Draft"
        : draft.documentNumber

    let project =
        draft.projectName
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )

    let contact =
        draft.clientContact
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )

    let client =
        draft.clientName
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )

    let greetingSource =
        contact.isEmpty
        ? client
        : contact

    let firstGreetingLine =
        greetingSource
            .components(
                separatedBy: .newlines
            )
            .first?
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            ) ?? ""

    let greeting =
        firstGreetingLine.isEmpty
        ? "there"
        : firstGreetingLine

    let amountDue =
        max(
            draft.total - amountPaid,
            0
        )

    let amountText =
        money(
            amountDue,
            currency: draft.currency
        )

    let dueText =
        invoiceDueDateText(
            mode: draft.dueDateMode,
            date: draft.dueDate
        )

    let duePhrase: String

    switch draft.dueDateMode {
    case "At project start":
        duePhrase =
            "at the start of the project"

    case "On delivery":
        duePhrase =
            "on delivery"

    default:
        duePhrase =
            "by \(dueText)"
    }

    let projectPhrase =
        project.isEmpty
        ? ""
        : " for \(project)"

    let subjectSuffix =
        project.isEmpty
        ? ""
        : " – \(project)"

    let stage =
        draft.paymentStage
            .lowercased()

    let isQuote =
        draft.documentType
            .uppercased()
            == "QUOTE"

    let subject: String
    let paragraph: String

    if isQuote {
        subject =
            "Quote \(number)\(subjectSuffix)"

        let validity: String

        if draft.dueDateMode
            == "Specific date" {
            validity =
                " The quote is valid until \(dueText)."
        } else {
            validity = ""
        }

        paragraph =
            """
Please find attached quote \(number)\(projectPhrase). The quoted total is \(amountText).\(validity) Please let me know if you would like to proceed or need any adjustments.
"""
    } else if stage.contains(
        "first 50"
    ) || stage.contains(
        "deposit"
    ) {
        subject =
            "Invoice \(number) – First 50% deposit"

        paragraph =
            """
Please find attached invoice \(number) for the first 50% deposit\(projectPhrase). The amount due is \(amountText), payable \(duePhrase). Work can begin once payment is received.
"""
    } else if stage.contains(
        "final 50"
    ) || stage.contains(
        "final balance"
    ) {
        subject =
            "Invoice \(number) – Final 50% balance"

        paragraph =
            """
Please find attached invoice \(number) for the final 50% balance\(projectPhrase). The amount due is \(amountText), payable \(duePhrase).
"""
    } else {
        subject =
            "Invoice \(number)\(subjectSuffix)"

        paragraph =
            """
Please find attached invoice \(number)\(projectPhrase). The amount due is \(amountText), payable \(duePhrase).
"""
    }

    return """
Subject: \(subject)

Hi \(greeting),

\(paragraph)

Kind regards,
Your name
"""
}


@discardableResult
private func writeInvoiceEmailDraft(
    for draft: InvoiceDraft,
    amountPaid: Double,
    beside pdfURL: URL
) throws -> URL {
    let filename =
        pdfURL
            .deletingPathExtension()
            .lastPathComponent

    let emailURL =
        pdfURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                "\(filename) - Email.txt"
            )

    try invoiceEmailDraftText(
        for: draft,
        amountPaid: amountPaid
    )
    .write(
        to: emailURL,
        atomically: true,
        encoding: .utf8
    )

    return emailURL
}


struct RecentDraft: Identifiable {
    let id: UUID
    let label: String
    let updatedAt: Date
    let documentNumber: String
    let documentType: String
    let status: String
    let clientName: String
    let dueDate: Date
    let total: Double
    let currency: String
}

// MARK: - Core Data

final class PersistenceController {
    var container: NSPersistentContainer
    let storeURL: URL
    private(set) var startupWarning: String?

    init() {
        let fileManager = FileManager.default
        let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        let root = support.appendingPathComponent("INV", isDirectory: true)
        let dataDirectory = root.appendingPathComponent("data", isDirectory: true)

        try? fileManager.createDirectory(
            at: dataDirectory,
            withIntermediateDirectories: true
        )

        storeURL = dataDirectory.appendingPathComponent("inv.sqlite3")

        container = NSPersistentContainer(
            name: "INV",
            managedObjectModel: Self.makeModel()
        )

        let description = NSPersistentStoreDescription(url: storeURL)
        description.type = NSSQLiteStoreType
        description.shouldAddStoreAsynchronously = false
        description.setOption(
            true as NSNumber,
            forKey: NSMigratePersistentStoresAutomaticallyOption
        )
        description.setOption(
            true as NSNumber,
            forKey: NSInferMappingModelAutomaticallyOption
        )

        container.persistentStoreDescriptions = [description]

        var loadError: Error?
        container.loadPersistentStores { _, error in
            loadError = error
        }

        if let loadError {
            startupWarning =
                "The invoice database could not be opened. INV is running in recovery mode: \(loadError.localizedDescription)"

            let fallback = NSPersistentContainer(
                name: "INV-Recovery",
                managedObjectModel: Self.makeModel()
            )
            let fallbackDescription = NSPersistentStoreDescription()
            fallbackDescription.type = NSInMemoryStoreType
            fallbackDescription.shouldAddStoreAsynchronously = false
            fallback.persistentStoreDescriptions = [fallbackDescription]

            var fallbackError: Error?
            fallback.loadPersistentStores { _, error in
                fallbackError = error
            }

            if fallbackError == nil {
                container = fallback
            }
        }

        container.viewContext.mergePolicy =
            NSMergeByPropertyObjectTrumpMergePolicy
    }

    var context: NSManagedObjectContext {
        container.viewContext
    }

    func backup() throws -> URL {
        if context.hasChanges {
            try context.save()
        }

        let fileManager = FileManager.default
        let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        let backupDirectory = support
            .appendingPathComponent("INV/backups", isDirectory: true)
            .appendingPathComponent(
                timestampFormatter.string(from: Date()),
                isDirectory: true
            )

        try fileManager.createDirectory(
            at: backupDirectory,
            withIntermediateDirectories: true
        )

        var result: Result<URL, Error>!

        container.persistentStoreCoordinator.performAndWait {
            do {
                for suffix in ["", "-wal", "-shm"] {
                    let source = URL(fileURLWithPath: storeURL.path + suffix)

                    guard fileManager.fileExists(atPath: source.path) else {
                        continue
                    }

                    let destination = backupDirectory
                        .appendingPathComponent(source.lastPathComponent)

                    try fileManager.copyItem(
                        at: source,
                        to: destination
                    )
                }

                result = .success(backupDirectory)
            } catch {
                result = .failure(error)
            }
        }

        return try result.get()
    }

    private static func makeModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        func entity(
            _ name: String,
            _ fields: [(String, NSAttributeType)]
        ) -> NSEntityDescription {
            let entity = NSEntityDescription()
            entity.name = name
            entity.managedObjectClassName =
                NSStringFromClass(NSManagedObject.self)

            var properties: [NSPropertyDescription] = []

            for field in fields {
                let attribute = NSAttributeDescription()
                attribute.name = field.0
                attribute.attributeType = field.1
                attribute.isOptional = true
                properties.append(attribute)
            }

            entity.properties = properties
            return entity
        }

        let settings = entity("Setting", [
            ("key", .stringAttributeType),
            ("value", .stringAttributeType)
        ])

        let clients = entity("Client", [
            ("id", .UUIDAttributeType),
            ("legalName", .stringAttributeType),
            ("contactName", .stringAttributeType),
            ("billingAddress", .stringAttributeType),
            ("createdAt", .dateAttributeType),
            ("updatedAt", .dateAttributeType)
        ])

        let projects = entity("Project", [
            ("id", .UUIDAttributeType),
            ("clientName", .stringAttributeType),
            ("name", .stringAttributeType),
            ("projectDescription", .stringAttributeType),
            ("createdAt", .dateAttributeType),
            ("updatedAt", .dateAttributeType)
        ])

        let invoices = entity("Invoice", [
            ("id", .UUIDAttributeType),
            ("documentType", .stringAttributeType),
            ("documentNumber", .stringAttributeType),
            ("status", .stringAttributeType),
            ("issueDate", .dateAttributeType),
            ("dueDate", .dateAttributeType),
            ("dueDateMode", .stringAttributeType),
            ("finalDueDate", .dateAttributeType),
            ("finalDueDateMode", .stringAttributeType),
            ("paymentPlan", .stringAttributeType),
            ("paymentStage", .stringAttributeType),
            ("senderName", .stringAttributeType),
            ("senderAddress", .stringAttributeType),
            ("clientName", .stringAttributeType),
            ("clientAddress", .stringAttributeType),
            ("clientContact", .stringAttributeType),
            ("projectName", .stringAttributeType),
            ("projectDescription", .stringAttributeType),
            ("currency", .stringAttributeType),
            ("taxRate", .doubleAttributeType),
            ("paymentTerms", .stringAttributeType),
            ("bankingDetails", .stringAttributeType),
            ("total", .doubleAttributeType),
            ("createdAt", .dateAttributeType),
            ("updatedAt", .dateAttributeType),
            ("issuedAt", .dateAttributeType)
        ])

        let invoiceLines = entity("InvoiceLine", [
            ("id", .UUIDAttributeType),
            ("invoiceId", .UUIDAttributeType),
            ("itemDescription", .stringAttributeType),
            ("quantity", .doubleAttributeType),
            ("rate", .doubleAttributeType),
            ("sortOrder", .integer64AttributeType)
        ])

        let payments = entity("Payment", [
            ("id", .UUIDAttributeType),
            ("invoiceId", .UUIDAttributeType),
            ("paymentDate", .dateAttributeType),
            ("paymentType", .stringAttributeType),
            ("amount", .doubleAttributeType),
            ("method", .stringAttributeType),
            ("reference", .stringAttributeType),
            ("notes", .stringAttributeType),
            ("createdAt", .dateAttributeType)
        ])

        let expenses = entity("Expense", [
            ("id", .UUIDAttributeType),
            ("expenseDate", .dateAttributeType),
            ("supplier", .stringAttributeType),
            ("category", .stringAttributeType),
            ("amount", .doubleAttributeType),
            ("currency", .stringAttributeType),
            ("notes", .stringAttributeType),
            ("createdAt", .dateAttributeType)
        ])

        let auditEvents = entity("AuditEvent", [
            ("id", .UUIDAttributeType),
            ("timestamp", .dateAttributeType),
            ("action", .stringAttributeType),
            ("entityId", .stringAttributeType),
            ("details", .stringAttributeType)
        ])

        model.entities = [
            settings,
            clients,
            projects,
            invoices,
            invoiceLines,
            payments,
            expenses,
            auditEvents
        ]

        return model
    }
}

// MARK: - Store

@MainActor
final class InvoiceStore: ObservableObject {
    @Published var current = InvoiceDraft.blank()
    @Published var amountPaid = 0.0
    @Published var recentDrafts: [RecentDraft] = []
    @Published var allDrafts: [RecentDraft] = []
    @Published var savedClients: [SavedClient] = []
    @Published var showDraftBrowser = false
    @Published var showPaymentSheet = false
    @Published var showIssueConfirmation = false
    @Published var showBooks = false
    @Published var message = "Ready"
    @Published private(set) var hasUnsavedChanges = false

    private let persistence: PersistenceController
    private var lastSavedDraft: InvoiceDraft?
    private var autosaveTask: DispatchWorkItem?

    init() {
        persistence = PersistenceController()
        loadClients()
        loadDrafts()
        newDocument()
        syncAccountingLedger()

        if let warning = persistence.startupWarning {
            message = warning
        }
    }

    private var context: NSManagedObjectContext {
        persistence.context
    }

    func matchingClients(
        _ query: String
    ) -> [SavedClient] {
        let trimmed =
            query.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        guard !trimmed.isEmpty else {
            return Array(
                savedClients.prefix(12)
            )
        }

        let lowered =
            trimmed.lowercased()

        return Array(
            savedClients.filter {
                client in

                client.name
                    .lowercased()
                    .contains(lowered)
                || client.contactName
                    .lowercased()
                    .contains(lowered)
                || client.billingAddress
                    .lowercased()
                    .contains(lowered)
            }
            .prefix(12)
        )
    }


    func applyClient(
        _ client: SavedClient
    ) {
current.clientName =
            client.name

        current.clientContact =
            client.contactName

        current.clientAddress =
            client.billingAddress

        message =
            "\(client.name) loaded"
    }


    func autofillClientIfKnown(
        _ name: String
    ) {
let trimmed =
            name.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        guard !trimmed.isEmpty,
              let client =
                savedClients.first(
                    where: {
                        $0.name
                            .caseInsensitiveCompare(
                                trimmed
                            )
                            == .orderedSame
                    }
                )
        else {
            return
        }

        current.clientName =
            client.name

        current.clientContact =
            client.contactName

        current.clientAddress =
            client.billingAddress
    }


    private func loadClients() {
        let objects =
            fetch("Client")

        savedClients =
            objects.compactMap {
                object in

                let name =
                    object.value(
                        forKey: "legalName"
                    ) as? String ?? ""

                guard !name
                    .trimmingCharacters(
                        in:
                            .whitespacesAndNewlines
                    )
                    .isEmpty
                else {
                    return nil
                }

                return SavedClient(
                    id:
                        object.value(
                            forKey: "id"
                        ) as? UUID
                        ?? UUID(),
                    name:
                        name,
                    contactName:
                        object.value(
                            forKey: "contactName"
                        ) as? String ?? "",
                    billingAddress:
                        object.value(
                            forKey:
                                "billingAddress"
                        ) as? String ?? ""
                )
            }
            .sorted {
                $0.name
                    .localizedCaseInsensitiveCompare(
                        $1.name
                    )
                    == .orderedAscending
            }
    }


    private func rememberCurrentClient() {
        let name =
            current.clientName
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )

        guard !name.isEmpty else {
            return
        }

        upsertClient()
        saveContext()
        loadClients()
    }


    func newDocument(type: String = "INVOICE") {
        flushAutosave()
        current = .blank()
        current.documentType = type
        amountPaid = 0
        lastSavedDraft = current
        hasUnsavedChanges = false
        message = "New invoice"
    }

    func importInvoice() {
        flushAutosave()

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .image]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import Invoice"

        guard panel.runModal() == .OK,
              let url = panel.url
        else {
            return
        }

        message = "Reading \(url.lastPathComponent)…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try InvoiceImporter.draft(from: url)
            }

            DispatchQueue.main.async {
                guard let self else { return }

                switch result {
                case .success(let imported):
                    self.current = imported
                    self.amountPaid = 0
                    self.lastSavedDraft = nil
                    self.documentDidChange()
                    self.message = imported.total > 0
                        ? "Invoice converted. Review the imported fields before issuing."
                        : "Invoice text imported, but the total needs your review."

                case .failure(let error):
                    self.message = "Import failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func documentDidChange() {
        let changed = current != lastSavedDraft
        hasUnsavedChanges = changed

        autosaveTask?.cancel()

        guard changed,
              !current.isIssued,
              currentHasMeaningfulContent
        else {
            return
        }

        let task = DispatchWorkItem { [weak self] in
            guard let self,
                  self.current != self.lastSavedDraft,
                  !self.current.isIssued
            else {
                return
            }

            self.writeCurrent(action: "Draft autosaved")
        }

        autosaveTask = task
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 1.2,
            execute: task
        )
    }

    func flushAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil

        guard hasUnsavedChanges,
              !current.isIssued,
              currentHasMeaningfulContent
        else {
            return
        }

        writeCurrent(action: "Draft autosaved")
    }

    private var currentHasMeaningfulContent: Bool {
        let text = [
            current.clientName,
            current.clientAddress,
            current.clientContact,
            current.projectName,
            current.projectDescription,
            current.paymentTerms
        ]

        return text.contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } || current.lines.contains {
            !$0.itemDescription
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty || $0.rate != 0 || $0.quantity != 1
        }
    }

    func addLine() {
        current.lines.append(LineDraft())
    }

    func removeLine(_ id: UUID) {
        guard current.lines.count > 1 else { return }
        current.lines.removeAll { $0.id == id }
    }

    func convertCurrentQuoteToInvoice() {
        guard current.documentType == "QUOTE" else {
            message =
                "Open a quote before converting it"
            return
        }

        let quote = current
        let quoteReference =
            quote.documentNumber.isEmpty
            ? "draft quote"
            : quote.documentNumber

        if !quote.isIssued {
            writeCurrent(
                action:
                    "Quote saved before conversion"
            )
        }

        let defaults = InvoiceDraft.blank()
        var invoice = defaults

        invoice.id = UUID()
        invoice.documentType = "INVOICE"
        invoice.documentNumber = ""
        invoice.status = "Draft"

        invoice.issueDate = Date()
        invoice.dueDate =
            Calendar.current.date(
                byAdding: .day,
                value: 7,
                to: invoice.issueDate
            ) ?? invoice.issueDate

        invoice.dueDateMode =
            "Specific date"

        invoice.finalDueDate =
            Calendar.current.date(
                byAdding: .day,
                value: 21,
                to: invoice.issueDate
            ) ?? invoice.issueDate

        invoice.finalDueDateMode =
            "On delivery"

        invoice.paymentPlan =
            "Single"

        invoice.senderName =
            quote.senderName

        invoice.senderAddress =
            quote.senderAddress

        invoice.clientName =
            quote.clientName

        invoice.clientAddress =
            quote.clientAddress

        invoice.clientContact =
            quote.clientContact

        invoice.projectName =
            quote.projectName

        invoice.projectDescription =
            quote.projectDescription

        invoice.lines = quote.lines.map {
            line in

            LineDraft(
                id: UUID(),
                itemDescription:
                    line.itemDescription,
                quantity:
                    line.quantity,
                rate:
                    line.rate
            )
        }

        invoice.currency =
            quote.currency

        invoice.taxRate =
            AccountingRepository.shared
                .profile
                .vatRegistered
            ? quote.taxRate
            : 0

        invoice.paymentStage =
            quote.paymentStage

        invoice.paymentTerms =
            quote.paymentTerms

        /*
         Quotes never expose account details.
         Converted invoices use the standard saved
         invoice banking information.
        */
        invoice.bankingDetails =
            defaults.bankingDetails

        current = invoice
        amountPaid = 0

        writeCurrent(
            action:
                "Invoice created from \(quoteReference)"
        )

        message =
            "Invoice draft created from \(quoteReference)"
    }


    func saveDraft() {
        if current.isIssued,
           current.documentType == "INVOICE" {
            guard current.total + 0.005 >= amountPaid else {
                message = "The revised total cannot be less than the amount already paid"
                return
            }

            current.status = amountPaid + 0.005 >= current.total
                ? "Paid"
                : amountPaid > 0
                    ? "Partially Paid"
                    : "Issued"

            writeCurrent(action: "Issued invoice updated")

            do {
                try AccountingRepository.shared.replaceInvoice(
                    invoiceId: current.id.uuidString,
                    invoiceNumber: current.documentNumber,
                    clientName: current.clientName,
                    issueDate: current.issueDate,
                    dueDate: current.dueDate,
                    total: current.total,
                    tax: current.tax
                )
                message = "\(current.documentNumber) and Books updated"
            } catch {
                message = "Invoice saved, but Books update failed: \(error.localizedDescription)"
            }
            return
        }

        let action =
            current.isIssued
            ? "Issued invoice updated"
            : "Draft saved"

        writeCurrent(
            action: action
        )
    }

    func issueCurrent() {
        guard current.paymentPlan != "50/50" else {
            message = "50/50 invoices are issued together. Choose Export to create both invoices."
            return
        }

        guard !current.clientName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty else {
            message = "Add a client before issuing"
            return
        }

        guard current.total > 0 else {
            message = "The invoice total must be greater than zero"
            return
        }

        guard current.lines.allSatisfy({ line in
            line.quantity > 0 && line.rate >= 0 &&
                !line.itemDescription
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
        }) else {
            message = "Every line needs a description, a positive quantity and a non-negative rate"
            return
        }

        let normalisedCurrency = current.currency
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        guard normalisedCurrency.count == 3,
              normalisedCurrency.allSatisfy({ $0.isLetter })
        else {
            message = "Use a three-letter currency code such as ZAR or USD"
            return
        }

        guard current.taxRate >= 0 && current.taxRate <= 100 else {
            message = "VAT must be between 0% and 100%"
            return
        }

        if current.dueDateMode == "Specific date",
           Calendar.current.startOfDay(for: current.dueDate) <
            Calendar.current.startOfDay(for: current.issueDate) {
            message = "The due date cannot be before the issue date"
            return
        }

        current.currency = normalisedCurrency

        if current.documentNumber.isEmpty {
            current.documentNumber = nextDocumentNumber(
                for: current.documentType
            )
        }

        if current.documentType == "INVOICE" {
            let profile = AccountingRepository.shared.profile

            if profile.vatRegistered &&
                profile.vatNumber
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    .isEmpty {
                message = "Add the VAT number in Books before issuing"
                return
            }

            if !profile.vatRegistered {
                current.taxRate = 0
            }
        }

        current.status = "Issued"
        writeCurrent(action: "\(current.documentType.capitalized) issued")

        if current.documentType == "INVOICE" {
            do {
                try AccountingRepository.shared.postInvoice(
                    invoiceId: current.id.uuidString,
                    invoiceNumber: current.documentNumber,
                    clientName: current.clientName,
                    issueDate: current.issueDate,
                    dueDate: current.dueDate,
                    total: current.total,
                    tax: current.tax
                )
            } catch {
                message = "Issued, but Books sync failed: \(error.localizedDescription)"
                return
            }
        }

        message = "\(current.documentNumber) issued"
    }

    func open(_ id: UUID) {
        flushAutosave()

        guard let invoice = invoiceObject(id) else { return }

        func string(_ key: String) -> String {
            invoice.value(forKey: key) as? String ?? ""
        }

        var draft = InvoiceDraft.blank()
        draft.id = id
        draft.documentType = string("documentType")
        draft.documentNumber = string("documentNumber")
        draft.status = string("status")
        draft.issueDate = invoice.value(forKey: "issueDate") as? Date ?? Date()
        draft.dueDate =
            invoice.value(
                forKey: "dueDate"
            ) as? Date ?? Date()

        let savedDueMode =
            string("dueDateMode")

        draft.dueDateMode =
            savedDueMode.isEmpty
            ? "Specific date"
            : savedDueMode

        draft.finalDueDate =
            invoice.value(
                forKey: "finalDueDate"
            ) as? Date
            ?? Calendar.current.date(
                byAdding: .day,
                value: 21,
                to: draft.issueDate
            )
            ?? draft.issueDate

        let savedFinalMode =
            string("finalDueDateMode")

        draft.finalDueDateMode =
            savedFinalMode.isEmpty
            ? "On delivery"
            : savedFinalMode

        let savedPaymentPlan =
            string("paymentPlan")

        draft.paymentPlan =
            savedPaymentPlan.isEmpty
            ? "Single"
            : savedPaymentPlan

        draft.paymentStage =
            string("paymentStage")
        draft.senderName = string("senderName")
        draft.senderAddress = string("senderAddress")
        draft.clientName = string("clientName")
        draft.clientAddress = string("clientAddress")
        draft.clientContact = string("clientContact")
        draft.projectName = string("projectName")
        draft.projectDescription = string("projectDescription")
        draft.currency = string("currency").isEmpty
            ? "ZAR"
            : string("currency")
        draft.taxRate =
            invoice.value(forKey: "taxRate") as? Double ?? 0
        draft.paymentTerms = string("paymentTerms")
        let savedBankingDetails =
            string("bankingDetails")
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )

        let legacyBankingDetails =
            invLegacyBankingDetails
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )

        draft.bankingDetails =
            savedBankingDetails.isEmpty
            || savedBankingDetails
                == legacyBankingDetails
            ? invDefaultBankingDetails
            : savedBankingDetails

        let lineObjects = fetch(
            "InvoiceLine",
            predicate: NSPredicate(
                format: "invoiceId == %@",
                id as NSUUID
            ),
            sort: [
                NSSortDescriptor(
                    key: "sortOrder",
                    ascending: true
                )
            ]
        )

        draft.lines = lineObjects.map { object in
            LineDraft(
                id: object.value(forKey: "id") as? UUID ?? UUID(),
                itemDescription:
                    object.value(forKey: "itemDescription") as? String ?? "",
                quantity:
                    object.value(forKey: "quantity") as? Double ?? 1,
                rate:
                    object.value(forKey: "rate") as? Double ?? 0
            )
        }

        if draft.lines.isEmpty {
            draft.lines = [LineDraft()]
        }

        current = draft
        amountPaid = paymentsTotal(for: id)
        lastSavedDraft = current
        hasUnsavedChanges = false
        message = draft.documentNumber.isEmpty
            ? "Draft opened"
            : draft.isIssued
                ? "\(draft.documentNumber) opened for editing"
                : "\(draft.documentNumber) opened"
    }

    func recordPayment(
        date: Date,
        amount: Double,
        type: String,
        method: String,
        reference: String,
        notes: String
    ) {
        guard current.isIssued else {
            message = "Issue the invoice before recording payment"
            return
        }

        guard amount > 0 else {
            message = "Payment amount must be greater than zero"
            return
        }

        let remaining = max(current.total - paymentsTotal(for: current.id), 0)

        guard amount <= remaining + 0.005 else {
            message = "Payment exceeds the remaining balance of \(money(remaining, currency: current.currency))"
            return
        }

        let payment = NSEntityDescription.insertNewObject(
            forEntityName: "Payment",
            into: context
        )

        let paymentId = UUID()
        payment.setValue(paymentId, forKey: "id")
        payment.setValue(current.id, forKey: "invoiceId")
        payment.setValue(date, forKey: "paymentDate")
        payment.setValue(type, forKey: "paymentType")
        payment.setValue(amount, forKey: "amount")
        payment.setValue(method, forKey: "method")
        payment.setValue(reference, forKey: "reference")
        payment.setValue(notes, forKey: "notes")
        payment.setValue(Date(), forKey: "createdAt")

        let paid = paymentsTotal(for: current.id)
        let newStatus = paid + 0.005 >= current.total
            ? "Paid"
            : "Partially Paid"

        invoiceObject(current.id)?
            .setValue(newStatus, forKey: "status")

        current.status = newStatus
        amountPaid = paid

        addAudit(
            action: "Payment recorded",
            entityId: current.id.uuidString,
            details: "\(money(amount, currency: current.currency)) via \(method)"
        )

        saveContext()
        lastSavedDraft = current
        hasUnsavedChanges = false

        do {
            try AccountingRepository.shared.postPayment(
                paymentId: paymentId.uuidString,
                invoiceId: current.id.uuidString,
                invoiceNumber: current.documentNumber,
                date: date,
                amount: amount,
                reference: reference
            )
        } catch {
            message = "Payment saved, but Books sync failed: \(error.localizedDescription)"
            return
        }

        message = "Payment recorded"
    }

    func exportPDF() {
        rememberCurrentClient()

        if current.paymentPlan == "50/50" {
            exportFiftyFiftyPair()
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]

        let suggestedName = current.documentNumber.isEmpty
            ? "INV Draft.pdf"
            : "\(current.documentNumber).pdf"

        panel.nameFieldStringValue = suggestedName

        guard panel.runModal() == .OK,
              let url = panel.url else {
            return
        }

        do {
            try PDFExporter.export(
                current,
                amountPaid: amountPaid,
                to: url
            )

            let emailURL =
                try writeInvoiceEmailDraft(
                    for: current,
                    amountPaid: amountPaid,
                    beside: url
                )

            NSWorkspace.shared
                .activateFileViewerSelecting(
                    [
                        url,
                        emailURL
                    ]
                )
            message = "PDF and email draft exported"
        } catch {
            message = "PDF export failed: \(error.localizedDescription)"
        }
    }

    func exportFiftyFiftyPair(
        to destinationFolder: URL? = nil
    ) {
        rememberCurrentClient()

        guard current.documentType == "INVOICE" else {
            message =
                "50/50 export is available for invoices"
            return
        }

        guard current.total > 0 else {
            message =
                "The invoice total must be greater than zero"
            return
        }

        guard !current.clientName
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            .isEmpty else {
            message =
                "Add a client before exporting"
            return
        }

        let replacingIssuedInvoice = current.isIssued

        guard !replacingIssuedInvoice || amountPaid <= 0.005 else {
            message = "A paid invoice cannot be converted to 50/50. Reverse its payments first."
            return
        }

        let profile = AccountingRepository.shared.profile

        guard !profile.vatRegistered ||
                !profile.vatNumber
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
        else {
            message = "Add the VAT number in Books before issuing"
            return
        }

        if !profile.vatRegistered {
            current.taxRate = 0
        }

        current.paymentPlan = "50/50"

        let baseNumber =
            current.documentNumber.isEmpty
            ? nextDocumentNumber(for: "INVOICE")
            : invoiceBaseNumber(current.documentNumber)

        let folder: URL

        if let destinationFolder {
            folder = destinationFolder
        } else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true
            panel.prompt = "Export Pair"

            guard panel.runModal() == .OK,
                  let selectedFolder = panel.url
            else {
                return
            }

            folder = selectedFolder
        }

        var first = current
        first.documentNumber =
            "\(baseNumber)-1"
        first.status = "Issued"
        first.paymentPlan = "Single"
        first.paymentStage =
            "First 50% deposit"
        first.dueDateMode =
            current.dueDateMode
        first.dueDate =
            current.dueDate

        first.lines = current.lines.map {
            line in

            LineDraft(
                id: UUID(),
                itemDescription:
                    line.itemDescription,
                quantity:
                    line.quantity,
                rate:
                    line.rate * 0.5
            )
        }

        let firstDue =
            invoiceDueDateText(
                mode: current.dueDateMode,
                date: current.dueDate
            )

        let firstOpening: String

        if current.dueDateMode
            == "At project start" {
            firstOpening =
                """
The first 50% deposit is due at the start of the project. Work begins once payment is received.
"""
        } else if current.dueDateMode
            == "On delivery" {
            firstOpening =
                """
The first 50% deposit is due on delivery. Work begins once payment is received.
"""
        } else {
            firstOpening =
                """
The first 50% deposit is due \(firstDue). Work begins once payment is received.
"""
        }

        first.paymentTerms =
            """
\(firstOpening)

This invoice represents the first 50% of the total project fee of \(money(current.total, currency: current.currency)). The amount due on this invoice is \(money(first.total, currency: first.currency)). The remaining 50% will be invoiced separately as \(baseNumber)-2.

\(current.paymentTerms)
"""
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        var final = current
        final.id = UUID()
        final.documentNumber =
            "\(baseNumber)-2"
        final.status = "Issued"
        final.paymentPlan = "Single"
        final.paymentStage =
            "Final 50% balance"
        final.dueDateMode =
            current.finalDueDateMode
        final.dueDate =
            current.finalDueDate

        final.lines = current.lines.map {
            line in

            LineDraft(
                id: UUID(),
                itemDescription:
                    line.itemDescription,
                quantity:
                    line.quantity,
                rate:
                    line.rate * 0.5
            )
        }

        let finalDue =
            invoiceDueDateText(
                mode:
                    current.finalDueDateMode,
                date:
                    current.finalDueDate
            )

        let finalOpening =
            current.finalDueDateMode
                == "On delivery"
            ? """
The final 50% balance is due on delivery, before release of the final production files.
"""
            : """
The final 50% balance is due \(finalDue), before release of the final production files.
"""

        final.paymentTerms =
            """
\(finalOpening)

This invoice represents the final 50% of the total project fee of \(money(current.total, currency: current.currency)). The amount due on this invoice is \(money(final.total, currency: final.currency)). The first 50% was invoiced separately as \(baseNumber)-1.

\(current.paymentTerms)
"""
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        let firstURL =
            folder.appendingPathComponent(
                "\(first.documentNumber).pdf"
            )

        let finalURL =
            folder.appendingPathComponent(
                "\(final.documentNumber).pdf"
            )

        do {
            try PDFExporter.export(
                first,
                amountPaid: 0,
                to: firstURL
            )

            try PDFExporter.export(
                final,
                amountPaid: 0,
                to: finalURL
            )

            let firstEmailURL =
                try writeInvoiceEmailDraft(
                    for: first,
                    amountPaid: 0,
                    beside: firstURL
                )

            let finalEmailURL =
                try writeInvoiceEmailDraft(
                    for: final,
                    amountPaid: 0,
                    beside: finalURL
                )

            current = first
            writeCurrent(
                action: "First 50% invoice issued"
            )

            if replacingIssuedInvoice {
                try AccountingRepository.shared.replaceInvoice(
                    invoiceId: first.id.uuidString,
                    invoiceNumber: first.documentNumber,
                    clientName: first.clientName,
                    issueDate: first.issueDate,
                    dueDate: first.dueDate,
                    total: first.total,
                    tax: first.tax
                )
            } else {
                try AccountingRepository.shared.postInvoice(
                    invoiceId: first.id.uuidString,
                    invoiceNumber: first.documentNumber,
                    clientName: first.clientName,
                    issueDate: first.issueDate,
                    dueDate: first.dueDate,
                    total: first.total,
                    tax: first.tax
                )
            }

            current = final
            writeCurrent(
                action: "Final 50% invoice issued"
            )

            try AccountingRepository.shared.postInvoice(
                invoiceId: final.id.uuidString,
                invoiceNumber: final.documentNumber,
                clientName: final.clientName,
                issueDate: final.issueDate,
                dueDate: final.dueDate,
                total: final.total,
                tax: final.tax
            )

            open(first.id)

            NSWorkspace.shared
                .activateFileViewerSelecting(
                    [
                        firstURL,
                        firstEmailURL,
                        finalURL,
                        finalEmailURL
                    ]
                )

            message =
                "\(first.documentNumber) and \(final.documentNumber) PDFs and email drafts exported"
        } catch {
            message =
                "50/50 export failed: \(error.localizedDescription)"
        }
    }


    func backupNow() {
        do {
            let url = try persistence.backup()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            message = "Backup created"
        } catch {
            message = "Backup failed: \(error.localizedDescription)"
        }
    }

    func exportAccountantData() {
        do {
            let fileManager = FileManager.default
            let documents = fileManager.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first!

            let folder = documents
                .appendingPathComponent("INV Exports", isDirectory: true)
                .appendingPathComponent(
                    timestampFormatter.string(from: Date()),
                    isDirectory: true
                )

            try fileManager.createDirectory(
                at: folder,
                withIntermediateDirectories: true
            )

            let invoiceObjects = fetch(
                "Invoice",
                sort: [
                    NSSortDescriptor(
                        key: "issueDate",
                        ascending: true
                    )
                ]
            )

            var invoiceCSV = """
document_number,document_type,status,client,project,issue_date,due_date,currency,total

"""

            for invoice in invoiceObjects {
                let row = [
                    invoice.value(forKey: "documentNumber") as? String ?? "",
                    invoice.value(forKey: "documentType") as? String ?? "",
                    invoice.value(forKey: "status") as? String ?? "",
                    invoice.value(forKey: "clientName") as? String ?? "",
                    invoice.value(forKey: "projectName") as? String ?? "",
                    csvDateFormatter.string(
                        from: invoice.value(forKey: "issueDate") as? Date
                            ?? Date()
                    ),
                    csvDateFormatter.string(
                        from: invoice.value(forKey: "dueDate") as? Date
                            ?? Date()
                    ),
                    invoice.value(forKey: "currency") as? String ?? "",
                    String(
                        format: "%.2f",
                        invoice.value(forKey: "total") as? Double ?? 0
                    )
                ]

                invoiceCSV += row.map(csvEscape).joined(separator: ",") + "\n"
            }

            let paymentObjects = fetch(
                "Payment",
                sort: [
                    NSSortDescriptor(
                        key: "paymentDate",
                        ascending: true
                    )
                ]
            )

            var paymentCSV = """
payment_id,invoice_id,payment_date,type,amount,method,reference,notes

"""

            for payment in paymentObjects {
                let row = [
                    (payment.value(forKey: "id") as? UUID)?
                        .uuidString ?? "",
                    (payment.value(forKey: "invoiceId") as? UUID)?
                        .uuidString ?? "",
                    csvDateFormatter.string(
                        from: payment.value(forKey: "paymentDate") as? Date
                            ?? Date()
                    ),
                    payment.value(forKey: "paymentType") as? String ?? "",
                    String(
                        format: "%.2f",
                        payment.value(forKey: "amount") as? Double ?? 0
                    ),
                    payment.value(forKey: "method") as? String ?? "",
                    payment.value(forKey: "reference") as? String ?? "",
                    payment.value(forKey: "notes") as? String ?? ""
                ]

                paymentCSV += row.map(csvEscape).joined(separator: ",") + "\n"
            }

            try invoiceCSV.write(
                to: folder.appendingPathComponent("Invoices.csv"),
                atomically: true,
                encoding: .utf8
            )

            try paymentCSV.write(
                to: folder.appendingPathComponent("Payments.csv"),
                atomically: true,
                encoding: .utf8
            )

            try AccountingRepository.shared
                .exportAccountantPack(to: folder)

            NSWorkspace.shared.activateFileViewerSelecting([folder])
            message = "Accountant export created"
        } catch {
            message = "Export failed: \(error.localizedDescription)"
        }
    }

    func loadDrafts() {
        let objects = fetch(
            "Invoice",
            sort: [
                NSSortDescriptor(
                    key: "updatedAt",
                    ascending: false
                )
            ]
        )

        let drafts = objects.compactMap { object -> RecentDraft? in
            guard let id = object.value(forKey: "id") as? UUID else {
                return nil
            }

            let client =
                object.value(forKey: "clientName") as? String ?? ""
            let project =
                object.value(forKey: "projectName") as? String ?? ""
            let updated =
                object.value(forKey: "updatedAt") as? Date ?? Date()
            let status =
                object.value(forKey: "status") as? String ?? "Draft"
            let documentNumber =
                object.value(forKey: "documentNumber") as? String ?? ""
            let documentType =
                object.value(forKey: "documentType") as? String ?? "INVOICE"
            let dueDate =
                object.value(forKey: "dueDate") as? Date ?? Date()
            let total =
                object.value(forKey: "total") as? Double ?? 0
            let currency =
                object.value(forKey: "currency") as? String ?? "ZAR"

            let parts = [client, project].filter {
                !$0.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
            }

            let label = parts.isEmpty
                ? "Untitled Draft"
                : parts.joined(separator: " — ")

            return RecentDraft(
                id: id,
                label: label,
                updatedAt: updated,
                documentNumber: documentNumber,
                documentType: documentType,
                status: status,
                clientName: client,
                dueDate: dueDate,
                total: total,
                currency: currency
            )
        }

        allDrafts = drafts
        recentDrafts = Array(
            drafts.filter { $0.status == "Draft" }.prefix(5)
        )
    }

    private func syncAccountingLedger() {
        var failures = 0

        let invoices = fetch(
            "Invoice",
            predicate: NSPredicate(
                format:
                    "status != %@ AND documentType == %@",
                "Draft",
                "INVOICE"
            ),
            sort: [
                NSSortDescriptor(
                    key: "issueDate",
                    ascending: true
                )
            ]
        )

        for invoice in invoices {
            guard let id =
                invoice.value(forKey: "id") as? UUID
            else {
                continue
            }

            let total =
                invoice.value(forKey: "total")
                    as? Double ?? 0

            let rate =
                invoice.value(forKey: "taxRate")
                    as? Double ?? 0

            let tax =
                rate > 0
                ? total - total / (1 + rate / 100)
                : 0

            do {
                try AccountingRepository.shared.postInvoice(
                    invoiceId: id.uuidString,
                    invoiceNumber:
                        invoice.value(
                            forKey: "documentNumber"
                        ) as? String ?? "",
                    clientName:
                        invoice.value(
                            forKey: "clientName"
                        ) as? String ?? "",
                    issueDate:
                        invoice.value(
                            forKey: "issueDate"
                        ) as? Date ?? Date(),
                    dueDate:
                        invoice.value(
                            forKey: "dueDate"
                        ) as? Date ?? Date(),
                    total: total,
                    tax: tax
                )
            } catch {
                failures += 1
            }
        }

        let payments = fetch(
            "Payment",
            sort: [
                NSSortDescriptor(
                    key: "paymentDate",
                    ascending: true
                )
            ]
        )

        for payment in payments {
            guard
                let paymentId =
                    payment.value(forKey: "id")
                        as? UUID,
                let invoiceId =
                    payment.value(forKey: "invoiceId")
                        as? UUID,
                let invoice =
                    invoiceObject(invoiceId)
            else {
                continue
            }

            do {
                try AccountingRepository.shared.postPayment(
                    paymentId: paymentId.uuidString,
                    invoiceId: invoiceId.uuidString,
                    invoiceNumber:
                        invoice.value(
                            forKey: "documentNumber"
                        ) as? String ?? "",
                    date:
                        payment.value(
                            forKey: "paymentDate"
                        ) as? Date ?? Date(),
                    amount:
                        payment.value(
                            forKey: "amount"
                        ) as? Double ?? 0,
                    reference:
                        payment.value(
                            forKey: "reference"
                        ) as? String ?? ""
                )
            } catch {
                failures += 1
            }
        }

        if failures > 0 {
            message = "Books could not reconcile \(failures) item(s). Open Books for details."
        }
    }


    private func writeCurrent(action: String) {
        let existing = invoiceObject(current.id)

        let invoice = existing
            ?? NSEntityDescription.insertNewObject(
                forEntityName: "Invoice",
                into: context
            )

        if existing == nil {
            invoice.setValue(Date(), forKey: "createdAt")
        }

        invoice.setValue(current.id, forKey: "id")
        invoice.setValue(current.documentType, forKey: "documentType")
        invoice.setValue(current.documentNumber, forKey: "documentNumber")
        invoice.setValue(current.status, forKey: "status")
        invoice.setValue(current.issueDate, forKey: "issueDate")
        invoice.setValue(
            current.dueDate,
            forKey: "dueDate"
        )

        invoice.setValue(
            current.dueDateMode,
            forKey: "dueDateMode"
        )

        invoice.setValue(
            current.finalDueDate,
            forKey: "finalDueDate"
        )

        invoice.setValue(
            current.finalDueDateMode,
            forKey: "finalDueDateMode"
        )

        invoice.setValue(
            current.paymentPlan,
            forKey: "paymentPlan"
        )

        invoice.setValue(
            current.paymentStage,
            forKey: "paymentStage"
        )
        invoice.setValue(current.senderName, forKey: "senderName")
        invoice.setValue(current.senderAddress, forKey: "senderAddress")
        invoice.setValue(current.clientName, forKey: "clientName")
        invoice.setValue(current.clientAddress, forKey: "clientAddress")
        invoice.setValue(current.clientContact, forKey: "clientContact")
        invoice.setValue(current.projectName, forKey: "projectName")
        invoice.setValue(
            current.projectDescription,
            forKey: "projectDescription"
        )
        invoice.setValue(current.currency, forKey: "currency")
        invoice.setValue(current.taxRate, forKey: "taxRate")
        invoice.setValue(current.paymentTerms, forKey: "paymentTerms")
        invoice.setValue(current.bankingDetails, forKey: "bankingDetails")
        invoice.setValue(current.total, forKey: "total")
        invoice.setValue(Date(), forKey: "updatedAt")

        if current.isIssued,
           invoice.value(forKey: "issuedAt") == nil {
            invoice.setValue(Date(), forKey: "issuedAt")
        }

        let oldLines = fetch(
            "InvoiceLine",
            predicate: NSPredicate(
                format: "invoiceId == %@",
                current.id as NSUUID
            )
        )

        oldLines.forEach(context.delete)

        for (index, line) in current.lines.enumerated() {
            let object = NSEntityDescription.insertNewObject(
                forEntityName: "InvoiceLine",
                into: context
            )

            object.setValue(line.id, forKey: "id")
            object.setValue(current.id, forKey: "invoiceId")
            object.setValue(
                line.itemDescription,
                forKey: "itemDescription"
            )
            object.setValue(line.quantity, forKey: "quantity")
            object.setValue(line.rate, forKey: "rate")
            object.setValue(Int64(index), forKey: "sortOrder")
        }

        upsertClient()
        upsertProject()

        addAudit(
            action: action,
            entityId: current.id.uuidString,
            details: current.documentNumber
        )

        saveContext()
        loadClients()
        loadDrafts()
        lastSavedDraft = current
        hasUnsavedChanges = false
        message = action
    }

    private func upsertClient() {
        let name = current.clientName
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !name.isEmpty else { return }

        let object = fetch(
            "Client",
            predicate: NSPredicate(
                format: "legalName =[c] %@",
                name
            )
        ).first ?? NSEntityDescription.insertNewObject(
            forEntityName: "Client",
            into: context
        )

        if object.value(forKey: "createdAt") == nil {
            object.setValue(UUID(), forKey: "id")
            object.setValue(Date(), forKey: "createdAt")
        }

        object.setValue(name, forKey: "legalName")
        object.setValue(current.clientContact, forKey: "contactName")
        object.setValue(
            current.clientAddress,
            forKey: "billingAddress"
        )
        object.setValue(Date(), forKey: "updatedAt")
    }

    private func upsertProject() {
        let name = current.projectName
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !name.isEmpty else { return }

        let object = fetch(
            "Project",
            predicate: NSPredicate(
                format: "name == %@ AND clientName == %@",
                name,
                current.clientName
            )
        ).first ?? NSEntityDescription.insertNewObject(
            forEntityName: "Project",
            into: context
        )

        if object.value(forKey: "createdAt") == nil {
            object.setValue(UUID(), forKey: "id")
            object.setValue(Date(), forKey: "createdAt")
        }

        object.setValue(current.clientName, forKey: "clientName")
        object.setValue(name, forKey: "name")
        object.setValue(
            current.projectDescription,
            forKey: "projectDescription"
        )
        object.setValue(Date(), forKey: "updatedAt")
    }

    private func nextDocumentNumber(for type: String) -> String {
        let isQuote = type == "QUOTE"
        let key = isQuote
            ? "next_quote_number"
            : "next_invoice_number"
        let startingNumber = isQuote ? 1 : 165

        let setting = fetch(
            "Setting",
            predicate: NSPredicate(format: "key == %@", key)
        ).first ?? NSEntityDescription.insertNewObject(
            forEntityName: "Setting",
            into: context
        )

        setting.setValue(key, forKey: "key")

        let stored = setting.value(forKey: "value") as? String
        let next = Int(stored ?? "") ?? startingNumber

        setting.setValue(String(next + 1), forKey: "value")

        return isQuote
            ? "Q-\(String(format: "%03d", next))"
            : "INV-\(next)"
    }

    private func paymentsTotal(for invoiceId: UUID) -> Double {
        fetch(
            "Payment",
            predicate: NSPredicate(
                format: "invoiceId == %@",
                invoiceId as NSUUID
            )
        ).reduce(0) {
            $0 + ($1.value(forKey: "amount") as? Double ?? 0)
        }
    }

    private func invoiceObject(_ id: UUID) -> NSManagedObject? {
        fetch(
            "Invoice",
            predicate: NSPredicate(
                format: "id == %@",
                id as NSUUID
            )
        ).first
    }

    private func addAudit(
        action: String,
        entityId: String,
        details: String
    ) {
        let event = NSEntityDescription.insertNewObject(
            forEntityName: "AuditEvent",
            into: context
        )

        event.setValue(UUID(), forKey: "id")
        event.setValue(Date(), forKey: "timestamp")
        event.setValue(action, forKey: "action")
        event.setValue(entityId, forKey: "entityId")
        event.setValue(details, forKey: "details")
    }

    private func saveContext() {
        do {
            if context.hasChanges {
                try context.save()
            }
        } catch {
            message = "Database error: \(error.localizedDescription)"
        }
    }

    private func fetch(
        _ entityName: String,
        predicate: NSPredicate? = nil,
        sort: [NSSortDescriptor] = []
    ) -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(
            entityName: entityName
        )

        request.predicate = predicate
        request.sortDescriptors = sort

        do {
            return try context.fetch(request)
        } catch {
            message = "Database read failed: \(error.localizedDescription)"
            return []
        }
    }
}

// MARK: - Editable document

struct InvoiceEditorView: View {
    @EnvironmentObject private var store: InvoiceStore
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("hasShownShortcutOverlay") private var hasShownShortcutOverlay = false
    @State private var showShortcutOverlay = true

    var body: some View {
        VStack(spacing: 0) {
            InvoiceToolbar()

            Divider()

            ZStack {
                FlatInvoiceDocument(
                    draft: $store.current,
                    amountPaid: store.amountPaid,
                    addLine: store.addLine,
                    removeLine: store.removeLine
                )

                if showShortcutOverlay {
                    ShortcutOverlay()
                        .transition(.opacity)
                        .onTapGesture {
                            withAnimation {
                                showShortcutOverlay = false
                            }
                        }
                }
            }

            Divider()
            InvoiceStatusBar()
        }
        .frame(minWidth: 760)
        .frame(minHeight: 720)
        .preferredColorScheme(.light)
        .sheet(isPresented: $store.showPaymentSheet) {
            PaymentSheet(
                maximumAmount: max(
                    store.current.total - store.amountPaid,
                    0
                ),
                currency: store.current.currency
            ) {
                date,
                amount,
                type,
                method,
                reference,
                notes in

                store.recordPayment(
                    date: date,
                    amount: amount,
                    type: type,
                    method: method,
                    reference: reference,
                    notes: notes
                )
            }
        }
        .sheet(isPresented: $store.showDraftBrowser) {
            DraftBrowserView()
                .environmentObject(store)
        }
        .sheet(isPresented: $store.showBooks) {
            AccountingWorkspace()
        }
        .alert(
            "Issue this \(store.current.documentType.lowercased())?",
            isPresented: $store.showIssueConfirmation
        ) {
            Button("Cancel", role: .cancel) {}

            Button("Issue") {
                store.issueCurrent()
            }
        } message: {
            Text(
                "A permanent number will be assigned. Later edits will be recorded and synchronized with Books when saved."
            )
        }
        .onChange(of: store.current) { _ in
            store.documentDidChange()
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active {
                store.flushAutosave()
            }
        }
        .onAppear {
            showShortcutOverlay = !hasShownShortcutOverlay
            hasShownShortcutOverlay = true

            if showShortcutOverlay {
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + 2.7
                ) {
                    withAnimation(
                        .easeOut(duration: 0.45)
                    ) {
                        showShortcutOverlay = false
                    }
                }
            }
        }
        .onDisappear {
            store.flushAutosave()
        }
    }
}


struct InvoiceToolbar: View {
    @EnvironmentObject private var store: InvoiceStore

    var body: some View {
        HStack(spacing: 10) {
            Button {
                store.newDocument(type: "INVOICE")
            } label: {
                Label("New", systemImage: "doc.badge.plus")
            }

            Button {
                store.loadDrafts()
                store.showDraftBrowser = true
            } label: {
                Label("Documents", systemImage: "tray.full")
            }

            Button {
                store.importInvoice()
            } label: {
                Label("Import", systemImage: "square.and.arrow.down.on.square")
            }

            Button {
                store.saveDraft()
            } label: {
                Label(
                    store.current.isIssued ? "Save Changes" : "Save",
                    systemImage: "square.and.arrow.down"
                )
            }

            Divider()
                .frame(height: 22)

            Button {
                store.showIssueConfirmation = true
            } label: {
                Label("Issue", systemImage: "checkmark.seal")
            }
            .disabled(store.current.isIssued)

            Button {
                store.exportPDF()
            } label: {
                Label("Export", systemImage: "doc.richtext")
            }

            Button {
                store.showPaymentSheet = true
            } label: {
                Label("Payment", systemImage: "banknote")
            }
            .disabled(
                !store.current.isIssued ||
                store.current.documentType != "INVOICE" ||
                store.amountPaid + 0.005 >= store.current.total
            )

            Button {
                store.showBooks = true
            } label: {
                Label("Books", systemImage: "books.vertical")
            }

            Spacer()

            Text(store.current.documentType.capitalized)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)

            Text(store.current.status)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(Color.black.opacity(0.07))
                )
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}


struct InvoiceStatusBar: View {
    @EnvironmentObject private var store: InvoiceStore

    var body: some View {
        HStack(spacing: 8) {
            Image(
                systemName: store.hasUnsavedChanges
                    ? "circle.fill"
                    : "checkmark.circle"
            )
            .foregroundColor(
                store.hasUnsavedChanges ? .orange : .green
            )

            Text(
                store.message
            )
            .lineLimit(1)

            Spacer()

            if store.hasUnsavedChanges {
                Text(
                    store.current.isIssued
                        ? "Unsaved issued changes · press Save"
                        : "Unsaved changes · autosaving…"
                )
                    .foregroundColor(.orange)
            } else if store.current.isIssued {
                Text("Editing an issued invoice updates Books when saved")
                    .foregroundColor(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}


struct ShortcutOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.08)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                Text("INV")
                    .font(
                        .system(
                            size: 25,
                            weight: .bold
                        )
                    )

                Text("KEYBOARD SHORTCUTS")
                    .font(
                        .system(
                            size: 10,
                            weight: .semibold
                        )
                    )
                    .foregroundColor(invQuietInk)

                VStack(alignment: .leading, spacing: 9) {
                    ShortcutLine(
                        keys: "⌘N",
                        label: "New invoice"
                    )

                    ShortcutLine(
                        keys: "⇧⌘N",
                        label: "New quote"
                    )

                    ShortcutLine(
                        keys: "⌘S",
                        label: "Save document"
                    )

                    ShortcutLine(
                        keys: "⇧⌘I",
                        label: "Issue"
                    )

                    ShortcutLine(
                        keys: "⇧⌘E",
                        label: "Export PDF"
                    )

                    ShortcutLine(
                        keys: "⇧⌘P",
                        label: "Record payment"
                    )
                }
            }
            .padding(28)
            .frame(width: 320)
            .background(invPaper)
            .overlay(
                Rectangle()
                    .stroke(
                        invInk.opacity(0.15),
                        lineWidth: 1
                    )
            )
        }
    }
}


struct ShortcutLine: View {
    let keys: String
    let label: String

    var body: some View {
        HStack {
            Text(keys)
                .font(
                    .system(
                        size: 12,
                        weight: .semibold
                    )
                )
                .frame(
                    width: 70,
                    alignment: .leading
                )

            Text(label)
                .font(.system(size: 12))
        }
    }
}


private let invPaper = Color(
    red: 0.965,
    green: 0.953,
    blue: 0.914
)

private let invQuotePaper = Color(
    red: 0.949,
    green: 0.957,
    blue: 0.961
)

private let invInk = Color(
    red: 0.075,
    green: 0.075,
    blue: 0.075
)

private let invQuietInk = Color(
    red: 0.36,
    green: 0.35,
    blue: 0.32
)



private struct INVExportModeKey: EnvironmentKey {
    static let defaultValue = false
}


private extension EnvironmentValues {
    var invExportMode: Bool {
        get {
            self[INVExportModeKey.self]
        }

        set {
            self[INVExportModeKey.self] = newValue
        }
    }
}


private extension View {
    @ViewBuilder
    func invTransparentEditorBackground() -> some View {
        if #available(macOS 13.0, *) {
            scrollContentBackground(.hidden)
        } else {
            self
        }
    }
}


struct FlatInvoiceDocument: View {
    @ObservedObject private var accounting =
        AccountingRepository.shared

    @Binding var draft: InvoiceDraft

    let amountPaid: Double
    let addLine: () -> Void
    let removeLine: (UUID) -> Void
    let isExporting: Bool

    init(
        draft: Binding<InvoiceDraft>,
        amountPaid: Double,
        addLine: @escaping () -> Void,
        removeLine: @escaping (UUID) -> Void,
        isExporting: Bool = false
    ) {
        _draft = draft
        self.amountPaid = amountPaid
        self.addLine = addLine
        self.removeLine = removeLine
        self.isExporting = isExporting
    }

    private var balance: Double {
        max(draft.total - amountPaid, 0)
    }

    private var documentPaper: Color {
        if isExporting {
            return .white
        }

        return draft.documentType == "QUOTE"
            ? invQuotePaper
            : invPaper
    }

    var body: some View {
        Group {
            if isExporting {
                documentContent
            } else {
                ScrollView(.vertical) {
                    documentContent
                }
            }
        }
        .background(documentPaper)
        .foregroundColor(invInk)
        .environment(
            \.invExportMode,
            isExporting
        )
    }

    private var documentContent: some View {
        VStack(
            alignment: .leading,
            spacing: 42
        ) {
            heading
            parties
            project
            lineItems
            totals
            terms
        }
        .padding(
            EdgeInsets(
                top: 54,
                leading: 58,
                bottom: 80,
                trailing: 58
            )
        )
        .frame(
            maxWidth: .infinity,
            alignment: .topLeading
        )
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 34) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(draft.status.uppercased())
                        .font(
                            .system(
                                size: 10,
                                weight: .medium
                            )
                        )
                        .foregroundColor(invQuietInk)

                    Text(
                        draft.documentNumber.isEmpty
                            ? (
                                isExporting
                                    ? ""
                                    : "NUMBER ASSIGNED ON ISSUE"
                            )
                            : draft.documentNumber
                    )
                    .font(.system(size: 12))
                    .foregroundColor(invQuietInk)
                }

                Spacer()

                Text(invoiceDisplayTitle(for: draft.documentType))
                    .font(
                        .system(
                            size: 54,
                            weight: .bold
                        )
                    )
            }

            HStack(alignment: .top, spacing: 42) {
                FlatDateField(
                    label: "ISSUE DATE",
                    date: $draft.issueDate
                )

                InvoiceDueDatePanel(
                    paymentPlan:
                        $draft.paymentPlan,
                    dueDate:
                        $draft.dueDate,
                    dueDateMode:
                        $draft.dueDateMode,
                    finalDueDate:
                        $draft.finalDueDate,
                    finalDueDateMode:
                        $draft.finalDueDateMode
                )

                FlatTextField(
                    label: "PAYMENT STAGE",
                    text: $draft.paymentStage,
                    placeholder: "Full payment, deposit or final balance"
                )

                FlatTextField(
                    label: "CURRENCY",
                    text: $draft.currency,
                    placeholder: "ZAR"
                )
                .frame(width: 85)
            }
        }
    }

    private var parties: some View {
        HStack(alignment: .top, spacing: 64) {
            VStack(alignment: .leading, spacing: 15) {
                FlatSectionLabel("FROM")

                FlatTextField(
                    label: "NAME",
                    text: $draft.senderName,
                    placeholder: "Your name or business name"
                )

                FlatMultilineEditor(
                    text: $draft.senderAddress,
                    height: 112,
                    placeholder: "Business address\nEmail address\nPhone number"
                )
            }
            .frame(
                maxWidth: .infinity,
                alignment: .topLeading
            )

            VStack(alignment: .leading, spacing: 15) {
                FlatSectionLabel("BILL TO")

                if isExporting {
                    FlatTextField(
                        label: "CLIENT",
                        text: $draft.clientName,
                        placeholder:
                            draft.sampleClientName
                    )
                } else {
                    ClientAutocompleteField(
                        text:
                            $draft.clientName,
                        placeholder:
                            draft.sampleClientName
                    )
                }

                VStack(
                    alignment: .leading,
                    spacing: 5
                ) {
                    Text("ATTENTION")
                        .font(
                            .system(
                                size: 9,
                                weight: .medium
                            )
                        )
                        .foregroundColor(invQuietInk)

                    GrowingDescriptionField(
                        text: $draft.clientContact,
                        placeholder: draft.sampleClientName
                    )
                }

                FlatMultilineEditor(
                    text: $draft.clientAddress,
                    height: 90,
                    placeholder: "Client billing address\nEmail address\nPhone number"
                )
            }
            .frame(
                maxWidth: .infinity,
                alignment: .topLeading
            )
        }
    }

    private var project: some View {
        VStack(alignment: .leading, spacing: 15) {
            FlatSectionLabel("PROJECT")

            FlatTextField(
                    label: "PROJECT NAME",
                    text: $draft.projectName,
                    placeholder: "Enter project name"
                )

            FlatMultilineEditor(
                    text: $draft.projectDescription,
                    height: 104,
                    placeholder: "Describe the work, deliverables and intended usage"
                )
        }
    }

    private var lineItems: some View {
        VStack(spacing: 0) {
            HStack(spacing: 20) {
                FlatColumnHeading("DESCRIPTION")
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )

                FlatColumnHeading("QTY")
                    .frame(
                        width: 60,
                        alignment: .trailing
                    )

                FlatColumnHeading("RATE")
                    .frame(
                        width: 105,
                        alignment: .trailing
                    )

                FlatColumnHeading("AMOUNT")
                    .frame(
                        width: 118,
                        alignment: .trailing
                    )
            }
            .frame(
                maxWidth: .infinity
            )
            .padding(.bottom, 11)

            FlatRule()

            ForEach(
                $draft.lines
            ) { $line in
                HStack(
                    alignment: .top,
                    spacing: 20
                ) {
                    GrowingDescriptionField(
                        text:
                            $line.itemDescription,
                        placeholder:
                            "Description"
                    )
                    .frame(
                        maxWidth: .infinity,
                        alignment: .topLeading
                    )

                    Group {
                        if isExporting {
                            Text(
                                decimalFormatter
                                    .string(
                                        from:
                                            NSNumber(
                                                value:
                                                    line.quantity
                                            )
                                    ) ?? "\(line.quantity)"
                            )
                        } else {
                            TextField(
                                "1",
                                value:
                                    $line.quantity,
                                formatter:
                                    decimalFormatter
                            )
                            .textFieldStyle(
                                .plain
                            )
                            .multilineTextAlignment(
                                .trailing
                            )
                        }
                    }
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundColor(invInk)
                    .frame(
                        width: 60,
                        alignment: .trailing
                    )
                    .padding(.top, 3)

                    Group {
                        if isExporting {
                            Text(
                                decimalFormatter
                                    .string(
                                        from:
                                            NSNumber(
                                                value:
                                                    line.rate
                                            )
                                    ) ?? "\(line.rate)"
                            )
                        } else {
                            TextField(
                                "0.00",
                                value:
                                    $line.rate,
                                formatter:
                                    decimalFormatter
                            )
                            .textFieldStyle(
                                .plain
                            )
                            .multilineTextAlignment(
                                .trailing
                            )
                        }
                    }
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundColor(invInk)
                    .frame(
                        width: 105,
                        alignment: .trailing
                    )
                    .padding(.top, 3)

                    Text(
                        money(
                            line.total,
                            currency:
                                draft.currency
                        )
                    )
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .frame(
                        width: 118,
                        alignment: .trailing
                    )
                    .padding(.top, 3)
                }
                .frame(
                    maxWidth: .infinity
                )
                .overlay(
                    alignment: .topTrailing
                ) {
                    if !isExporting {
                        Button("×") {
                            removeLine(
                                line.id
                            )
                        }
                        .buttonStyle(.plain)
                        .font(
                            .system(
                                size: 17
                            )
                        )
                        .foregroundColor(
                            invQuietInk
                        )
                        .frame(width: 22)
                        .offset(
                            x: 32,
                            y: 3
                        )
                    }
                }
                .padding(.vertical, 13)

                FlatRule()
            }

            if !isExporting {
                HStack {
                    Button("+ ADD LINE") {
                        addLine()
                    }
                    .buttonStyle(.plain)
                    .font(
                        .system(
                            size: 10,
                            weight: .medium
                        )
                    )
                    .foregroundColor(
                        invQuietInk
                    )

                    Spacer()
                }
                .padding(.top, 14)
            }
        }
        .frame(
            maxWidth: .infinity
        )
    }

    private var totals: some View {
        HStack(
            alignment: .top,
            spacing: 32
        ) {
            if !isExporting {
                VStack(
                    alignment: .leading,
                    spacing: 14
                ) {
                    FlatSectionLabel("VAT")

                    FlatNumberField(
                        label: "RATE %",
                        value:
                            $draft.taxRate
                    )
                    .frame(width: 110)
                }
            }

            Spacer(minLength: 24)

            VStack(spacing: 11) {
                FlatAmountLine(
                    label: "SUBTOTAL",
                    value:
                        money(
                            draft.subtotal,
                            currency:
                                draft.currency
                        )
                )

                FlatAmountLine(
                    label: "VAT",
                    value:
                        draft.taxRate == 0
                        ? "N/A"
                        : money(
                            draft.tax,
                            currency:
                                draft.currency
                        )
                )

                FlatRule()

                FlatAmountLine(
                    label: "TOTAL",
                    value:
                        money(
                            draft.total,
                            currency:
                                draft.currency
                        ),
                    emphasised: true
                )

                if amountPaid > 0 {
                    FlatAmountLine(
                        label: "PAID",
                        value:
                            money(
                                amountPaid,
                                currency:
                                    draft.currency
                            )
                    )

                    FlatAmountLine(
                        label: "BALANCE",
                        value:
                            money(
                                balance,
                                currency:
                                    draft.currency
                            ),
                        emphasised: true
                    )
                }
            }
            .frame(
                width: 310,
                alignment: .trailing
            )
        }
        .frame(
            maxWidth: .infinity,
            alignment: .trailing
        )
    }

    @ViewBuilder
    private var terms: some View {
        if draft.documentType == "QUOTE" {
            VStack(
                alignment: .leading,
                spacing: 28
            ) {
                VStack(
                    alignment: .leading,
                    spacing: 15
                ) {
                    FlatSectionLabel(
                        "QUOTE TERMS & ACCEPTANCE"
                    )

                    FlatMultilineEditor(
                        text:
                            $draft.paymentTerms,
                        height: 180,
                        placeholder:
                            "Quote validity, revision allowance, usage rights, deposit requirements and acceptance instructions"
                    )
                }

                VStack(
                    alignment: .leading,
                    spacing: 4
                ) {
                    Text(
                        "QUOTE REFERENCE"
                    )
                    .font(
                        .system(
                            size: 9,
                            weight: .medium
                        )
                    )
                    .foregroundColor(
                        invQuietInk
                    )

                    Text(
                        draft.documentNumber
                            .isEmpty
                        ? (
                            isExporting
                                ? ""
                                : "ASSIGNED ON ISSUE"
                        )
                        : draft.documentNumber
                    )
                    .font(.system(size: 13))
                }
            }
            .frame(
                maxWidth: 480,
                alignment: .leading
            )
            .frame(
                maxWidth: .infinity,
                alignment: .leading
            )
        } else {
            VStack(
                alignment: .leading,
                spacing: 34
            ) {
                if !isExporting
                    || !draft.paymentTerms
                        .trimmingCharacters(
                            in:
                                .whitespacesAndNewlines
                        )
                        .isEmpty {

                    VStack(
                        alignment: .leading,
                        spacing: 15
                    ) {
                        FlatSectionLabel(
                            "PAYMENT TERMS"
                        )

                        FlatMultilineEditor(
                            text:
                                $draft.paymentTerms,
                            height: 130,
                            placeholder:
                                "Payment due date, licensing terms and any late-payment conditions"
                        )
                    }
                }

                VStack(
                    alignment: .leading,
                    spacing: 15
                ) {
                    FlatSectionLabel(
                        "BANKING DETAILS"
                    )

                    GrowingDescriptionField(
                        text:
                            $draft.bankingDetails,
                        placeholder:
                            "Account holder\nBank\nAccount number\nBranch code"
                    )
                    .frame(
                        minHeight: 30,
                        alignment: .topLeading
                    )

                    VStack(
                        alignment: .leading,
                        spacing: 4
                    ) {
                        Text(
                            "PAYMENT REFERENCE"
                        )
                        .font(
                            .system(
                                size: 9,
                                weight: .medium
                            )
                        )
                        .foregroundColor(
                            invQuietInk
                        )

                        Text(
                            draft.documentNumber
                                .isEmpty
                            ? (
                                isExporting
                                    ? ""
                                    : "ASSIGNED ON ISSUE"
                            )
                            : draft.documentNumber
                        )
                        .font(.system(size: 13))
                    }
                    .padding(.top, 4)
                }
                .fixedSize(
                    horizontal: false,
                    vertical: true
                )
            }
            .frame(
                maxWidth: 480,
                alignment: .leading
            )
            .frame(
                maxWidth: .infinity,
                alignment: .leading
            )
        }
    }
}


struct FlatSectionLabel: View {
    let value: String

    init(_ value: String) {
        self.value = value
    }

    var body: some View {
        Text(value)
            .font(
                .system(
                    size: 11,
                    weight: .semibold
                )
            )
            .foregroundColor(invInk)
    }
}


struct FlatColumnHeading: View {
    let value: String

    init(_ value: String) {
        self.value = value
    }

    var body: some View {
        Text(value)
            .font(
                .system(
                    size: 9,
                    weight: .medium
                )
            )
            .foregroundColor(invQuietInk)
    }
}


struct FlatRule: View {
    var body: some View {
        Rectangle()
            .fill(invInk.opacity(0.18))
            .frame(height: 1)
    }
}


struct ClientAutocompleteField: View {
    @EnvironmentObject private var store:
        InvoiceStore

    @Binding var text: String
    let placeholder: String

    private var suggestions:
        [SavedClient] {
        store.matchingClients(text)
    }

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 6
        ) {
            FlatTextField(
                label: "CLIENT",
                text: $text,
                placeholder: placeholder
            )

            if !store.savedClients.isEmpty {
                Menu {
                    if suggestions.isEmpty {
                        Text(
                            "No matching saved client"
                        )
                    } else {
                        ForEach(suggestions) {
                            client in

                            Button {
                                store.applyClient(
                                    client
                                )
                            } label: {
                                VStack(
                                    alignment: .leading
                                ) {
                                    Text(client.name)

                                    if !client
                                        .contactName
                                        .isEmpty {
                                        Text(
                                            client.contactName
                                        )
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    HStack(
                        spacing: 5
                    ) {
                        Image(
                            systemName:
                                "person.crop.circle"
                        )

                        Text(
                            store.savedClients.count
                                == 1
                            ? "1 SAVED CLIENT"
                            : "\(store.savedClients.count) SAVED CLIENTS"
                        )

                        Image(
                            systemName:
                                "chevron.down"
                        )
                    }
                    .font(
                        .system(
                            size: 9,
                            weight: .medium
                        )
                    )
                    .foregroundColor(
                        invQuietInk
                    )
                }
                .menuStyle(
                    .borderlessButton
                )
                .fixedSize()
            }
        }
        .onChange(of: text) {
            newValue in

            store.autofillClientIfKnown(
                newValue
            )
        }
    }
}


struct FlatTextField: View {
    @Environment(
        \.invExportMode
    ) private var isExporting

    let label: String

    @Binding var text: String

    var placeholder: String = ""

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 5
        ) {
            Text(label)
                .font(
                    .system(
                        size: 9,
                        weight: .medium
                    )
                )
                .foregroundColor(invQuietInk)

            Group {
                if isExporting {
                    Text(
                        text.isEmpty
                            ? " "
                            : text
                    )
                    .opacity(
                        text.isEmpty ? 0 : 1
                    )
                } else {
                    TextField(
                        placeholder,
                        text: $text
                    )
                    .textFieldStyle(.plain)
                }
            }
            .font(.system(size: 13))
            .foregroundColor(invInk)
        }
        .frame(
            maxWidth: .infinity,
            alignment: .leading
        )
    }
}


struct InvoiceDueDatePanel: View {
    @Environment(
        \.invExportMode
    ) private var isExporting

    @Binding var paymentPlan: String
    @Binding var dueDate: Date
    @Binding var dueDateMode: String
    @Binding var finalDueDate: Date
    @Binding var finalDueDateMode: String

    @State private var isExpanded = false

    private var planName: String {
        paymentPlan == "50/50"
            ? "50 / 50"
            : "Single"
    }

    private var firstDueText: String {
        invoiceDueDateText(
            mode: dueDateMode,
            date: dueDate
        )
    }

    private var finalDueText: String {
        invoiceDueDateText(
            mode: finalDueDateMode,
            date: finalDueDate
        )
    }

    private var collapsedSummary: String {
        if paymentPlan == "50/50" {
            return "\(planName) · \(firstDueText) / \(finalDueText)"
        }

        return "\(planName) · \(firstDueText)"
    }

    private var firstAlternativeMode: String {
        paymentPlan == "50/50"
            ? "At project start"
            : "On delivery"
    }

    var body: some View {
        Group {
            if isExporting {
                exportedContent
            } else {
                collapsibleEditor
            }
        }
        .frame(
            maxWidth: .infinity,
            alignment: .topLeading
        )
        .onChange(of: paymentPlan) {
            newValue in

            if newValue == "50/50",
               dueDateMode == "On delivery" {
                dueDateMode = "At project start"
            }

            if newValue != "50/50",
               dueDateMode == "At project start" {
                dueDateMode = "On delivery"
            }
        }
    }

    private var collapsibleEditor: some View {
        VStack(
            alignment: .leading,
            spacing: 0
        ) {
            Button {
                withAnimation(
                    .easeInOut(
                        duration: 0.18
                    )
                ) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(
                    spacing: 12
                ) {
                    VStack(
                        alignment: .leading,
                        spacing: 3
                    ) {
                        Text("PAYMENT SCHEDULE")
                            .font(
                                .system(
                                    size: 9,
                                    weight: .semibold
                                )
                            )
                            .foregroundColor(
                                invQuietInk
                            )

                        Text(collapsedSummary)
                            .font(
                                .system(
                                    size: 13,
                                    weight: .medium
                                )
                            )
                            .foregroundColor(invInk)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 10)

                    Image(
                        systemName: "chevron.right"
                    )
                    .font(
                        .system(
                            size: 11,
                            weight: .semibold
                        )
                    )
                    .foregroundColor(invQuietInk)
                    .rotationEffect(
                        .degrees(
                            isExpanded ? 90 : 0
                        )
                    )
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                    .padding(.vertical, 12)

                VStack(
                    alignment: .leading,
                    spacing: 14
                ) {
                    Text("PAYMENT PLAN")
                        .font(
                            .system(
                                size: 9,
                                weight: .medium
                            )
                        )
                        .foregroundColor(invQuietInk)

                    Picker(
                        "",
                        selection: $paymentPlan
                    ) {
                        Text("Single")
                            .tag("Single")

                        Text("50 / 50")
                            .tag("50/50")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)

                    dueEditor(
                        label:
                            paymentPlan == "50/50"
                            ? "FIRST 50% DUE"
                            : "DUE DATE",
                        alternativeMode:
                            firstAlternativeMode,
                        mode: $dueDateMode,
                        date: $dueDate
                    )

                    if paymentPlan == "50/50" {
                        dueEditor(
                            label: "FINAL 50% DUE",
                            alternativeMode:
                                "On delivery",
                            mode:
                                $finalDueDateMode,
                            date:
                                $finalDueDate
                        )
                    }
                }
            }
        }
        .padding(13)
        .background(
            RoundedRectangle(
                cornerRadius: 10,
                style: .continuous
            )
            .fill(
                invInk.opacity(0.035)
            )
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: 10,
                style: .continuous
            )
            .stroke(
                invInk.opacity(0.14),
                lineWidth: 1
            )
        )
    }

    private var exportedContent: some View {
        VStack(
            alignment: .leading,
            spacing: 10
        ) {
            exportedField(
                label:
                    paymentPlan == "50/50"
                    ? "FIRST 50% DUE"
                    : "DUE DATE",
                mode: dueDateMode,
                date: dueDate
            )

            if paymentPlan == "50/50" {
                exportedField(
                    label: "FINAL 50% DUE",
                    mode: finalDueDateMode,
                    date: finalDueDate
                )
            }
        }
    }

    @ViewBuilder
    private func dueEditor(
        label: String,
        alternativeMode: String,
        mode: Binding<String>,
        date: Binding<Date>
    ) -> some View {
        VStack(
            alignment: .leading,
            spacing: 6
        ) {
            Text(label)
                .font(
                    .system(
                        size: 9,
                        weight: .medium
                    )
                )
                .foregroundColor(invQuietInk)

            Picker(
                "",
                selection: mode
            ) {
                Text("Specific date")
                    .tag("Specific date")

                Text(alternativeMode)
                    .tag(alternativeMode)
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            if mode.wrappedValue == "Specific date" {
                DatePicker(
                    "",
                    selection: date,
                    displayedComponents: .date
                )
                .labelsHidden()
            } else {
                Text(mode.wrappedValue)
                    .font(.system(size: 13))
                    .foregroundColor(invInk)
            }
        }
    }

    private func exportedField(
        label: String,
        mode: String,
        date: Date
    ) -> some View {
        VStack(
            alignment: .leading,
            spacing: 5
        ) {
            Text(label)
                .font(
                    .system(
                        size: 9,
                        weight: .medium
                    )
                )
                .foregroundColor(invQuietInk)

            Text(
                invoiceDueDateText(
                    mode: mode,
                    date: date
                )
            )
            .font(.system(size: 13))
            .foregroundColor(invInk)
        }
    }
}


struct FlatDateField: View {
    @Environment(
        \.invExportMode
    ) private var isExporting

    let label: String

    @Binding var date: Date

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 5
        ) {
            Text(label)
                .font(
                    .system(
                        size: 9,
                        weight: .medium
                    )
                )
                .foregroundColor(invQuietInk)

            Group {
                if isExporting {
                    Text(
                        invDateFormatter.string(
                            from: date
                        )
                    )
                } else {
                    TextField(
                        "",
                        value: $date,
                        formatter:
                            invDateFormatter
                    )
                    .textFieldStyle(.plain)
                }
            }
            .font(.system(size: 13))
            .foregroundColor(invInk)
        }
        .frame(
            maxWidth: .infinity,
            alignment: .leading
        )
    }
}


struct FlatNumberField: View {
    @Environment(
        \.invExportMode
    ) private var isExporting

    let label: String

    @Binding var value: Double

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 5
        ) {
            Text(label)
                .font(
                    .system(
                        size: 9,
                        weight: .medium
                    )
                )
                .foregroundColor(invQuietInk)

            Group {
                if isExporting {
                    Text(
                        decimalFormatter.string(
                            from: NSNumber(
                                value: value
                            )
                        ) ?? "\(value)"
                    )
                } else {
                    TextField(
                        "",
                        value: $value,
                        formatter:
                            decimalFormatter
                    )
                    .textFieldStyle(.plain)
                }
            }
            .font(.system(size: 13))
            .foregroundColor(invInk)
        }
    }
}


struct FlatAmountLine: View {
    let label: String
    let value: String

    var emphasised = false

    var body: some View {
        HStack(spacing: 20) {
            Text(label)
                .font(
                    .system(
                        size:
                            emphasised
                            ? 11
                            : 9,
                        weight:
                            emphasised
                            ? .semibold
                            : .medium
                    )
                )
                .foregroundColor(
                    emphasised
                        ? invInk
                        : invQuietInk
                )

            Spacer(minLength: 20)

            Text(value)
                .font(
                    .system(
                        size:
                            emphasised
                            ? 18
                            : 13,
                        weight:
                            emphasised
                            ? .semibold
                            : .regular
                    )
                )
                .monospacedDigit()
                .frame(
                    minWidth: 125,
                    alignment: .trailing
                )
        }
        .frame(
            maxWidth: .infinity
        )
    }
}


struct FlatMultilineEditor: View {
    @Environment(
        \.invExportMode
    ) private var isExporting

    @Binding var text: String

    let height: CGFloat

    var placeholder: String = ""

    var body: some View {
        Group {
            if isExporting {
                Text(
                    text.isEmpty
                        ? " "
                        : text
                )
                .font(.system(size: 13))
                .foregroundColor(invInk)
                .fixedSize(
                    horizontal: false,
                    vertical: true
                )
                .frame(
                    maxWidth: .infinity,
                    minHeight: height,
                    alignment: .topLeading
                )
                .opacity(
                    text.isEmpty ? 0 : 1
                )
            } else {
                ZStack(
                    alignment: .topLeading
                ) {
                    if text.isEmpty &&
                        !placeholder.isEmpty {

                        Text(placeholder)
                            .font(
                                .system(
                                    size: 13
                                )
                            )
                            .foregroundColor(
                                invQuietInk
                                    .opacity(0.42)
                            )
                            .padding(.top, 3)
                            .allowsHitTesting(
                                false
                            )
                    }

                    TextEditor(text: $text)
                        .font(.system(size: 13))
                        .foregroundColor(invInk)
                        .invTransparentEditorBackground()
                        .background(Color.clear)
                }
                .frame(height: height)
            }
        }
    }
}


struct FlatTextView: NSViewRepresentable {
    @Binding var text: String

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: FlatTextView

        init(_ parent: FlatTextView) {
            self.parent = parent
        }

        func textDidChange(
            _ notification: Notification
        ) {
            guard let textView =
                notification.object as? NSTextView
            else {
                return
            }

            if parent.text != textView.string {
                parent.text = textView.string
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(
        context: Context
    ) -> NSScrollView {
        let scrollView = NSScrollView()

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false

        let textView = NSTextView()

        textView.delegate = context.coordinator
        textView.string = text
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.focusRingType = .none
        textView.textColor = NSColor(
            calibratedWhite: 0.075,
            alpha: 1
        )
        textView.font =
            NSFont.systemFont(ofSize: 13)

        textView.textContainerInset = NSSize(
            width: 0,
            height: 3
        )

        textView.textContainer?
            .lineFragmentPadding = 0

        textView.textContainer?
            .widthTracksTextView = true

        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView

        return scrollView
    }

    func updateNSView(
        _ scrollView: NSScrollView,
        context: Context
    ) {
        context.coordinator.parent = self

        guard let textView =
            scrollView.documentView as? NSTextView
        else {
            return
        }

        if textView.string != text {
            textView.string = text
        }
    }
}


final class GrowingDescriptionScrollView: NSScrollView {
    var widthChanged: ((CGFloat) -> Void)?

    override func layout() {
        super.layout()

        let width = max(
            contentSize.width,
            1
        )

        widthChanged?(width)
    }
}


struct GrowingDescriptionField: View {
    @Environment(
        \.invExportMode
    ) private var isExporting

    @Binding var text: String

    var placeholder: String = ""

    @State private var measuredHeight:
        CGFloat = 30

    var body: some View {
        Group {
            if isExporting {
                Text(
                    text.isEmpty
                        ? " "
                        : text
                )
                .font(.system(size: 13))
                .foregroundColor(invInk)
                .fixedSize(
                    horizontal: false,
                    vertical: true
                )
                .frame(
                    maxWidth: .infinity,
                    minHeight: 30,
                    alignment: .topLeading
                )
                .opacity(
                    text.isEmpty ? 0 : 1
                )
            } else {
                ZStack(
                    alignment: .topLeading
                ) {
                    if text.isEmpty {
                        Text(placeholder)
                            .font(
                                .system(
                                    size: 13
                                )
                            )
                            .foregroundColor(
                                invQuietInk
                                    .opacity(0.42)
                            )
                            .padding(.top, 3)
                            .allowsHitTesting(
                                false
                            )
                    }

                    TextEditor(text: $text)
                        .font(.system(size: 13))
                        .foregroundColor(invInk)
                        .invTransparentEditorBackground()
                        .background(Color.clear)
                }
                .frame(
                    height: max(measuredHeight, 48)
                )
                .onChange(of: text) { newValue in
                    let explicitLines = max(
                        newValue.components(separatedBy: .newlines).count,
                        1
                    )
                    let wrappedLines = max(newValue.count / 48 + 1, 1)
                    measuredHeight = CGFloat(
                        max(explicitLines, wrappedLines)
                    ) * 18 + 16
                }
            }
        }
    }
}


struct GrowingDescriptionTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GrowingDescriptionTextView

        init(
            _ parent: GrowingDescriptionTextView
        ) {
            self.parent = parent
        }

        func textDidChange(
            _ notification: Notification
        ) {
            guard let textView =
                notification.object as? NSTextView
            else {
                return
            }

            if parent.text != textView.string {
                parent.text = textView.string
            }

            let width = max(
                textView.enclosingScrollView?
                    .contentSize.width
                    ?? textView.frame.width,
                1
            )

            recalculate(
                textView,
                width: width
            )
        }

        func recalculate(
            _ textView: NSTextView,
            width: CGFloat
        ) {
            guard
                let textContainer =
                    textView.textContainer,
                let layoutManager =
                    textView.layoutManager
            else {
                return
            }

            let usableWidth = max(width, 80)

            textContainer.containerSize = NSSize(
                width: usableWidth,
                height: CGFloat.greatestFiniteMagnitude
            )

            textContainer.widthTracksTextView = true
            textContainer.heightTracksTextView = false

            textView.setFrameSize(
                NSSize(
                    width: usableWidth,
                    height: max(
                        textView.frame.height,
                        30
                    )
                )
            )

            layoutManager.ensureLayout(
                for: textContainer
            )

            let usedRect = layoutManager.usedRect(
                for: textContainer
            )

            let calculatedHeight = max(
                30,
                ceil(
                    usedRect.height
                    + textView.textContainerInset.height * 2
                    + 4
                )
            )

            if abs(
                textView.frame.height
                    - calculatedHeight
            ) > 0.5 {
                textView.setFrameSize(
                    NSSize(
                        width: usableWidth,
                        height: calculatedHeight
                    )
                )
            }

            DispatchQueue.main.async {
                if abs(
                    self.parent.measuredHeight
                        - calculatedHeight
                ) > 0.5 {
                    self.parent.measuredHeight =
                        calculatedHeight
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(
        context: Context
    ) -> GrowingDescriptionScrollView {
        let scrollView =
            GrowingDescriptionScrollView()

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = NSTextView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: 300,
                height: 30
            )
        )

        textView.delegate = context.coordinator
        textView.string = text
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.allowsUndo = true
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.focusRingType = .none

        textView.textColor = NSColor(
            calibratedWhite: 0.075,
            alpha: 1
        )

        textView.font =
            NSFont.systemFont(ofSize: 13)

        textView.textContainerInset = NSSize(
            width: 0,
            height: 3
        )

        textView.textContainer?
            .lineFragmentPadding = 0

        textView.textContainer?
            .widthTracksTextView = true

        textView.textContainer?
            .heightTracksTextView = false

        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]

        textView.minSize = NSSize(
            width: 0,
            height: 30
        )

        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.documentView = textView

        scrollView.widthChanged = {
            [weak textView,
             weak coordinator = context.coordinator]
            width in

            guard
                let textView = textView,
                let coordinator = coordinator
            else {
                return
            }

            coordinator.recalculate(
                textView,
                width: width
            )
        }

        return scrollView
    }

    func updateNSView(
        _ scrollView:
            GrowingDescriptionScrollView,
        context: Context
    ) {
        context.coordinator.parent = self

        guard let textView =
            scrollView.documentView as? NSTextView
        else {
            return
        }

        if textView.string != text {
            textView.string = text
        }

        context.coordinator.recalculate(
            textView,
            width: max(
                scrollView.contentSize.width,
                80
            )
        )
    }
}


struct EditablePageOne: View {
    @Binding var draft: InvoiceDraft
    let removeLine: (UUID) -> Void
    let addLine: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                Picker("", selection: $draft.documentType) {
                    Text("Invoice").tag("INVOICE")
                    Text("Quote").tag("QUOTE")
                }
                .labelsHidden()
                .frame(width: 130)

                Spacer()

                Text(invoiceDisplayTitle(for: draft.documentType))
                    .font(.system(size: 30, weight: .bold))
            }

            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    DetailRow(
                        label: "\(draft.documentType.capitalized) number",
                        value: draft.documentNumber.isEmpty
                            ? "Assigned on issue"
                            : draft.documentNumber
                    )

                    DateField(
                        label: "Issue date",
                        date: $draft.issueDate
                    )

                    DateField(
                        label: "Due date",
                        date: $draft.dueDate
                    )

                    PlainField(
                        label: "Payment stage",
                        text: $draft.paymentStage
                    )
                }

                Spacer()
            }

            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("From")
                        .font(.headline)

                    PlainField(
                        label: "Name",
                        text: $draft.senderName
                    )

                    MultilineField(
                        text: $draft.senderAddress,
                        height: 116
                    )
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Bill To")
                        .font(.headline)

                    PlainField(
                        label: "Client",
                        text: $draft.clientName
                    )

                    PlainField(
                        label: "Attention",
                        text: $draft.clientContact
                    )

                    MultilineField(
                        text: $draft.clientAddress,
                        height: 92
                    )
                }
                .frame(maxWidth: .infinity)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Project")
                    .font(.headline)

                PlainField(
                    label: "Project name",
                    text: $draft.projectName
                )

                MultilineField(
                    text: $draft.projectDescription,
                    height: 92
                )
            }

            VStack(spacing: 0) {
                HStack {
                    Text("Description")
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text("Quantity")
                        .frame(width: 80, alignment: .trailing)

                    Text("Rate")
                        .frame(width: 110, alignment: .trailing)

                    Text("Amount")
                        .frame(width: 120, alignment: .trailing)

                    Color.clear.frame(width: 24)
                }
                .font(.system(size: 11, weight: .semibold))
                .padding(.vertical, 8)

                Divider()

                ForEach($draft.lines) { $line in
                    HStack {
                        TextField(
                            "Description",
                            text: $line.itemDescription
                        )
                        .textFieldStyle(.plain)
                        .frame(maxWidth: .infinity)

                        TextField(
                            "1",
                            value: $line.quantity,
                            formatter: decimalFormatter
                        )
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)

                        TextField(
                            "0.00",
                            value: $line.rate,
                            formatter: decimalFormatter
                        )
                        .multilineTextAlignment(.trailing)
                        .frame(width: 110)

                        Text(
                            money(
                                line.total,
                                currency: draft.currency
                            )
                        )
                        .frame(width: 120, alignment: .trailing)

                        Button {
                            removeLine(line.id)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .frame(width: 24)
                    }
                    .padding(.vertical, 8)

                    Divider()
                }

                HStack {
                    Button("Add line") {
                        addLine()
                    }

                    Spacer()
                }
                .padding(.top, 10)
            }

            Spacer()

            Text("1")
                .font(.caption)
                .frame(maxWidth: .infinity)
                .foregroundColor(.secondary)
        }
        .padding(52)
        .frame(width: 760)
        .frame(minHeight: 1010)
        .background(Color.white)
        .foregroundColor(.black)
        .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
    }
}

struct EditablePageTwo: View {
    @Binding var draft: InvoiceDraft
    let amountPaid: Double

    var balance: Double {
        max(draft.total - amountPaid, 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Amount")
                .font(.system(size: 22, weight: .bold))

            VStack(spacing: 10) {
                AmountRow(
                    label: "Subtotal",
                    value: money(
                        draft.subtotal,
                        currency: draft.currency
                    )
                )

                AmountRow(
                    label: "VAT",
                    value: draft.taxRate == 0
                        ? "N/A"
                        : money(
                            draft.tax,
                            currency: draft.currency
                        )
                )

                Divider()

                AmountRow(
                    label: "Total",
                    value: money(
                        draft.total,
                        currency: draft.currency
                    ),
                    bold: true
                )

                if amountPaid > 0 {
                    AmountRow(
                        label: "Paid",
                        value: money(
                            amountPaid,
                            currency: draft.currency
                        )
                    )

                    AmountRow(
                        label: "Balance",
                        value: money(
                            balance,
                            currency: draft.currency
                        ),
                        bold: true
                    )
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Payment Terms")
                    .font(.headline)

                MultilineField(
                    text: $draft.paymentTerms,
                    height: 116
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Banking Details")
                    .font(.headline)

                MultilineField(
                    text: $draft.bankingDetails,
                    height: 150
                )

                DetailRow(
                    label: "Payment reference",
                    value: draft.documentNumber.isEmpty
                        ? "Assigned on issue"
                        : draft.documentNumber
                )
            }

            HStack {
                PlainField(
                    label: "Currency",
                    text: $draft.currency
                )
                .frame(width: 180)

                PlainNumberField(
                    label: "Tax rate %",
                    value: $draft.taxRate
                )
                .frame(width: 180)

                Spacer()
            }

            Spacer()

            Text("2")
                .font(.caption)
                .frame(maxWidth: .infinity)
                .foregroundColor(.secondary)
        }
        .padding(52)
        .frame(width: 760)
        .frame(minHeight: 1010)
        .background(Color.white)
        .foregroundColor(.black)
        .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
    }
}

// MARK: - Controls

struct PlainField: View {
    let label: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)

            TextField("", text: $text)
                .textFieldStyle(.plain)
                .padding(7)
                .background(Color.black.opacity(0.045))
                .cornerRadius(4)
        }
    }
}

struct PlainNumberField: View {
    let label: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)

            TextField(
                "",
                value: $value,
                formatter: decimalFormatter
            )
            .textFieldStyle(.plain)
            .padding(7)
            .background(Color.black.opacity(0.045))
            .cornerRadius(4)
        }
    }
}

struct MultilineField: View {
    @Binding var text: String
    let height: CGFloat

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 13))
            .frame(height: height)
            .padding(5)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.black.opacity(0.12))
            )
    }
}

struct DateField: View {
    let label: String
    @Binding var date: Date

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            DatePicker(
                "",
                selection: $date,
                displayedComponents: .date
            )
            .labelsHidden()
        }
    }
}

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(label):")
                .font(.system(size: 13, weight: .semibold))

            Text(value)
        }
        .font(.system(size: 13))
    }
}

struct AmountRow: View {
    let label: String
    let value: String
    var bold = false

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
        }
        .font(.system(size: 13, weight: bold ? .bold : .regular))
    }
}

// MARK: - Payments

struct PaymentSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var date = Date()
    @State private var amount = 0.0
    @State private var type = "Deposit"
    @State private var method = "Bank transfer"
    @State private var reference = ""
    @State private var notes = ""

    let maximumAmount: Double
    let currency: String

    let onSave: (
        Date,
        Double,
        String,
        String,
        String,
        String
    ) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Record Payment")
                .font(.system(size: 22, weight: .bold))

            DatePicker(
                "Payment date",
                selection: $date,
                displayedComponents: .date
            )

            TextField(
                "Amount",
                value: $amount,
                formatter: decimalFormatter
            )

            Text(
                "Remaining balance: \(money(maximumAmount, currency: currency))"
            )
            .font(.caption)
            .foregroundColor(.secondary)

            TextField("Payment type", text: $type)
            TextField("Method", text: $method)
            TextField("Bank reference", text: $reference)
            TextField("Notes", text: $notes)

            HStack {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }

                Button("Record") {
                    onSave(
                        date,
                        amount,
                        type,
                        method,
                        reference,
                        notes
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    amount <= 0 || amount > maximumAmount + 0.005
                )
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear {
            if amount == 0 {
                amount = maximumAmount
            }
        }
    }
}

// MARK: - Draft browser

struct DraftBrowserView: View {
    @EnvironmentObject private var store: InvoiceStore
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var statusFilter = "All"

    private var documents: [RecentDraft] {
        store.allDrafts.filter { document in
            let matchesStatus = statusFilter == "All" ||
                displayStatus(for: document) == statusFilter

            let query = searchText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()

            let matchesSearch = query.isEmpty || [
                document.documentNumber,
                document.clientName,
                document.label,
                document.documentType,
                document.status
            ].contains { $0.lowercased().contains(query) }

            return matchesStatus && matchesSearch
        }
    }

    private func displayStatus(for document: RecentDraft) -> String {
        if document.documentType == "INVOICE",
           (document.status == "Issued" || document.status == "Partially Paid"),
           document.dueDate < Calendar.current.startOfDay(for: Date()) {
            return "Overdue"
        }

        return document.status
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Documents")
                .font(.system(size: 22, weight: .bold))

            HStack {
                TextField("Search number, client or project", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                Picker("Status", selection: $statusFilter) {
                    ForEach(
                        ["All", "Draft", "Issued", "Overdue", "Partially Paid", "Paid"],
                        id: \.self
                    ) { status in
                        Text(status).tag(status)
                    }
                }
                .frame(width: 170)
            }

            if store.allDrafts.isEmpty {
                Text("There are no saved documents.")
                    .foregroundColor(.secondary)
            } else if documents.isEmpty {
                Text("No documents match these filters.")
                    .foregroundColor(.secondary)
            } else {
                List(documents) { draft in
                    Button {
                        store.open(draft.id)
                        dismiss()
                    } label: {
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(
                                    draft.documentNumber.isEmpty
                                        ? draft.label
                                        : draft.documentNumber
                                )
                                .fontWeight(.medium)

                                Text(draft.label)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 3) {
                                Text(money(draft.total, currency: draft.currency))
                                    .monospacedDigit()
                                Text(displayStatus(for: draft))
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(
                                        displayStatus(for: draft) == "Overdue"
                                            ? .red
                                            : .secondary
                                    )

                                Text(
                                    draft.status == "Draft"
                                        ? "Open"
                                        : "Open & Edit"
                                )
                                .font(.caption2)
                                .foregroundColor(.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Spacer()

                Button("Close") {
                    dismiss()
                }
            }
        }
        .padding(24)
        .frame(width: 680, height: 520)
    }
}

// MARK: - PDF

@MainActor
enum PDFExporter {
    private static let pageSize = NSSize(
        width: 595,
        height: 842
    )

    private static let canvasWidth:
        CGFloat = 760

    /*
     A small reduction lets ordinary invoices remain
     on one page without making the text uncomfortably
     small.
    */
    private static let minimumOnePageScale:
        CGFloat = 0.56

    static func export(
        _ draft: InvoiceDraft,
        amountPaid: Double,
        to url: URL
    ) throws {
        let document = PDFDocument()

        let paper = Color.white

        let canvas = FlatInvoiceDocument(
            draft: .constant(draft),
            amountPaid: amountPaid,
            addLine: {},
            removeLine: { _ in },
            isExporting: true
        )
        .frame(
            width: canvasWidth,
            alignment: .topLeading
        )
        .fixedSize(
            horizontal: false,
            vertical: true
        )

        let naturalHeight = measuredHeight(
            canvas
        )

        guard naturalHeight > 1 else {
            throw NSError(
                domain: "INV",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not measure the PDF document."
                ]
            )
        }

        let widthScale =
            pageSize.width / canvasWidth

        let onePageScale = min(
            widthScale,
            (
                pageSize.height - 2
            ) / naturalHeight
        )

        if onePageScale >= minimumOnePageScale {
            guard let page = renderCanvasPage(
                canvas,
                naturalHeight:
                    naturalHeight,
                scale:
                    onePageScale,
                paper:
                    paper
            ) else {
                throw NSError(
                    domain: "INV",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Could not render the PDF."
                    ]
                )
            }

            document.insert(
                page,
                at: 0
            )
        } else {
            /*
             Longer documents are rendered as complete
             semantic sections instead of slicing through
             one continuous canvas. This prevents text
             lines and paragraphs being cut at page edges.
            */
            guard let firstPage = renderFixedPage(
                PrintablePageOne(
                    draft: draft
                ),
                paper: paper
            ) else {
                throw NSError(
                    domain: "INV",
                    code: 3,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Could not render page one."
                    ]
                )
            }

            guard let secondPage = renderFixedPage(
                PrintablePageTwo(
                    draft: draft,
                    amountPaid: amountPaid
                ),
                paper: paper
            ) else {
                throw NSError(
                    domain: "INV",
                    code: 4,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Could not render page two."
                    ]
                )
            }

            document.insert(
                firstPage,
                at: 0
            )

            document.insert(
                secondPage,
                at: 1
            )
        }

        guard document.write(to: url) else {
            throw NSError(
                domain: "INV",
                code: 5,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not write the PDF."
                ]
            )
        }
    }

    private static func measuredHeight<
        Content: View
    >(
        _ view: Content
    ) -> CGFloat {
        let hostingView = NSHostingView(
            rootView: view
        )

        hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: canvasWidth,
            height: 1
        )

        hostingView.needsLayout = true
        hostingView.layoutSubtreeIfNeeded()

        return max(
            ceil(
                hostingView.fittingSize.height
            ),
            1
        )
    }

    private static func renderCanvasPage<
        Content: View
    >(
        _ view: Content,
        naturalHeight: CGFloat,
        scale: CGFloat,
        paper: Color
    ) -> PDFPage? {
        let renderedWidth =
            canvasWidth * scale

        let horizontalOffset = max(
            (
                pageSize.width
                    - renderedWidth
            ) / 2,
            0
        )

        let pageView = ZStack(
            alignment: .topLeading
        ) {
            paper

            view
                .frame(
                    width: canvasWidth,
                    height: naturalHeight,
                    alignment: .topLeading
                )
                .scaleEffect(
                    scale,
                    anchor: .topLeading
                )
                .offset(
                    x: horizontalOffset
                )
        }
        .frame(
            width: pageSize.width,
            height: pageSize.height,
            alignment: .topLeading
        )
        .clipped()

        return pdfPage(
            from: pageView
        )
    }

    private static func renderFixedPage<
        Content: View
    >(
        _ view: Content,
        paper: Color
    ) -> PDFPage? {
        let pageView = view
            .frame(
                width: pageSize.width,
                height: pageSize.height,
                alignment: .topLeading
            )
            .background(paper)
            .clipped()

        return pdfPage(
            from: pageView
        )
    }

    private static func pdfPage<
        Content: View
    >(
        from view: Content
    ) -> PDFPage? {
        if #available(macOS 13.0, *),
           let page = imageRendererPDFPage(from: view) {
            return page
        }

        let hostingView = NSHostingView(
            rootView: view
        )

        hostingView.frame = NSRect(
            origin: .zero,
            size: pageSize
        )

        /*
         SwiftUI-backed AppKit views can produce an empty
         dataWithPDF result when they have never belonged
         to a window. An off-screen borderless window gives
         the hosting view a complete rendering environment
         without showing anything to the user.
        */
        let window = NSWindow(
            contentRect: NSRect(
                x: -10_000,
                y: -10_000,
                width: pageSize.width,
                height: pageSize.height
            ),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.orderBack(nil)

        hostingView.needsLayout = true
        hostingView.layoutSubtreeIfNeeded()
        hostingView.needsDisplay = true
        hostingView.displayIfNeeded()

        RunLoop.main.run(
            until: Date().addingTimeInterval(0.02)
        )

        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        let data = hostingView.dataWithPDF(
            inside: hostingView.bounds
        )

        window.contentView = nil
        window.close()

        return PDFDocument(
            data: data
        )?.page(at: 0)
    }

    @available(macOS 13.0, *)
    private static func imageRendererPDFPage<
        Content: View
    >(
        from view: Content
    ) -> PDFPage? {
        let data = NSMutableData()

        guard let consumer = CGDataConsumer(
            data: data as CFMutableData
        ) else {
            return nil
        }

        var mediaBox = CGRect(
            origin: .zero,
            size: pageSize
        )

        guard let context = CGContext(
            consumer: consumer,
            mediaBox: &mediaBox,
            nil
        ) else {
            return nil
        }

        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(
            width: pageSize.width,
            height: pageSize.height
        )

        context.beginPDFPage(nil)
        renderer.render { _, draw in
            draw(context)
        }
        context.endPDFPage()
        context.closePDF()

        return PDFDocument(
            data: data as Data
        )?.page(at: 0)
    }
}

struct PrintableSinglePage: View {
    let draft: InvoiceDraft
    let amountPaid: Double

    private var balance: Double {
        max(
            draft.total - amountPaid,
            0
        )
    }

    private var dateLabel: String {
        draft.documentType == "QUOTE"
            ? "VALID UNTIL"
            : "DUE DATE"
    }

    private var referenceLabel: String {
        draft.documentType == "QUOTE"
            ? "QUOTE REFERENCE"
            : "PAYMENT REFERENCE"
    }

    private var termsLabel: String {
        draft.documentType == "QUOTE"
            ? "QUOTE TERMS & ACCEPTANCE"
            : "PAYMENT TERMS"
    }

    private var totalLabel: String {
        if draft.documentType == "QUOTE" {
            return "QUOTED TOTAL"
        }

        if amountPaid > 0 {
            return "BALANCE DUE"
        }

        return "AMOUNT DUE"
    }

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 14
        ) {
            header
            parties
            project
            lineItems
            footer
        }
        .padding(38)
        .foregroundColor(.black)
    }

    private var header: some View {
        VStack(
            alignment: .leading,
            spacing: 13
        ) {
            HStack(
                alignment: .top
            ) {
                VStack(
                    alignment: .leading,
                    spacing: 4
                ) {
                    Text(
                        draft.documentNumber.isEmpty
                            ? "DRAFT"
                            : draft.documentNumber
                    )
                    .font(
                        .system(
                            size: 10,
                            weight: .semibold
                        )
                    )

                    Text(
                        invDateFormatter.string(
                            from: draft.issueDate
                        )
                    )
                    .font(.system(size: 9.5))
                    .foregroundColor(
                        Color.black.opacity(0.56)
                    )
                }

                Spacer()

                Text(
                    invoiceDisplayTitle(
                        for: draft.documentType
                    )
                )
                .font(
                    .system(
                        size: 30,
                        weight: .bold
                    )
                )
            }

            HStack(
                alignment: .top,
                spacing: 24
            ) {
                if !draft.paymentStage.isEmpty {
                    PrintableCompactField(
                        label: "PAYMENT STAGE",
                        value: draft.paymentStage
                    )
                }

                PrintableCompactField(
                    label: dateLabel,
                    value:
                        invoiceDueDateText(
                            mode:
                                draft.dueDateMode,
                            date:
                                draft.dueDate
                        )
                )

                PrintableCompactField(
                    label: "CURRENCY",
                    value: draft.currency
                )
            }
        }
    }

    private var parties: some View {
        HStack(
            alignment: .top,
            spacing: 34
        ) {
            PrintableBlock(
                heading: "From",
                lines: [
                    draft.senderName,
                    draft.senderAddress
                ]
            )

            PrintableBlock(
                heading: "Bill To",
                lines: [
                    draft.clientName,
                    draft.clientContact,
                    draft.clientAddress
                ]
            )
        }
    }

    @ViewBuilder
    private var project: some View {
        if !draft.projectName.isEmpty
            || !draft.projectDescription.isEmpty {

            VStack(
                alignment: .leading,
                spacing: 5
            ) {
                Text("Project")
                    .font(
                        .system(
                            size: 12,
                            weight: .semibold
                        )
                    )

                if !draft.projectName.isEmpty {
                    Text(draft.projectName)
                        .font(
                            .system(
                                size: 10.5,
                                weight: .semibold
                            )
                        )
                }

                if !draft.projectDescription.isEmpty {
                    Text(
                        draft.projectDescription
                    )
                    .font(.system(size: 9.5))
                    .fixedSize(
                        horizontal: false,
                        vertical: true
                    )
                }
            }
        }
    }

    private var lineItems: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("DESCRIPTION")
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )

                Text("QTY")
                    .frame(
                        width: 40,
                        alignment: .trailing
                    )

                Text("RATE")
                    .frame(
                        width: 82,
                        alignment: .trailing
                    )

                Text("AMOUNT")
                    .frame(
                        width: 92,
                        alignment: .trailing
                    )
            }
            .font(
                .system(
                    size: 8,
                    weight: .semibold
                )
            )
            .foregroundColor(
                Color.black.opacity(0.56)
            )
            .padding(.bottom, 7)

            Divider()

            ForEach(draft.lines) { line in
                HStack(
                    alignment: .top,
                    spacing: 10
                ) {
                    Text(line.itemDescription)
                        .fixedSize(
                            horizontal: false,
                            vertical: true
                        )
                        .frame(
                            maxWidth: .infinity,
                            alignment: .leading
                        )

                    Text(
                        decimalFormatter.string(
                            from: NSNumber(
                                value: line.quantity
                            )
                        ) ?? ""
                    )
                    .frame(
                        width: 40,
                        alignment: .trailing
                    )

                    Text(
                        money(
                            line.rate,
                            currency:
                                draft.currency
                        )
                    )
                    .frame(
                        width: 82,
                        alignment: .trailing
                    )

                    Text(
                        money(
                            line.total,
                            currency:
                                draft.currency
                        )
                    )
                    .frame(
                        width: 92,
                        alignment: .trailing
                    )
                }
                .font(.system(size: 9))
                .padding(.vertical, 7)

                Divider()
            }
        }
    }

    private var footer: some View {
        HStack(
            alignment: .top,
            spacing: 34
        ) {
            VStack(
                alignment: .leading,
                spacing: 15
            ) {
                if !draft.paymentTerms.isEmpty {
                    PrintableTextSection(
                        heading: termsLabel,
                        text: draft.paymentTerms
                    )
                }

                if draft.documentType != "QUOTE"
                    && !draft.bankingDetails.isEmpty {

                    PrintableTextSection(
                        heading: "BANKING DETAILS",
                        text:
                            draft.bankingDetails
                    )
                }

                PrintableCompactField(
                    label: referenceLabel,
                    value:
                        draft.documentNumber.isEmpty
                        ? "DRAFT"
                        : draft.documentNumber
                )
            }
            .frame(
                maxWidth: .infinity,
                alignment: .topLeading
            )

            VStack(spacing: 9) {
                AmountRow(
                    label: "Subtotal",
                    value:
                        money(
                            draft.subtotal,
                            currency:
                                draft.currency
                        )
                )

                AmountRow(
                    label: "VAT",
                    value:
                        draft.taxRate == 0
                        ? "N/A"
                        : money(
                            draft.tax,
                            currency:
                                draft.currency
                        )
                )

                Divider()

                AmountRow(
                    label: totalLabel,
                    value:
                        money(
                            amountPaid > 0
                                ? balance
                                : draft.total,
                            currency:
                                draft.currency
                        ),
                    bold: true
                )

                if amountPaid > 0 {
                    AmountRow(
                        label: "Amount paid",
                        value:
                            money(
                                amountPaid,
                                currency:
                                    draft.currency
                            )
                    )
                }
            }
            .frame(width: 205)
        }
    }
}


struct PrintableCompactField: View {
    let label: String
    let value: String

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 3
        ) {
            Text(label)
                .font(
                    .system(
                        size: 7.5,
                        weight: .semibold
                    )
                )
                .foregroundColor(
                    Color.black.opacity(0.56)
                )

            Text(value)
                .font(.system(size: 9.5))
                .fixedSize(
                    horizontal: false,
                    vertical: true
                )
        }
        .frame(
            maxWidth: .infinity,
            alignment: .leading
        )
    }
}


struct PrintableTextSection: View {
    let heading: String
    let text: String

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 5
        ) {
            Text(heading)
                .font(
                    .system(
                        size: 8,
                        weight: .semibold
                    )
                )
                .foregroundColor(
                    Color.black.opacity(0.56)
                )

            Text(text)
                .font(.system(size: 9))
                .fixedSize(
                    horizontal: false,
                    vertical: true
                )
        }
    }
}


struct PrintablePageOne: View {
    let draft: InvoiceDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Spacer()

                Text(invoiceDisplayTitle(for: draft.documentType))
                    .font(.system(size: 27, weight: .bold))
            }

            DetailRow(
                label: "\(draft.documentType.capitalized) number",
                value: draft.documentNumber.isEmpty
                    ? "DRAFT"
                    : draft.documentNumber
            )

            DetailRow(
                label: "\(draft.documentType.capitalized) date",
                value: invDateFormatter.string(from: draft.issueDate)
            )

            if !draft.paymentStage.isEmpty {
                DetailRow(
                    label: "Payment stage",
                    value: draft.paymentStage
                )
            }

            HStack(alignment: .top, spacing: 28) {
                PrintableBlock(
                    heading: "From",
                    lines: [
                        draft.senderName,
                        draft.senderAddress
                    ]
                )

                PrintableBlock(
                    heading: "Bill To",
                    lines: [
                        draft.clientName,
                        draft.clientAddress,
                        draft.clientContact
                    ]
                )
            }

            Text("Project")
                .font(.headline)

            if !draft.projectName.isEmpty {
                Text(draft.projectName)
                    .font(.system(size: 13, weight: .semibold))
            }

            Text(draft.projectDescription)
                .font(.system(size: 10.5))

            HStack {
                Text("Description")
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("Quantity")
                    .frame(width: 58, alignment: .trailing)

                Text("Rate")
                    .frame(width: 88, alignment: .trailing)

                Text("Amount")
                    .frame(width: 96, alignment: .trailing)
            }
            .font(.system(size: 9, weight: .semibold))
            .padding(.vertical, 7)

            Divider()

            ForEach(draft.lines) { line in
                HStack(alignment: .top) {
                    Text(line.itemDescription)
                        .frame(
                            maxWidth: .infinity,
                            alignment: .leading
                        )

                    Text(
                        decimalFormatter.string(
                            from: NSNumber(value: line.quantity)
                        ) ?? ""
                    )
                    .frame(width: 58, alignment: .trailing)

                    Text(
                        money(
                            line.rate,
                            currency: draft.currency
                        )
                    )
                    .frame(width: 88, alignment: .trailing)

                    Text(
                        money(
                            line.total,
                            currency: draft.currency
                        )
                    )
                    .frame(width: 96, alignment: .trailing)
                }
                .font(.system(size: 9.5))
                .padding(.vertical, 7)

                Divider()
            }

            Spacer()

            Text("1")
                .font(.system(size: 9))
                .frame(maxWidth: .infinity)
        }
        .padding(42)
        .foregroundColor(.black)
    }
}

struct PrintablePageTwo: View {
    let draft: InvoiceDraft
    let amountPaid: Double

    private var balance: Double {
        max(
            draft.total - amountPaid,
            0
        )
    }

    private var totalLabel: String {
        if draft.documentType == "QUOTE" {
            return "Quoted Total"
        }

        if amountPaid > 0 {
            return "Balance Due"
        }

        return "Amount Due"
    }

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 24
        ) {
            HStack(
                alignment: .top
            ) {
                Text(
                    invoiceDisplayTitle(
                        for: draft.documentType
                    )
                )
                .font(
                    .system(
                        size: 28,
                        weight: .bold
                    )
                )

                Spacer()

                Text(
                    draft.documentNumber.isEmpty
                        ? "DRAFT"
                        : draft.documentNumber
                )
                .font(
                    .system(
                        size: 11,
                        weight: .semibold
                    )
                )
            }

            HStack(
                alignment: .top,
                spacing: 46
            ) {
                VStack(
                    alignment: .leading,
                    spacing: 24
                ) {
                    if !draft.paymentTerms.isEmpty {
                        PrintableTextSection(
                            heading:
                                draft.documentType
                                    == "QUOTE"
                                ? "QUOTE TERMS & ACCEPTANCE"
                                : "PAYMENT TERMS",
                            text:
                                draft.paymentTerms
                        )
                    }

                    if draft.documentType != "QUOTE"
                        && !draft.bankingDetails.isEmpty {

                        PrintableTextSection(
                            heading:
                                "BANKING DETAILS",
                            text:
                                draft.bankingDetails
                        )
                    }

                    PrintableCompactField(
                        label:
                            draft.documentType
                                == "QUOTE"
                            ? "QUOTE REFERENCE"
                            : "PAYMENT REFERENCE",
                        value:
                            draft.documentNumber.isEmpty
                            ? "DRAFT"
                            : draft.documentNumber
                    )
                }
                .frame(
                    maxWidth: .infinity,
                    alignment: .topLeading
                )

                VStack(spacing: 11) {
                    AmountRow(
                        label: "Subtotal",
                        value:
                            money(
                                draft.subtotal,
                                currency:
                                    draft.currency
                            )
                    )

                    AmountRow(
                        label: "VAT",
                        value:
                            draft.taxRate == 0
                            ? "N/A"
                            : money(
                                draft.tax,
                                currency:
                                    draft.currency
                            )
                    )

                    Divider()

                    AmountRow(
                        label: totalLabel,
                        value:
                            money(
                                amountPaid > 0
                                    ? balance
                                    : draft.total,
                                currency:
                                    draft.currency
                            ),
                        bold: true
                    )

                    if amountPaid > 0 {
                        AmountRow(
                            label: "Amount paid",
                            value:
                                money(
                                    amountPaid,
                                    currency:
                                        draft.currency
                                )
                        )
                    }
                }
                .frame(width: 215)
            }

            Spacer()

            Text("2")
                .font(.system(size: 9))
                .frame(
                    maxWidth: .infinity
                )
        }
        .padding(42)
        .foregroundColor(.black)
    }
}

struct PrintableBlock: View {
    let heading: String
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(heading)
                .font(.headline)

            ForEach(
                Array(lines.enumerated()),
                id: \.offset
            ) { _, line in
                if !line.isEmpty {
                    Text(line)
                        .font(.system(size: 10))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Native menus

struct INVCommands: Commands {
    @ObservedObject var store: InvoiceStore

    var body: some Commands {
        // Standard Edit menu.
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") {
                _ = NSApp.sendAction(
                    #selector(UndoManager.undo),
                    to: nil,
                    from: nil
                )
            }
            .keyboardShortcut(
                "z",
                modifiers: .command
            )

            Button("Redo") {
                _ = NSApp.sendAction(
                    #selector(UndoManager.redo),
                    to: nil,
                    from: nil
                )
            }
            .keyboardShortcut(
                "z",
                modifiers: [
                    .command,
                    .shift
                ]
            )
        }

        // Familiar File menu:
        // create, open, save, export and protect files.
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") {
                _ = NSApp.sendAction(
                    #selector(NSText.cut(_:)),
                    to: nil,
                    from: nil
                )
            }
            .keyboardShortcut(
                "x",
                modifiers: .command
            )

            Button("Copy") {
                _ = NSApp.sendAction(
                    #selector(NSText.copy(_:)),
                    to: nil,
                    from: nil
                )
            }
            .keyboardShortcut(
                "c",
                modifiers: .command
            )

            Button("Paste") {
                _ = NSApp.sendAction(
                    #selector(NSText.paste(_:)),
                    to: nil,
                    from: nil
                )
            }
            .keyboardShortcut(
                "v",
                modifiers: .command
            )

            Button("Paste and Match Style") {
                _ = NSApp.sendAction(
                    #selector(NSTextView.pasteAsPlainText(_:)),
                    to: nil,
                    from: nil
                )
            }
            .keyboardShortcut(
                "v",
                modifiers: [
                    .command,
                    .option,
                    .shift
                ]
            )

            Divider()

            Button("Select All") {
                _ = NSApp.sendAction(
                    #selector(NSText.selectAll(_:)),
                    to: nil,
                    from: nil
                )
            }
            .keyboardShortcut(
                "a",
                modifiers: .command
            )
        }

        CommandGroup(replacing: .newItem) {
            Button("New Invoice") {
                store.newDocument(type: "INVOICE")
            }
            .keyboardShortcut(
                "n",
                modifiers: .command
            )

            Button("New Quote") {
                store.newDocument(type: "QUOTE")
            }
            .keyboardShortcut(
                "n",
                modifiers: [
                    .command,
                    .shift
                ]
            )

            Divider()

            Menu("Open Recent Draft") {
                if store.recentDrafts.isEmpty {
                    Text("No Saved Drafts")
                } else {
                    ForEach(
                        store.recentDrafts
                    ) { draft in
                        Button(draft.label) {
                            store.open(
                                draft.id
                            )
                        }
                    }
                }
            }

            Button("Open Documents…") {
                store.loadDrafts()
                store.showDraftBrowser = true
            }
            .keyboardShortcut(
                "o",
                modifiers: .command
            )

            Button("Import Invoice…") {
                store.importInvoice()
            }
            .keyboardShortcut(
                "o",
                modifiers: [.command, .option]
            )
        }

        CommandGroup(replacing: .saveItem) {
            Button(
                store.current.isIssued
                ? "Save Changes"
                : "Save Draft"
            ) {
                store.saveDraft()
            }
            .keyboardShortcut(
                "s",
                modifiers: .command
            )

            Divider()

            Button("Export PDF…") {
                store.exportPDF()
            }
            .keyboardShortcut(
                "e",
                modifiers: [
                    .command,
                    .shift
                ]
            )

            Button("Export 50/50 Pair…") {
                store.exportFiftyFiftyPair()
            }
            .keyboardShortcut(
                "e",
                modifiers: [
                    .command,
                    .option,
                    .shift
                ]
            )
            .disabled(
                store.current.documentType
                    != "INVOICE"
            )


            Divider()

            Button("Back Up Database") {
                store.backupNow()
            }

            Button(
                "Export Accountant Data"
            ) {
                store.exportAccountantData()
            }
        }

        // The main document workflow remains visible.
        CommandMenu("Issue") {
            if store.current.documentType == "QUOTE" {
                Button(
                    "Convert Quote to Invoice"
                ) {
                    store.convertCurrentQuoteToInvoice()
                }
                .keyboardShortcut(
                    "i",
                    modifiers: [
                        .command,
                        .option
                    ]
                )

                Divider()
            }

            Button(
                "Issue \(store.current.documentType.capitalized)"
            ) {
                store.showIssueConfirmation =
                    true
            }
            .keyboardShortcut(
                "i",
                modifiers: [
                    .command,
                    .shift
                ]
            )
            .disabled(
                store.current.isIssued
            )

            Divider()

            Button("Record Payment…") {
                store.showPaymentSheet = true
            }
            .keyboardShortcut(
                "p",
                modifiers: [
                    .command,
                    .shift
                ]
            )
            .disabled(
                !store.current.isIssued
                || store.current.documentType
                    != "INVOICE"
            )
        }

        // Accounting remains a distinct workspace.
        CommandMenu("Books") {
            Button("Open Books…") {
                store.showBooks = true
            }
            .keyboardShortcut(
                "b",
                modifiers: [
                    .command,
                    .shift
                ]
            )

            Divider()

            Button(
                "Export Accountant Pack"
            ) {
                do {
                    _ = try AccountingRepository
                        .shared
                        .exportDefaultAccountantPack()
                } catch {
                    AccountingRepository
                        .shared
                        .message =
                            error.localizedDescription
                }
            }
        }
    }
}


// MARK: - App

final class INVAppDelegate:
    NSObject,
    NSApplicationDelegate {

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        true
    }
}


#if !INV_TEST
@main
struct INVApp: App {
    
    @NSApplicationDelegateAdaptor(
        INVAppDelegate.self
    )
    private var appDelegate

    @StateObject private var store = InvoiceStore()

    var body: some Scene {
        WindowGroup("INV") {
            InvoiceEditorView()
                .environmentObject(store)
        }
        .windowStyle(HiddenTitleBarWindowStyle())
        .commands {
            INVCommands(store: store)
        }
    }
}
#endif
