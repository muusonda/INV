import SwiftUI
import AppKit
import Foundation
import UniformTypeIdentifiers
import SQLite3

private let sqliteTransient = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)

private let accountingDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

private let accountingDisplayDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter
}()

private let accountingNumberFormatter: NumberFormatter = {
    let formatter = NumberFormatter()

    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = 2
    formatter.usesGroupingSeparator = true

    return formatter
}()


private let booksPaper = Color(
    red: 0.965,
    green: 0.968,
    blue: 0.971
)

private let booksInk = Color(
    red: 0.08,
    green: 0.08,
    blue: 0.08
)

private let booksBorder = Color.black.opacity(0.13)

private let booksMuted = Color.black.opacity(0.57)

private let booksPanel = Color.white.opacity(0.42)

private let booksSuccess = Color(
    red: 0.13,
    green: 0.43,
    blue: 0.28
)

private let booksWarning = Color(
    red: 0.65,
    green: 0.36,
    blue: 0.08
)


private func booksMoney(_ amount: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "ZAR"
    formatter.currencySymbol = "R"
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2

    return formatter.string(
        from: NSNumber(value: amount)
    ) ?? "R\(String(format: "%.2f", amount))"
}

private func booksCSV(_ value: String) -> String {
    "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
}

func invoiceDisplayTitle(
    for documentType: String
) -> String {
    if documentType == "QUOTE" {
        return "QUOTE"
    }

    let profile = AccountingRepository.shared.profile

    if profile.vatRegistered &&
        !profile.vatNumber
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            .isEmpty {
        return "TAX INVOICE"
    }

    return "INVOICE"
}

// MARK: - Models

struct CompanyProfileData {
    var legalName = ""
    var registrationNumber = ""
    var incomeTaxReference = ""

    var vatRegistered = false
    var vatNumber = ""

    var address = ""
    var incorporationDate = Date()

    var financialYearEndMonth = 2
    var financialYearEndDay = 28

    var accountingFramework = "IFRS for SMEs"
    var employerRegistered = false

    var averageEmployees = 0
    var annualTurnover = 0.0
    var thirdPartyLiabilities = 0.0
    var beneficialInterestHolders = 1

    var publicInterestScore: Int {
        averageEmployees
        + Int(ceil(annualTurnover / 1_000_000))
        + Int(ceil(thirdPartyLiabilities / 1_000_000))
        + beneficialInterestHolders
    }
}

struct LedgerAccount: Identifiable, Hashable {
    let code: String
    let name: String
    let type: String
    let active: Bool

    var id: String {
        code
    }

    var displayName: String {
        "\(code) — \(name)"
    }
}

struct ReportRow: Identifiable {
    let id: String
    let code: String
    let name: String
    let type: String
    let debit: Double
    let credit: Double
    let balance: Double
}

struct ReceivableRow: Identifiable {
    let id: String
    let invoiceNumber: String
    let clientName: String
    let issueDate: Date
    let dueDate: Date
    let total: Double
    let paid: Double

    var balance: Double {
        max(total - paid, 0)
    }

    var ageDays: Int {
        Calendar.current.dateComponents(
            [.day],
            from: dueDate,
            to: Date()
        ).day ?? 0
    }

    var bucket: String {
        if ageDays <= 0 {
            return "Current"
        }

        if ageDays <= 30 {
            return "1–30"
        }

        if ageDays <= 60 {
            return "31–60"
        }

        if ageDays <= 90 {
            return "61–90"
        }

        return "90+"
    }
}

struct BankTransactionRow: Identifiable {
    let id: String
    let date: Date
    let description: String
    let amount: Double
    let reference: String
    let matchedEntryId: String
    let reconciled: Bool
}

struct ComplianceRow: Identifiable {
    let id: String
    let title: String
    let category: String
    let dueDate: Date
    let note: String
}

struct SourceDocumentRow: Identifiable {
    let id: String
    let fileName: String
    let linkedType: String
    let linkedId: String
    let storedPath: String
    let addedAt: Date
    let retentionUntil: Date
}

enum SQLValue {
    case text(String)
    case double(Double)
    case integer(Int)
    case null
}

enum AccountingError: LocalizedError {
    case database(String)
    case validation(String)

    var errorDescription: String? {
        switch self {
        case .database(let message):
            return message
        case .validation(let message):
            return message
        }
    }
}

// MARK: - Repository

final class AccountingRepository: ObservableObject {
    static let shared = AccountingRepository()

    @Published private(set) var profile =
        CompanyProfileData()

    @Published private(set) var accounts:
        [LedgerAccount] = []

    @Published private(set) var bankTransactions:
        [BankTransactionRow] = []

    @Published private(set) var sourceDocuments:
        [SourceDocumentRow] = []

    @Published var message = "Books ready"

    private var database: OpaquePointer?
    private let databaseURL: URL
    private let documentsDirectory: URL

    private init() {
        let fileManager = FileManager.default

        let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        let root = support.appendingPathComponent(
            "INV",
            isDirectory: true
        )

        let dataDirectory = root.appendingPathComponent(
            "data",
            isDirectory: true
        )

        documentsDirectory = root.appendingPathComponent(
            "documents/source-documents",
            isDirectory: true
        )

        try? fileManager.createDirectory(
            at: dataDirectory,
            withIntermediateDirectories: true
        )

        try? fileManager.createDirectory(
            at: documentsDirectory,
            withIntermediateDirectories: true
        )

        databaseURL = dataDirectory.appendingPathComponent(
            "accounting.sqlite3"
        )

        do {
            try openDatabase()
            try migrate()
            try seedAccounts()

            profile = try loadProfile()
            refresh()
        } catch {
            message = error.localizedDescription
        }
    }

    deinit {
        sqlite3_close(database)
    }

    private func openDatabase() throws {
        let flags =
            SQLITE_OPEN_CREATE
            | SQLITE_OPEN_READWRITE
            | SQLITE_OPEN_FULLMUTEX

        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            flags,
            nil
        ) == SQLITE_OK else {
            throw AccountingError.database(
                "Could not open the accounting database."
            )
        }

        try execute("PRAGMA foreign_keys = ON;")
        try execute("PRAGMA journal_mode = WAL;")
    }

    private func migrate() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS company_profile (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                legal_name TEXT NOT NULL DEFAULT '',
                registration_number TEXT NOT NULL DEFAULT '',
                income_tax_reference TEXT NOT NULL DEFAULT '',
                vat_registered INTEGER NOT NULL DEFAULT 0,
                vat_number TEXT NOT NULL DEFAULT '',
                address TEXT NOT NULL DEFAULT '',
                incorporation_date REAL NOT NULL,
                financial_year_end_month INTEGER NOT NULL DEFAULT 2,
                financial_year_end_day INTEGER NOT NULL DEFAULT 28,
                accounting_framework TEXT NOT NULL DEFAULT 'IFRS for SMEs',
                employer_registered INTEGER NOT NULL DEFAULT 0,
                average_employees INTEGER NOT NULL DEFAULT 0,
                annual_turnover REAL NOT NULL DEFAULT 0,
                third_party_liabilities REAL NOT NULL DEFAULT 0,
                beneficial_interest_holders INTEGER NOT NULL DEFAULT 1
            );

            CREATE TABLE IF NOT EXISTS accounts (
                code TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                account_type TEXT NOT NULL,
                active INTEGER NOT NULL DEFAULT 1
            );

            CREATE TABLE IF NOT EXISTS journal_entries (
                id TEXT PRIMARY KEY,
                entry_date REAL NOT NULL,
                reference TEXT NOT NULL,
                description TEXT NOT NULL,
                source_type TEXT NOT NULL,
                source_id TEXT UNIQUE,
                related_source_id TEXT,
                locked INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS journal_lines (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                entry_id TEXT NOT NULL,
                account_code TEXT NOT NULL,
                debit REAL NOT NULL DEFAULT 0,
                credit REAL NOT NULL DEFAULT 0,
                memo TEXT NOT NULL DEFAULT '',
                FOREIGN KEY(entry_id)
                    REFERENCES journal_entries(id)
                    ON DELETE CASCADE,
                FOREIGN KEY(account_code)
                    REFERENCES accounts(code)
            );

            CREATE TABLE IF NOT EXISTS receivables (
                invoice_id TEXT PRIMARY KEY,
                invoice_number TEXT NOT NULL,
                client_name TEXT NOT NULL,
                issue_date REAL NOT NULL,
                due_date REAL NOT NULL,
                total REAL NOT NULL DEFAULT 0,
                paid REAL NOT NULL DEFAULT 0
            );

            CREATE TABLE IF NOT EXISTS bank_transactions (
                id TEXT PRIMARY KEY,
                transaction_date REAL NOT NULL,
                description TEXT NOT NULL,
                amount REAL NOT NULL,
                reference TEXT NOT NULL DEFAULT '',
                matched_entry_id TEXT,
                reconciled INTEGER NOT NULL DEFAULT 0,
                imported_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS source_documents (
                id TEXT PRIMARY KEY,
                linked_type TEXT NOT NULL,
                linked_id TEXT NOT NULL,
                original_name TEXT NOT NULL,
                stored_path TEXT NOT NULL,
                added_at REAL NOT NULL,
                retention_until REAL NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_journal_date
                ON journal_entries(entry_date);

            CREATE INDEX IF NOT EXISTS idx_journal_source
                ON journal_entries(source_type, source_id);

            CREATE INDEX IF NOT EXISTS idx_lines_account
                ON journal_lines(account_code);

            CREATE INDEX IF NOT EXISTS idx_receivables_due
                ON receivables(due_date);
            """
        )

        let count = try scalarInt(
            "SELECT COUNT(*) FROM company_profile;"
        )

        if count == 0 {
            try saveProfile(CompanyProfileData())
        }
    }

    private func seedAccounts() throws {
        let defaults: [(String, String, String)] = [
            ("1000", "Bank", "Asset"),
            ("1010", "Petty Cash", "Asset"),
            ("1100", "Accounts Receivable", "Asset"),
            ("1200", "VAT Input", "Asset"),
            ("1300", "Equipment", "Asset"),
            ("1400", "Accumulated Depreciation", "Contra Asset"),

            ("2000", "Accounts Payable", "Liability"),
            ("2100", "VAT Output", "Liability"),
            ("2200", "Income Tax Payable", "Liability"),
            ("2300", "Shareholder Loan", "Liability"),

            ("3000", "Share Capital", "Equity"),
            ("3100", "Retained Earnings", "Equity"),
            ("3200", "Owner Drawings", "Equity"),

            ("4000", "Sales", "Income"),
            ("4100", "Other Income", "Income"),

            ("5000", "Cost of Sales", "Expense"),
            ("6000", "Advertising", "Expense"),
            ("6010", "Bank Charges", "Expense"),
            ("6020", "Software and Subscriptions", "Expense"),
            ("6030", "Professional Fees", "Expense"),
            ("6040", "Travel", "Expense"),
            ("6050", "Telephone and Internet", "Expense"),
            ("6060", "Office Supplies", "Expense"),
            ("6070", "Rent", "Expense"),
            ("6080", "Insurance", "Expense"),
            ("6090", "Depreciation", "Expense"),
            ("6100", "Other Expenses", "Expense")
        ]

        for account in defaults {
            let statement = try prepare(
                """
                INSERT OR IGNORE INTO accounts
                    (code, name, account_type, active)
                VALUES (?, ?, ?, 1);
                """,
                [
                    .text(account.0),
                    .text(account.1),
                    .text(account.2)
                ]
            )

            defer {
                sqlite3_finalize(statement)
            }

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw databaseError()
            }
        }
    }

    func refresh() {
        do {
            accounts = try loadAccounts()
            bankTransactions = try loadBankTransactions()
            sourceDocuments = try loadSourceDocuments()
        } catch {
            message = error.localizedDescription
        }
    }

    func saveProfile(
        _ value: CompanyProfileData
    ) throws {
        if value.vatRegistered &&
            value.vatNumber
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                .isEmpty {
            throw AccountingError.validation(
                "Add the VAT registration number before enabling VAT."
            )
        }

        let statement = try prepare(
            """
            INSERT OR REPLACE INTO company_profile (
                id,
                legal_name,
                registration_number,
                income_tax_reference,
                vat_registered,
                vat_number,
                address,
                incorporation_date,
                financial_year_end_month,
                financial_year_end_day,
                accounting_framework,
                employer_registered,
                average_employees,
                annual_turnover,
                third_party_liabilities,
                beneficial_interest_holders
            ) VALUES (
                1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
            );
            """,
            [
                .text(value.legalName),
                .text(value.registrationNumber),
                .text(value.incomeTaxReference),
                .integer(value.vatRegistered ? 1 : 0),
                .text(value.vatNumber),
                .text(value.address),
                .double(value.incorporationDate.timeIntervalSince1970),
                .integer(value.financialYearEndMonth),
                .integer(value.financialYearEndDay),
                .text(value.accountingFramework),
                .integer(value.employerRegistered ? 1 : 0),
                .integer(value.averageEmployees),
                .double(value.annualTurnover),
                .double(value.thirdPartyLiabilities),
                .integer(value.beneficialInterestHolders)
            ]
        )

        defer {
            sqlite3_finalize(statement)
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError()
        }

        profile = value
        message = "Company profile saved"
    }

    func postInvoice(
        invoiceId: String,
        invoiceNumber: String,
        clientName: String,
        issueDate: Date,
        dueDate: Date,
        total: Double,
        tax: Double
    ) throws {
        guard total > 0 else {
            return
        }

        let sourceId = "invoice:\(invoiceId)"

        if try sourceExists(sourceId) {
            return
        }

        let recognisedTax =
            profile.vatRegistered
            ? max(min(tax, total), 0)
            : 0

        let sales = total - recognisedTax

        var lines: [
            (
                account: String,
                debit: Double,
                credit: Double,
                memo: String
            )
        ] = [
            (
                "1100",
                total,
                0,
                clientName
            ),
            (
                "4000",
                0,
                sales,
                invoiceNumber
            )
        ]

        if recognisedTax > 0 {
            lines.append(
                (
                    "2100",
                    0,
                    recognisedTax,
                    "Output VAT"
                )
            )
        }

        try insertJournal(
            date: issueDate,
            reference: invoiceNumber,
            description: "Invoice — \(clientName)",
            sourceType: "Invoice",
            sourceId: sourceId,
            relatedSourceId: invoiceId,
            locked: true,
            lines: lines
        )

        let statement = try prepare(
            """
            INSERT OR REPLACE INTO receivables (
                invoice_id,
                invoice_number,
                client_name,
                issue_date,
                due_date,
                total,
                paid
            ) VALUES (
                ?, ?, ?, ?, ?, ?,
                COALESCE(
                    (
                        SELECT paid
                        FROM receivables
                        WHERE invoice_id = ?
                    ),
                    0
                )
            );
            """,
            [
                .text(invoiceId),
                .text(invoiceNumber),
                .text(clientName),
                .double(issueDate.timeIntervalSince1970),
                .double(dueDate.timeIntervalSince1970),
                .double(total),
                .text(invoiceId)
            ]
        )

        defer {
            sqlite3_finalize(statement)
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError()
        }

        message = "\(invoiceNumber) posted to the ledger"
    }

    func replaceInvoice(
        invoiceId: String,
        invoiceNumber: String,
        clientName: String,
        issueDate: Date,
        dueDate: Date,
        total: Double,
        tax: Double
    ) throws {
        guard total > 0 else {
            throw AccountingError.validation(
                "The invoice total must be greater than zero."
            )
        }

        do {
            let statement = try prepare(
                "DELETE FROM journal_entries WHERE source_id = ?;",
                [.text("invoice:\(invoiceId)")]
            )

            guard sqlite3_step(statement) == SQLITE_DONE else {
                sqlite3_finalize(statement)
                throw databaseError()
            }
            sqlite3_finalize(statement)

            try postInvoice(
                invoiceId: invoiceId,
                invoiceNumber: invoiceNumber,
                clientName: clientName,
                issueDate: issueDate,
                dueDate: dueDate,
                total: total,
                tax: tax
            )

            message = "\(invoiceNumber) updated in the ledger"
        } catch {
            throw error
        }
    }

    func postPayment(
        paymentId: String,
        invoiceId: String,
        invoiceNumber: String,
        date: Date,
        amount: Double,
        reference: String
    ) throws {
        guard amount > 0 else {
            return
        }

        let sourceId = "payment:\(paymentId)"

        if try sourceExists(sourceId) {
            return
        }

        try insertJournal(
            date: date,
            reference: reference.isEmpty
                ? invoiceNumber
                : reference,
            description: "Payment — \(invoiceNumber)",
            sourceType: "Payment",
            sourceId: sourceId,
            relatedSourceId: invoiceId,
            locked: true,
            lines: [
                (
                    "1000",
                    amount,
                    0,
                    invoiceNumber
                ),
                (
                    "1100",
                    0,
                    amount,
                    invoiceNumber
                )
            ]
        )

        let statement = try prepare(
            """
            UPDATE receivables
            SET paid = MIN(total, paid + ?)
            WHERE invoice_id = ?;
            """,
            [
                .double(amount),
                .text(invoiceId)
            ]
        )

        defer {
            sqlite3_finalize(statement)
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError()
        }

        message = "Payment posted to the ledger"
    }

    func postExpense(
        date: Date,
        supplier: String,
        reference: String,
        expenseAccount: String,
        paymentAccount: String,
        totalAmount: Double,
        vatAmount: Double,
        notes: String
    ) throws {
        guard totalAmount > 0 else {
            throw AccountingError.validation(
                "Expense amount must be greater than zero."
            )
        }

        let recognisedVAT =
            profile.vatRegistered
            ? max(min(vatAmount, totalAmount), 0)
            : 0

        let netExpense = totalAmount - recognisedVAT
        let sourceId = "expense:\(UUID().uuidString)"

        var lines: [
            (
                account: String,
                debit: Double,
                credit: Double,
                memo: String
            )
        ] = [
            (
                expenseAccount,
                netExpense,
                0,
                supplier
            ),
            (
                paymentAccount,
                0,
                totalAmount,
                reference
            )
        ]

        if recognisedVAT > 0 {
            lines.insert(
                (
                    "1200",
                    recognisedVAT,
                    0,
                    "Input VAT"
                ),
                at: 1
            )
        }

        try insertJournal(
            date: date,
            reference: reference,
            description: supplier.isEmpty
                ? notes
                : "Expense — \(supplier)",
            sourceType: "Expense",
            sourceId: sourceId,
            relatedSourceId: "",
            locked: false,
            lines: lines
        )

        message = "Expense posted"
    }

    func postManualJournal(
        date: Date,
        reference: String,
        description: String,
        debitAccount: String,
        creditAccount: String,
        amount: Double
    ) throws {
        guard amount > 0 else {
            throw AccountingError.validation(
                "Journal amount must be greater than zero."
            )
        }

        guard debitAccount != creditAccount else {
            throw AccountingError.validation(
                "Debit and credit accounts must differ."
            )
        }

        try insertJournal(
            date: date,
            reference: reference,
            description: description,
            sourceType: "Manual Journal",
            sourceId: "journal:\(UUID().uuidString)",
            relatedSourceId: "",
            locked: false,
            lines: [
                (
                    debitAccount,
                    amount,
                    0,
                    description
                ),
                (
                    creditAccount,
                    0,
                    amount,
                    description
                )
            ]
        )

        message = "Journal posted"
    }

    private func insertJournal(
        date: Date,
        reference: String,
        description: String,
        sourceType: String,
        sourceId: String,
        relatedSourceId: String,
        locked: Bool,
        lines: [
            (
                account: String,
                debit: Double,
                credit: Double,
                memo: String
            )
        ]
    ) throws {
        let debitTotal = lines.reduce(0) {
            $0 + $1.debit
        }

        let creditTotal = lines.reduce(0) {
            $0 + $1.credit
        }

        guard abs(debitTotal - creditTotal) < 0.005 else {
            throw AccountingError.validation(
                "Journal debits and credits do not balance."
            )
        }

        try execute("BEGIN IMMEDIATE;")

        do {
            let entryId = UUID().uuidString

            let entryStatement = try prepare(
                """
                INSERT INTO journal_entries (
                    id,
                    entry_date,
                    reference,
                    description,
                    source_type,
                    source_id,
                    related_source_id,
                    locked,
                    created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                """,
                [
                    .text(entryId),
                    .double(date.timeIntervalSince1970),
                    .text(reference),
                    .text(description),
                    .text(sourceType),
                    .text(sourceId),
                    .text(relatedSourceId),
                    .integer(locked ? 1 : 0),
                    .double(Date().timeIntervalSince1970)
                ]
            )

            defer {
                sqlite3_finalize(entryStatement)
            }

            guard sqlite3_step(entryStatement) ==
                    SQLITE_DONE else {
                throw databaseError()
            }

            for line in lines {
                let lineStatement = try prepare(
                    """
                    INSERT INTO journal_lines (
                        entry_id,
                        account_code,
                        debit,
                        credit,
                        memo
                    ) VALUES (?, ?, ?, ?, ?);
                    """,
                    [
                        .text(entryId),
                        .text(line.account),
                        .double(line.debit),
                        .double(line.credit),
                        .text(line.memo)
                    ]
                )

                defer {
                    sqlite3_finalize(lineStatement)
                }

                guard sqlite3_step(lineStatement) ==
                        SQLITE_DONE else {
                    throw databaseError()
                }
            }

            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func trialBalance() -> [ReportRow] {
        loadReport(
            types: [],
            signed: false
        )
    }

    func incomeStatement() -> [ReportRow] {
        loadReport(
            types: ["Income", "Expense"],
            signed: true
        )
    }

    func balanceSheet() -> [ReportRow] {
        loadReport(
            types: [
                "Asset",
                "Contra Asset",
                "Liability",
                "Equity"
            ],
            signed: true
        )
    }

    private func loadReport(
        types: [String],
        signed: Bool
    ) -> [ReportRow] {
        do {
            let placeholders = types
                .map { _ in "?" }
                .joined(separator: ",")

            let filter = types.isEmpty
                ? ""
                : "WHERE a.account_type IN (\(placeholders))"

            let values = types.map {
                SQLValue.text($0)
            }

            let statement = try prepare(
                """
                SELECT
                    a.code,
                    a.name,
                    a.account_type,
                    COALESCE(SUM(l.debit), 0),
                    COALESCE(SUM(l.credit), 0)
                FROM accounts a
                LEFT JOIN journal_lines l
                    ON l.account_code = a.code
                \(filter)
                GROUP BY
                    a.code,
                    a.name,
                    a.account_type
                ORDER BY a.code;
                """,
                values
            )

            defer {
                sqlite3_finalize(statement)
            }

            var rows: [ReportRow] = []

            while sqlite3_step(statement) == SQLITE_ROW {
                let code = text(statement, 0)
                let name = text(statement, 1)
                let type = text(statement, 2)
                let debit = sqlite3_column_double(
                    statement,
                    3
                )
                let credit = sqlite3_column_double(
                    statement,
                    4
                )

                let balance: Double

                if signed {
                    switch type {
                    case "Income",
                         "Liability",
                         "Equity",
                         "Contra Asset":
                        balance = credit - debit
                    default:
                        balance = debit - credit
                    }
                } else {
                    balance = debit - credit
                }

                if abs(debit) > 0.004 ||
                    abs(credit) > 0.004 {
                    rows.append(
                        ReportRow(
                            id: code,
                            code: code,
                            name: name,
                            type: type,
                            debit: debit,
                            credit: credit,
                            balance: balance
                        )
                    )
                }
            }

            return rows
        } catch {
            message = error.localizedDescription
            return []
        }
    }

    func receivables() -> [ReceivableRow] {
        do {
            let statement = try prepare(
                """
                SELECT
                    invoice_id,
                    invoice_number,
                    client_name,
                    issue_date,
                    due_date,
                    total,
                    paid
                FROM receivables
                WHERE total - paid > 0.004
                ORDER BY due_date;
                """
            )

            defer {
                sqlite3_finalize(statement)
            }

            var rows: [ReceivableRow] = []

            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(
                    ReceivableRow(
                        id: text(statement, 0),
                        invoiceNumber: text(statement, 1),
                        clientName: text(statement, 2),
                        issueDate: Date(
                            timeIntervalSince1970:
                                sqlite3_column_double(
                                    statement,
                                    3
                                )
                        ),
                        dueDate: Date(
                            timeIntervalSince1970:
                                sqlite3_column_double(
                                    statement,
                                    4
                                )
                        ),
                        total: sqlite3_column_double(
                            statement,
                            5
                        ),
                        paid: sqlite3_column_double(
                            statement,
                            6
                        )
                    )
                )
            }

            return rows
        } catch {
            message = error.localizedDescription
            return []
        }
    }

    func importBankCSV(
        from url: URL
    ) throws -> Int {
        let content = try String(
            contentsOf: url,
            encoding: .utf8
        )

        let lines = content
            .components(separatedBy: .newlines)
            .filter {
                !$0.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
            }

        guard lines.count > 1 else {
            throw AccountingError.validation(
                "The bank CSV contains no transactions."
            )
        }

        let headers = parseCSVLine(lines[0])
            .map {
                $0.lowercased()
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
            }

        func column(
            matching candidates: [String],
            fallback: Int
        ) -> Int {
            for candidate in candidates {
                if let index = headers.firstIndex(
                    where: {
                        $0 == candidate ||
                        $0.contains(candidate)
                    }
                ) {
                    return index
                }
            }

            return fallback
        }

        let dateColumn = column(
            matching: ["date", "transaction date"],
            fallback: 0
        )

        let descriptionColumn = column(
            matching: ["description", "details", "narrative"],
            fallback: 1
        )

        let amountColumn = column(
            matching: ["amount", "value"],
            fallback: 2
        )

        let referenceColumn = column(
            matching: ["reference", "ref"],
            fallback: min(3, headers.count - 1)
        )

        var imported = 0

        for line in lines.dropFirst() {
            let fields = parseCSVLine(line)

            guard fields.indices.contains(dateColumn),
                  fields.indices.contains(descriptionColumn),
                  fields.indices.contains(amountColumn)
            else {
                continue
            }

            guard let date = parseBankDate(
                fields[dateColumn]
            ) else {
                continue
            }

            let cleanedAmount = fields[amountColumn]
                .replacingOccurrences(of: "R", with: "")
                .replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: " ", with: "")

            guard let amount = Double(cleanedAmount) else {
                continue
            }

            let reference =
                fields.indices.contains(referenceColumn)
                ? fields[referenceColumn]
                : ""

            let statement = try prepare(
                """
                INSERT OR IGNORE INTO bank_transactions (
                    id,
                    transaction_date,
                    description,
                    amount,
                    reference,
                    matched_entry_id,
                    reconciled,
                    imported_at
                ) VALUES (?, ?, ?, ?, ?, '', 0, ?);
                """,
                [
                    .text(UUID().uuidString),
                    .double(date.timeIntervalSince1970),
                    .text(fields[descriptionColumn]),
                    .double(amount),
                    .text(reference),
                    .double(Date().timeIntervalSince1970)
                ]
            )

            defer {
                sqlite3_finalize(statement)
            }

            if sqlite3_step(statement) == SQLITE_DONE {
                imported += sqlite3_changes(database) > 0
                    ? 1
                    : 0
            }
        }

        refresh()
        message = "\(imported) bank transaction(s) imported"

        return imported
    }

    func setBankTransaction(
        _ id: String,
        reconciled: Bool
    ) throws {
        let statement = try prepare(
            """
            UPDATE bank_transactions
            SET reconciled = ?
            WHERE id = ?;
            """,
            [
                .integer(reconciled ? 1 : 0),
                .text(id)
            ]
        )

        defer {
            sqlite3_finalize(statement)
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError()
        }

        refresh()
    }

    func addSourceDocument(
        linkedType: String,
        linkedId: String
    ) throws {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK,
              let source = panel.url else {
            return
        }

        let year = Calendar.current.component(
            .year,
            from: Date()
        )

        let yearDirectory = documentsDirectory
            .appendingPathComponent(
                String(year),
                isDirectory: true
            )

        try FileManager.default.createDirectory(
            at: yearDirectory,
            withIntermediateDirectories: true
        )

        let id = UUID().uuidString
        let destination = yearDirectory
            .appendingPathComponent(
                "\(id)-\(source.lastPathComponent)"
            )

        try FileManager.default.copyItem(
            at: source,
            to: destination
        )

        let retention = Calendar.current.date(
            byAdding: .year,
            value: 7,
            to: Date()
        ) ?? Date()

        let statement = try prepare(
            """
            INSERT INTO source_documents (
                id,
                linked_type,
                linked_id,
                original_name,
                stored_path,
                added_at,
                retention_until
            ) VALUES (?, ?, ?, ?, ?, ?, ?);
            """,
            [
                .text(id),
                .text(linkedType),
                .text(linkedId),
                .text(source.lastPathComponent),
                .text(destination.path),
                .double(Date().timeIntervalSince1970),
                .double(retention.timeIntervalSince1970)
            ]
        )

        defer {
            sqlite3_finalize(statement)
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError()
        }

        refresh()
        message = "Source document archived"
    }

    func complianceCalendar() -> [ComplianceRow] {
        let calendar = Calendar.current
        let now = Date()
        let year = calendar.component(
            .year,
            from: now
        )

        var yearEndComponents = DateComponents()
        yearEndComponents.year = year
        yearEndComponents.month =
            profile.financialYearEndMonth
        yearEndComponents.day =
            min(profile.financialYearEndDay, 28)

        var yearEnd =
            calendar.date(
                from: yearEndComponents
            ) ?? now

        if yearEnd < now {
            yearEnd = calendar.date(
                byAdding: .year,
                value: 1,
                to: yearEnd
            ) ?? yearEnd
        }

        let yearStart = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.date(
                byAdding: .year,
                value: -1,
                to: yearEnd
            ) ?? yearEnd
        ) ?? yearEnd

        let firstIRP6 = calendar.date(
            byAdding: .month,
            value: 6,
            to: yearStart
        ) ?? yearStart

        let afsDue = calendar.date(
            byAdding: .month,
            value: 6,
            to: yearEnd
        ) ?? yearEnd

        let itr14Due = calendar.date(
            byAdding: .month,
            value: 12,
            to: yearEnd
        ) ?? yearEnd

        let thirdIRP6 = calendar.date(
            byAdding: .month,
            value: 6,
            to: yearEnd
        ) ?? yearEnd

        var anniversaryComponents =
            calendar.dateComponents(
                [.month, .day],
                from: profile.incorporationDate
            )

        anniversaryComponents.year = year

        var anniversary =
            calendar.date(
                from: anniversaryComponents
            ) ?? now

        if anniversary < now {
            anniversary = calendar.date(
                byAdding: .year,
                value: 1,
                to: anniversary
            ) ?? anniversary
        }

        let annualReturnDue = addBusinessDays(
            30,
            to: anniversary
        )

        return [
            ComplianceRow(
                id: "irp6-1",
                title: "First provisional tax return and payment",
                category: "SARS",
                dueDate: firstIRP6,
                note: "IRP6 first period"
            ),
            ComplianceRow(
                id: "irp6-2",
                title: "Second provisional tax return and payment",
                category: "SARS",
                dueDate: yearEnd,
                note: "IRP6 at financial year-end"
            ),
            ComplianceRow(
                id: "afs",
                title: "Annual financial statements prepared",
                category: "Companies Act",
                dueDate: afsDue,
                note: "Within six months after financial year-end"
            ),
            ComplianceRow(
                id: "irp6-3",
                title: "Optional provisional-tax top-up",
                category: "SARS",
                dueDate: thirdIRP6,
                note: "Review with the accountant"
            ),
            ComplianceRow(
                id: "itr14",
                title: "Company income-tax return",
                category: "SARS",
                dueDate: itr14Due,
                note: "ITR14"
            ),
            ComplianceRow(
                id: "cipc-ar",
                title: "CIPC annual return",
                category: "CIPC",
                dueDate: annualReturnDue,
                note: "Anniversary filing window"
            ),
            ComplianceRow(
                id: "cipc-bo",
                title: "Beneficial-ownership declaration",
                category: "CIPC",
                dueDate: annualReturnDue,
                note: "File with the annual return and update after changes"
            )
        ]
        .sorted {
            $0.dueDate < $1.dueDate
        }
    }

    private func addBusinessDays(
        _ number: Int,
        to date: Date
    ) -> Date {
        var result = date
        var remaining = number
        let calendar = Calendar.current

        while remaining > 0 {
            result = calendar.date(
                byAdding: .day,
                value: 1,
                to: result
            ) ?? result

            let weekday = calendar.component(
                .weekday,
                from: result
            )

            if weekday != 1 && weekday != 7 {
                remaining -= 1
            }
        }

        return result
    }

    func exportAccountantPack(
        to folder: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )

        let profileCSV = """
field,value
"Legal name",\(booksCSV(profile.legalName))
"Registration number",\(booksCSV(profile.registrationNumber))
"Income tax reference",\(booksCSV(profile.incomeTaxReference))
"VAT registered",\(booksCSV(profile.vatRegistered ? "Yes" : "No"))
"VAT number",\(booksCSV(profile.vatNumber))
"Accounting framework",\(booksCSV(profile.accountingFramework))
"Public Interest Score","\(profile.publicInterestScore)"
"""

        try profileCSV.write(
            to: folder.appendingPathComponent(
                "Company Profile.csv"
            ),
            atomically: true,
            encoding: .utf8
        )

        try writeAccounts(
            to: folder.appendingPathComponent(
                "Chart of Accounts.csv"
            )
        )

        try writeJournalEntries(
            to: folder.appendingPathComponent(
                "Journal Entries.csv"
            )
        )

        try writeJournalLines(
            to: folder.appendingPathComponent(
                "Journal Lines.csv"
            )
        )

        try writeReport(
            trialBalance(),
            to: folder.appendingPathComponent(
                "Trial Balance.csv"
            )
        )

        try writeReport(
            incomeStatement(),
            to: folder.appendingPathComponent(
                "Income Statement.csv"
            )
        )

        try writeReport(
            balanceSheet(),
            to: folder.appendingPathComponent(
                "Balance Sheet.csv"
            )
        )

        try writeReceivables(
            to: folder.appendingPathComponent(
                "Aged Receivables.csv"
            )
        )

        try writeCompliance(
            to: folder.appendingPathComponent(
                "Compliance Calendar.csv"
            )
        )

        try writeBankReconciliation(
            to: folder.appendingPathComponent(
                "Bank Reconciliation.csv"
            )
        )
    }

    func exportDefaultAccountantPack() throws -> URL {
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first!

        let folder = documents
            .appendingPathComponent(
                "INV Exports",
                isDirectory: true
            )
            .appendingPathComponent(
                accountingDateFormatter.string(
                    from: Date()
                ),
                isDirectory: true
            )

        try exportAccountantPack(to: folder)

        NSWorkspace.shared.activateFileViewerSelecting(
            [folder]
        )

        message = "Accountant pack exported"

        return folder
    }

    private func writeAccounts(
        to url: URL
    ) throws {
        var csv = "code,name,type,active\n"

        for account in accounts {
            csv += [
                booksCSV(account.code),
                booksCSV(account.name),
                booksCSV(account.type),
                booksCSV(account.active ? "Yes" : "No")
            ].joined(separator: ",") + "\n"
        }

        try csv.write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
    }

    private func writeReport(
        _ rows: [ReportRow],
        to url: URL
    ) throws {
        var csv = "code,name,type,debit,credit,balance\n"

        for row in rows {
            csv += [
                booksCSV(row.code),
                booksCSV(row.name),
                booksCSV(row.type),
                String(format: "%.2f", row.debit),
                String(format: "%.2f", row.credit),
                String(format: "%.2f", row.balance)
            ].joined(separator: ",") + "\n"
        }

        try csv.write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
    }

    private func writeReceivables(
        to url: URL
    ) throws {
        var csv = """
invoice_number,client,issue_date,due_date,total,paid,balance,age_bucket

"""

        for row in receivables() {
            csv += [
                booksCSV(row.invoiceNumber),
                booksCSV(row.clientName),
                booksCSV(
                    accountingDateFormatter.string(
                        from: row.issueDate
                    )
                ),
                booksCSV(
                    accountingDateFormatter.string(
                        from: row.dueDate
                    )
                ),
                String(format: "%.2f", row.total),
                String(format: "%.2f", row.paid),
                String(format: "%.2f", row.balance),
                booksCSV(row.bucket)
            ].joined(separator: ",") + "\n"
        }

        try csv.write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
    }

    private func writeCompliance(
        to url: URL
    ) throws {
        var csv = "category,item,due_date,note\n"

        for item in complianceCalendar() {
            csv += [
                booksCSV(item.category),
                booksCSV(item.title),
                booksCSV(
                    accountingDateFormatter.string(
                        from: item.dueDate
                    )
                ),
                booksCSV(item.note)
            ].joined(separator: ",") + "\n"
        }

        try csv.write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
    }

    private func writeBankReconciliation(
        to url: URL
    ) throws {
        var csv = """
date,description,amount,reference,reconciled

"""

        for row in bankTransactions {
            csv += [
                booksCSV(
                    accountingDateFormatter.string(
                        from: row.date
                    )
                ),
                booksCSV(row.description),
                String(format: "%.2f", row.amount),
                booksCSV(row.reference),
                booksCSV(
                    row.reconciled ? "Yes" : "No"
                )
            ].joined(separator: ",") + "\n"
        }

        try csv.write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
    }

    private func writeJournalEntries(
        to url: URL
    ) throws {
        let statement = try prepare(
            """
            SELECT
                id,
                entry_date,
                reference,
                description,
                source_type,
                source_id,
                locked
            FROM journal_entries
            ORDER BY entry_date, created_at;
            """
        )

        defer {
            sqlite3_finalize(statement)
        }

        var csv = """
entry_id,date,reference,description,source_type,source_id,locked

"""

        while sqlite3_step(statement) == SQLITE_ROW {
            csv += [
                booksCSV(text(statement, 0)),
                booksCSV(
                    accountingDateFormatter.string(
                        from: Date(
                            timeIntervalSince1970:
                                sqlite3_column_double(
                                    statement,
                                    1
                                )
                        )
                    )
                ),
                booksCSV(text(statement, 2)),
                booksCSV(text(statement, 3)),
                booksCSV(text(statement, 4)),
                booksCSV(text(statement, 5)),
                booksCSV(
                    sqlite3_column_int(statement, 6) == 1
                        ? "Yes"
                        : "No"
                )
            ].joined(separator: ",") + "\n"
        }

        try csv.write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
    }

    private func writeJournalLines(
        to url: URL
    ) throws {
        let statement = try prepare(
            """
            SELECT
                entry_id,
                account_code,
                debit,
                credit,
                memo
            FROM journal_lines
            ORDER BY entry_id, id;
            """
        )

        defer {
            sqlite3_finalize(statement)
        }

        var csv = """
entry_id,account_code,debit,credit,memo

"""

        while sqlite3_step(statement) == SQLITE_ROW {
            csv += [
                booksCSV(text(statement, 0)),
                booksCSV(text(statement, 1)),
                String(
                    format: "%.2f",
                    sqlite3_column_double(
                        statement,
                        2
                    )
                ),
                String(
                    format: "%.2f",
                    sqlite3_column_double(
                        statement,
                        3
                    )
                ),
                booksCSV(text(statement, 4))
            ].joined(separator: ",") + "\n"
        }

        try csv.write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
    }

    private func loadProfile() throws
        -> CompanyProfileData {
        let statement = try prepare(
            """
            SELECT
                legal_name,
                registration_number,
                income_tax_reference,
                vat_registered,
                vat_number,
                address,
                incorporation_date,
                financial_year_end_month,
                financial_year_end_day,
                accounting_framework,
                employer_registered,
                average_employees,
                annual_turnover,
                third_party_liabilities,
                beneficial_interest_holders
            FROM company_profile
            WHERE id = 1;
            """
        )

        defer {
            sqlite3_finalize(statement)
        }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return CompanyProfileData()
        }

        var value = CompanyProfileData()

        value.legalName = text(statement, 0)
        value.registrationNumber = text(statement, 1)
        value.incomeTaxReference = text(statement, 2)
        value.vatRegistered =
            sqlite3_column_int(statement, 3) == 1
        value.vatNumber = text(statement, 4)
        value.address = text(statement, 5)
        value.incorporationDate = Date(
            timeIntervalSince1970:
                sqlite3_column_double(statement, 6)
        )
        value.financialYearEndMonth =
            Int(sqlite3_column_int(statement, 7))
        value.financialYearEndDay =
            Int(sqlite3_column_int(statement, 8))
        value.accountingFramework = text(statement, 9)
        value.employerRegistered =
            sqlite3_column_int(statement, 10) == 1
        value.averageEmployees =
            Int(sqlite3_column_int(statement, 11))
        value.annualTurnover =
            sqlite3_column_double(statement, 12)
        value.thirdPartyLiabilities =
            sqlite3_column_double(statement, 13)
        value.beneficialInterestHolders =
            Int(sqlite3_column_int(statement, 14))

        return value
    }

    private func loadAccounts() throws
        -> [LedgerAccount] {
        let statement = try prepare(
            """
            SELECT
                code,
                name,
                account_type,
                active
            FROM accounts
            ORDER BY code;
            """
        )

        defer {
            sqlite3_finalize(statement)
        }

        var result: [LedgerAccount] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(
                LedgerAccount(
                    code: text(statement, 0),
                    name: text(statement, 1),
                    type: text(statement, 2),
                    active:
                        sqlite3_column_int(
                            statement,
                            3
                        ) == 1
                )
            )
        }

        return result
    }

    private func loadBankTransactions() throws
        -> [BankTransactionRow] {
        let statement = try prepare(
            """
            SELECT
                id,
                transaction_date,
                description,
                amount,
                reference,
                COALESCE(matched_entry_id, ''),
                reconciled
            FROM bank_transactions
            ORDER BY transaction_date DESC;
            """
        )

        defer {
            sqlite3_finalize(statement)
        }

        var result: [BankTransactionRow] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(
                BankTransactionRow(
                    id: text(statement, 0),
                    date: Date(
                        timeIntervalSince1970:
                            sqlite3_column_double(
                                statement,
                                1
                            )
                    ),
                    description: text(statement, 2),
                    amount: sqlite3_column_double(
                        statement,
                        3
                    ),
                    reference: text(statement, 4),
                    matchedEntryId: text(statement, 5),
                    reconciled:
                        sqlite3_column_int(
                            statement,
                            6
                        ) == 1
                )
            )
        }

        return result
    }

    private func loadSourceDocuments() throws
        -> [SourceDocumentRow] {
        let statement = try prepare(
            """
            SELECT
                id,
                original_name,
                linked_type,
                linked_id,
                stored_path,
                added_at,
                retention_until
            FROM source_documents
            ORDER BY added_at DESC;
            """
        )

        defer {
            sqlite3_finalize(statement)
        }

        var result: [SourceDocumentRow] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(
                SourceDocumentRow(
                    id: text(statement, 0),
                    fileName: text(statement, 1),
                    linkedType: text(statement, 2),
                    linkedId: text(statement, 3),
                    storedPath: text(statement, 4),
                    addedAt: Date(
                        timeIntervalSince1970:
                            sqlite3_column_double(
                                statement,
                                5
                            )
                    ),
                    retentionUntil: Date(
                        timeIntervalSince1970:
                            sqlite3_column_double(
                                statement,
                                6
                            )
                    )
                )
            )
        }

        return result
    }

    private func sourceExists(
        _ sourceId: String
    ) throws -> Bool {
        let statement = try prepare(
            """
            SELECT COUNT(*)
            FROM journal_entries
            WHERE source_id = ?;
            """,
            [.text(sourceId)]
        )

        defer {
            sqlite3_finalize(statement)
        }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return false
        }

        return sqlite3_column_int(statement, 0) > 0
    }

    private func scalarInt(
        _ sql: String
    ) throws -> Int {
        let statement = try prepare(sql)

        defer {
            sqlite3_finalize(statement)
        }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return 0
        }

        return Int(sqlite3_column_int(statement, 0))
    }

    private func execute(
        _ sql: String
    ) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?

        guard sqlite3_exec(
            database,
            sql,
            nil,
            nil,
            &errorMessage
        ) == SQLITE_OK else {
            let message = errorMessage.map {
                String(cString: $0)
            } ?? "Unknown SQLite error"

            sqlite3_free(errorMessage)

            throw AccountingError.database(message)
        }
    }

    private func prepare(
        _ sql: String,
        _ values: [SQLValue] = []
    ) throws -> OpaquePointer {
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(
            database,
            sql,
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
        let statement else {
            throw databaseError()
        }

        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)

            switch value {
            case .text(let string):
                _ = string.withCString {
                    sqlite3_bind_text(
                        statement,
                        index,
                        $0,
                        -1,
                        sqliteTransient
                    )
                }

            case .double(let number):
                sqlite3_bind_double(
                    statement,
                    index,
                    number
                )

            case .integer(let number):
                sqlite3_bind_int64(
                    statement,
                    index,
                    sqlite3_int64(number)
                )

            case .null:
                sqlite3_bind_null(statement, index)
            }
        }

        return statement
    }

    private func text(
        _ statement: OpaquePointer,
        _ column: Int32
    ) -> String {
        guard let pointer =
            sqlite3_column_text(
                statement,
                column
            )
        else {
            return ""
        }

        return String(
            cString: UnsafePointer(pointer)
        )
    }

    private func databaseError()
        -> AccountingError {
        let message = database.map {
            String(cString: sqlite3_errmsg($0))
        } ?? "Unknown accounting database error"

        return .database(message)
    }

    private func parseBankDate(
        _ value: String
    ) -> Date? {
        let formats = [
            "yyyy-MM-dd",
            "dd/MM/yyyy",
            "yyyy/MM/dd",
            "dd-MM-yyyy"
        ]

        for format in formats {
            let formatter = DateFormatter()
            formatter.dateFormat = format

            if let date = formatter.date(
                from: value.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            ) {
                return date
            }
        }

        return nil
    }

    private func parseCSVLine(
        _ line: String
    ) -> [String] {
        var result: [String] = []
        var current = ""
        var insideQuotes = false
        var iterator = line.makeIterator()

        while let character = iterator.next() {
            if character == "\"" {
                insideQuotes.toggle()
            } else if character == "," &&
                        !insideQuotes {
                result.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }

        result.append(current)

        return result
    }
}

// MARK: - Workspace

enum BooksSection:
    String,
    CaseIterable,
    Identifiable {

    case overview = "Overview"
    case company = "Company"
    case entries = "Entries"
    case bank = "Bank"
    case reports = "Reports"
    case compliance = "Compliance"
    case records = "Records"

    var id: String {
        rawValue
    }

    var symbol: String {
        switch self {
        case .overview:
            return "rectangle.grid.2x2"

        case .company:
            return "building.2"

        case .entries:
            return "square.and.pencil"

        case .bank:
            return "banknote"

        case .reports:
            return "chart.bar.xaxis"

        case .compliance:
            return "calendar"

        case .records:
            return "archivebox"
        }
    }

    var title: String {
        switch self {
        case .overview:
            return "Business overview"

        case .company:
            return "Company setup"

        case .entries:
            return "Record transactions"

        case .bank:
            return "Reconcile the bank"

        case .reports:
            return "Financial reports"

        case .compliance:
            return "Compliance calendar"

        case .records:
            return "Source documents"
        }
    }

    var subtitle: String {
        switch self {
        case .overview:
            return """
            See what needs attention without touring the entire accounting department.
            """

        case .company:
            return """
            Registration, tax status, financial year-end and reporting inputs.
            """

        case .entries:
            return """
            Capture expenses and balanced manual journal entries.
            """

        case .bank:
            return """
            Import statement transactions and mark completed reconciliations.
            """

        case .reports:
            return """
            Review balances, performance, position and outstanding invoices.
            """

        case .compliance:
            return """
            Track company deadlines and the inputs used for the Public Interest Score.
            """

        case .records:
            return """
            Keep supporting documents linked to invoices, payments and tax records.
            """
        }
    }
}


struct AccountingWorkspace: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject private var repository =
        AccountingRepository.shared

    @State private var section:
        BooksSection = .overview

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            HStack(spacing: 0) {
                sidebar

                Divider()

                VStack(spacing: 0) {
                    BooksPageHeader(
                        title: section.title,
                        subtitle: section.subtitle
                    )

                    Divider()

                    selectedContent
                        .padding(20)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .topLeading
                        )
                }
            }
        }
        .frame(
            minWidth: 1_020,
            idealWidth: 1_080,
            minHeight: 700,
            idealHeight: 760
        )
        .background(booksPaper)
        .foregroundColor(booksInk)
        .tint(booksInk)
    }

    private var header: some View {
        HStack(spacing: 18) {
            VStack(
                alignment: .leading,
                spacing: 3
            ) {
                Text("BOOKS")
                    .font(
                        .system(
                            size: 24,
                            weight: .bold
                        )
                    )

                Text(
                    repository.profile.legalName.isEmpty
                        ? "LOCAL ACCOUNTING"
                        : repository.profile.legalName.uppercased()
                )
                .font(
                    .system(
                        size: 9,
                        weight: .medium
                    )
                )
                .foregroundColor(booksMuted)
                .lineLimit(1)
            }

            Spacer()

            BooksStatusPill(
                message: repository.message
            )

            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .buttonStyle(BooksSecondaryButtonStyle())
        }
        .padding(
            EdgeInsets(
                top: 15,
                leading: 20,
                bottom: 15,
                trailing: 20
            )
        )
    }

    private var sidebar: some View {
        VStack(
            alignment: .leading,
            spacing: 0
        ) {
            Text("WORKSPACE")
                .font(
                    .system(
                        size: 9,
                        weight: .medium
                    )
                )
                .foregroundColor(booksMuted)
                .padding(
                    EdgeInsets(
                        top: 20,
                        leading: 18,
                        bottom: 10,
                        trailing: 18
                    )
                )

            ForEach(
                BooksSection.allCases
            ) { item in
                Button {
                    section = item
                } label: {
                    HStack(spacing: 12) {
                        Rectangle()
                            .fill(
                                section == item
                                    ? booksInk
                                    : Color.clear
                            )
                            .frame(width: 2)

                        Image(
                            systemName: item.symbol
                        )
                        .font(.system(size: 13))
                        .frame(width: 18)

                        Text(item.rawValue)
                            .font(
                                .system(
                                    size: 13,
                                    weight:
                                        section == item
                                        ? .semibold
                                        : .regular
                                )
                            )

                        Spacer()
                    }
                    .foregroundColor(booksInk)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: 42,
                        alignment: .leading
                    )
                    .padding(.trailing, 14)
                    .contentShape(Rectangle())
                    .background(
                        section == item
                            ? booksInk.opacity(0.055)
                            : Color.clear
                    )
                }
                .buttonStyle(.plain)
                .help(item.title)
            }

            Spacer()

            VStack(
                alignment: .leading,
                spacing: 5
            ) {
                Text("LOCAL DATABASE")
                    .font(
                        .system(
                            size: 9,
                            weight: .medium
                        )
                    )
                    .foregroundColor(booksMuted)

                Text("Changes remain on this Mac.")
                    .font(.system(size: 11))
                    .foregroundColor(booksMuted)
            }
            .padding(18)
        }
        .frame(width: 202)
        .background(
            Color.black.opacity(0.018)
        )
    }

    @ViewBuilder
    private var selectedContent:
        some View {

        switch section {
        case .overview:
            BooksOverviewView(
                section: $section
            )

        case .company:
            CompanyProfileView()

        case .entries:
            JournalWorkspaceView()

        case .bank:
            BankWorkspaceView()

        case .reports:
            ReportsWorkspaceView()

        case .compliance:
            ComplianceWorkspaceView {
                section = .company
            }

        case .records:
            RecordsWorkspaceView()
        }
    }
}


// MARK: - Shared interface

struct BooksPageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top) {
            VStack(
                alignment: .leading,
                spacing: 5
            ) {
                Text(title)
                    .font(
                        .system(
                            size: 20,
                            weight: .semibold
                        )
                    )

                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(booksMuted)
                    .fixedSize(
                        horizontal: false,
                        vertical: true
                    )
            }

            Spacer()
        }
        .padding(
            EdgeInsets(
                top: 18,
                leading: 20,
                bottom: 17,
                trailing: 20
            )
        )
    }
}


struct BooksStatusPill: View {
    let message: String

    private var warning:
        Bool {

        let lower = message.lowercased()

        return lower.contains("could not")
            || lower.contains("missing")
            || lower.contains("must")
            || lower.contains("add the")
            || lower.contains("greater than")
            || lower.contains("differ")
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(
                    warning
                        ? booksWarning
                        : booksSuccess
                )
                .frame(width: 7, height: 7)

            Text(message)
                .font(.system(size: 11))
                .lineLimit(1)
        }
        .foregroundColor(booksMuted)
        .padding(.horizontal, 11)
        .frame(height: 30)
        .overlay(
            Capsule()
                .stroke(
                    booksBorder,
                    lineWidth: 1
                )
        )
    }
}


struct BooksSectionCard<
    Content: View
>: View {

    let title: String
    let subtitle: String
    let content: Content

    init(
        title: String,
        subtitle: String = "",
        @ViewBuilder content:
            () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 16
        ) {
            VStack(
                alignment: .leading,
                spacing: 4
            ) {
                Text(title)
                    .font(
                        .system(
                            size: 14,
                            weight: .semibold
                        )
                    )

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(
                            booksMuted
                        )
                        .fixedSize(
                            horizontal: false,
                            vertical: true
                        )
                }
            }

            content
        }
        .padding(18)
        .background(booksPanel)
        .overlay(
            RoundedRectangle(
                cornerRadius: 6
            )
            .stroke(
                booksBorder,
                lineWidth: 1
            )
        )
        .cornerRadius(6)
    }
}


struct BooksMetricCard: View {
    let label: String
    let value: String
    let note: String

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 8
        ) {
            Text(label.uppercased())
                .font(
                    .system(
                        size: 9,
                        weight: .medium
                    )
                )
                .foregroundColor(booksMuted)

            Text(value)
                .font(
                    .system(
                        size: 23,
                        weight: .semibold
                    )
                )
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Text(note)
                .font(.system(size: 10))
                .foregroundColor(booksMuted)
                .lineLimit(2)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: 88,
            alignment: .topLeading
        )
        .padding(15)
        .background(booksPanel)
        .overlay(
            RoundedRectangle(
                cornerRadius: 6
            )
            .stroke(
                booksBorder,
                lineWidth: 1
            )
        )
        .cornerRadius(6)
    }
}


struct BooksEmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 24))
                .foregroundColor(booksMuted)

            Text(title)
                .font(
                    .system(
                        size: 14,
                        weight: .semibold
                    )
                )

            Text(message)
                .font(.system(size: 11))
                .foregroundColor(booksMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: 210
        )
    }
}


struct BooksInlineCallout: View {
    let symbol: String
    let text: String
    var warning = false

    var body: some View {
        HStack(
            alignment: .top,
            spacing: 9
        ) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundColor(
                    warning
                        ? booksWarning
                        : booksMuted
                )

            Text(text)
                .font(.system(size: 11))
                .foregroundColor(booksMuted)
                .fixedSize(
                    horizontal: false,
                    vertical: true
                )

            Spacer()
        }
        .padding(11)
        .background(
            warning
                ? booksWarning.opacity(0.07)
                : Color.black.opacity(0.025)
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: 5
            )
            .stroke(
                warning
                    ? booksWarning.opacity(0.25)
                    : booksBorder,
                lineWidth: 1
            )
        )
        .cornerRadius(5)
    }
}


struct BooksTextInput: View {
    let label: String
    let placeholder: String

    @Binding var text: String

    var note = ""

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 6
        ) {
            Text(label.uppercased())
                .font(
                    .system(
                        size: 9,
                        weight: .medium
                    )
                )
                .foregroundColor(booksMuted)

            TextField(
                placeholder,
                text: $text
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                Color.white.opacity(0.52)
            )
            .overlay(
                RoundedRectangle(
                    cornerRadius: 4
                )
                .stroke(
                    booksBorder,
                    lineWidth: 1
                )
            )
            .cornerRadius(4)

            if !note.isEmpty {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundColor(
                        booksMuted
                    )
            }
        }
        .frame(
            maxWidth: .infinity,
            alignment: .leading
        )
    }
}


struct BooksDoubleInput: View {
    let label: String

    @Binding var value: Double

    var disabled = false

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 6
        ) {
            Text(label.uppercased())
                .font(
                    .system(
                        size: 9,
                        weight: .medium
                    )
                )
                .foregroundColor(booksMuted)

            TextField(
                "",
                value: $value,
                formatter:
                    accountingNumberFormatter
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                Color.white.opacity(
                    disabled ? 0.22 : 0.52
                )
            )
            .overlay(
                RoundedRectangle(
                    cornerRadius: 4
                )
                .stroke(
                    booksBorder,
                    lineWidth: 1
                )
            )
            .cornerRadius(4)
            .disabled(disabled)
        }
        .frame(
            maxWidth: .infinity,
            alignment: .leading
        )
    }
}


struct BooksPrimaryButtonStyle:
    ButtonStyle {

    @Environment(\.isEnabled)
    private var isEnabled

    func makeBody(
        configuration: Configuration
    ) -> some View {

        configuration.label
            .font(
                .system(
                    size: 12,
                    weight: .semibold
                )
            )
            .foregroundColor(.white)
            .padding(.horizontal, 15)
            .frame(minHeight: 36)
            .background(
                isEnabled
                    ? booksInk.opacity(
                        configuration.isPressed
                            ? 0.76
                            : 1
                    )
                    : booksInk.opacity(0.24)
            )
            .cornerRadius(5)
    }
}


struct BooksSecondaryButtonStyle:
    ButtonStyle {

    @Environment(\.isEnabled)
    private var isEnabled

    func makeBody(
        configuration: Configuration
    ) -> some View {

        configuration.label
            .font(
                .system(
                    size: 12,
                    weight: .medium
                )
            )
            .foregroundColor(
                isEnabled
                    ? booksInk
                    : booksMuted.opacity(0.45)
            )
            .padding(.horizontal, 13)
            .frame(minHeight: 34)
            .background(
                configuration.isPressed
                    ? Color.black.opacity(0.055)
                    : Color.clear
            )
            .overlay(
                RoundedRectangle(
                    cornerRadius: 5
                )
                .stroke(
                    booksBorder,
                    lineWidth: 1
                )
            )
            .cornerRadius(5)
    }
}


// MARK: - Overview

struct BooksOverviewView: View {
    @ObservedObject private var repository =
        AccountingRepository.shared

    @Binding var section: BooksSection

    private var outstanding:
        Double {

        repository.receivables()
            .reduce(0) {
                $0 + $1.balance
            }
    }

    private var unreconciled:
        Int {

        repository.bankTransactions
            .filter {
                !$0.reconciled
            }
            .count
    }

    private var setupItems:
        [(String, Bool)] {

        let profile = repository.profile

        return [
            (
                "Legal company name",
                !profile.legalName
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    .isEmpty
            ),
            (
                "Registration number",
                !profile.registrationNumber
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    .isEmpty
            ),
            (
                "Income-tax reference",
                !profile.incomeTaxReference
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    .isEmpty
            ),
            (
                "Registered address",
                !profile.address
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    .isEmpty
            ),
            (
                "VAT status",
                !profile.vatRegistered
                    || !profile.vatNumber
                        .trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )
                        .isEmpty
            )
        ]
    }

    private var setupProgress:
        Double {

        let completed = setupItems
            .filter {
                $0.1
            }
            .count

        return Double(completed)
            / Double(setupItems.count)
    }

    private var nextDeadline:
        ComplianceRow? {

        repository.complianceCalendar()
            .first {
                $0.dueDate >=
                    Calendar.current
                        .startOfDay(
                            for: Date()
                        )
            }
    }

    private var nextAction:
        (
            title: String,
            detail: String,
            target: BooksSection
        ) {

        if setupProgress < 1 {
            return (
                "Complete company setup",
                """
                Add the remaining company and tax details before relying on reports.
                """,
                .company
            )
        }

        if unreconciled > 0 {
            return (
                "Review bank transactions",
                """
                There are \(unreconciled) imported transaction(s) still awaiting reconciliation.
                """,
                .bank
            )
        }

        if repository.trialBalance().isEmpty {
            return (
                "Record the first transaction",
                """
                Add an expense or journal entry to begin building the ledger.
                """,
                .entries
            )
        }

        return (
            "Review the financial reports",
            """
            The ledger contains activity and is ready for a quick sense-check.
            """,
            .reports
        )
    }

    var body: some View {
        ScrollView {
            VStack(
                alignment: .leading,
                spacing: 18
            ) {
                HStack(spacing: 12) {
                    BooksMetricCard(
                        label: "Outstanding",
                        value:
                            booksMoney(
                                outstanding
                            ),
                        note:
                            "Unpaid invoice balances"
                    )

                    BooksMetricCard(
                        label: "Bank",
                        value:
                            "\(unreconciled)",
                        note:
                            "Transactions awaiting review"
                    )

                    BooksMetricCard(
                        label: "PI Score",
                        value:
                            "\(repository.profile.publicInterestScore)",
                        note:
                            "Based on saved company inputs"
                    )

                    BooksMetricCard(
                        label: "Next deadline",
                        value:
                            nextDeadline.map {
                                accountingDisplayDateFormatter
                                    .string(
                                        from: $0.dueDate
                                    )
                            } ?? "—",
                        note:
                            nextDeadline?.title
                            ?? "No upcoming item"
                    )
                }

                BooksSectionCard(
                    title: "Next useful action",
                    subtitle:
                        nextAction.detail
                ) {
                    HStack {
                        Button(
                            nextAction.title
                        ) {
                            section =
                                nextAction.target
                        }
                        .buttonStyle(
                            BooksPrimaryButtonStyle()
                        )

                        Spacer()
                    }
                }

                HStack(
                    alignment: .top,
                    spacing: 14
                ) {
                    BooksSectionCard(
                        title: "Company setup",
                        subtitle:
                            "\(Int(setupProgress * 100))% complete"
                    ) {
                        ProgressView(
                            value: setupProgress
                        )
                        .progressViewStyle(.linear)

                        VStack(
                            alignment: .leading,
                            spacing: 8
                        ) {
                            ForEach(
                                Array(
                                    setupItems.enumerated()
                                ),
                                id: \.offset
                            ) { item in
                                HStack(spacing: 8) {
                                    Image(
                                        systemName:
                                            item.element.1
                                            ? "checkmark.circle.fill"
                                            : "circle"
                                    )
                                    .foregroundColor(
                                        item.element.1
                                            ? booksSuccess
                                            : booksMuted
                                    )

                                    Text(
                                        item.element.0
                                    )
                                    .font(
                                        .system(
                                            size: 11
                                        )
                                    )
                                }
                            }
                        }

                        Button("Open company setup") {
                            section = .company
                        }
                        .buttonStyle(
                            BooksSecondaryButtonStyle()
                        )
                    }

                    BooksSectionCard(
                        title: "Common tasks",
                        subtitle:
                            "The jobs most likely to happen between client emails."
                    ) {
                        VStack(spacing: 9) {
                            overviewAction(
                                title:
                                    "Record an expense",
                                symbol:
                                    "square.and.pencil",
                                target:
                                    .entries
                            )

                            overviewAction(
                                title:
                                    "Import a bank statement",
                                symbol:
                                    "arrow.down.doc",
                                target:
                                    .bank
                            )

                            overviewAction(
                                title:
                                    "Review reports",
                                symbol:
                                    "chart.bar.xaxis",
                                target:
                                    .reports
                            )

                            overviewAction(
                                title:
                                    "Archive a document",
                                symbol:
                                    "archivebox",
                                target:
                                    .records
                            )
                        }
                    }
                }
            }
            .padding(.bottom, 20)
        }
        .onAppear {
            repository.refresh()
        }
    }

    private func overviewAction(
        title: String,
        symbol: String,
        target: BooksSection
    ) -> some View {

        Button {
            section = target
        } label: {
            HStack(spacing: 10) {
                Image(
                    systemName: symbol
                )
                .frame(width: 18)

                Text(title)
                    .font(.system(size: 12))

                Spacer()

                Image(
                    systemName:
                        "chevron.right"
                )
                .font(.system(size: 9))
                .foregroundColor(
                    booksMuted
                )
            }
            .foregroundColor(booksInk)
            .frame(minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}


// MARK: - Company

struct CompanyProfileView: View {
    @ObservedObject private var repository =
        AccountingRepository.shared

    @State private var profile =
        AccountingRepository.shared.profile

    @State private var status = ""

    private var vatInvalid:
        Bool {

        profile.vatRegistered
            && profile.vatNumber
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                .isEmpty
    }

    private var monthNames:
        [String] {

        DateFormatter().monthSymbols
    }

    var body: some View {
        ScrollView {
            VStack(
                alignment: .leading,
                spacing: 16
            ) {
                BooksSectionCard(
                    title: "Registered identity",
                    subtitle:
                        "Use the details shown on official company and tax records."
                ) {
                    HStack(
                        alignment: .top,
                        spacing: 14
                    ) {
                        BooksTextInput(
                            label:
                                "Legal company name",
                            placeholder:
                                "Company legal name",
                            text:
                                $profile.legalName
                        )

                        BooksTextInput(
                            label:
                                "Registration number",
                            placeholder:
                                "2024/000000/07",
                            text:
                                $profile.registrationNumber
                        )
                    }

                    HStack(
                        alignment: .top,
                        spacing: 14
                    ) {
                        BooksTextInput(
                            label:
                                "Income-tax reference",
                            placeholder:
                                "Tax reference number",
                            text:
                                $profile.incomeTaxReference
                        )

                        VStack(
                            alignment: .leading,
                            spacing: 6
                        ) {
                            Text(
                                "INCORPORATION DATE"
                            )
                            .font(
                                .system(
                                    size: 9,
                                    weight: .medium
                                )
                            )
                            .foregroundColor(
                                booksMuted
                            )

                            DatePicker(
                                "",
                                selection:
                                    $profile.incorporationDate,
                                displayedComponents:
                                    .date
                            )
                            .labelsHidden()
                        }
                        .frame(
                            maxWidth: .infinity,
                            alignment: .leading
                        )
                    }

                    BooksTextInput(
                        label:
                            "Registered address",
                        placeholder:
                            "Street, suburb, city and postal code",
                        text:
                            $profile.address
                    )
                }

                BooksSectionCard(
                    title: "Tax status",
                    subtitle:
                        "Invoice wording and VAT treatment follow these settings."
                ) {
                    Toggle(
                        "Registered for VAT",
                        isOn:
                            $profile.vatRegistered
                    )
                    .toggleStyle(.checkbox)

                    if profile.vatRegistered {
                        BooksTextInput(
                            label:
                                "VAT registration number",
                            placeholder:
                                "VAT number",
                            text:
                                $profile.vatNumber
                        )

                        if vatInvalid {
                            BooksInlineCallout(
                                symbol:
                                    "exclamationmark.triangle",
                                text:
                                    "Add the VAT registration number before issuing a tax invoice.",
                                warning: true
                            )
                        }
                    } else {
                        BooksInlineCallout(
                            symbol:
                                "info.circle",
                            text:
                                "Invoices remain ordinary invoices and VAT is excluded from ledger postings."
                        )
                    }

                    Toggle(
                        "Registered as an employer",
                        isOn:
                            $profile.employerRegistered
                    )
                    .toggleStyle(.checkbox)
                }

                BooksSectionCard(
                    title: "Financial year",
                    subtitle:
                        "The calendar uses this date to estimate reporting reminders."
                ) {
                    HStack(
                        alignment: .top,
                        spacing: 18
                    ) {
                        VStack(
                            alignment: .leading,
                            spacing: 6
                        ) {
                            Text("YEAR-END MONTH")
                                .font(
                                    .system(
                                        size: 9,
                                        weight: .medium
                                    )
                                )
                                .foregroundColor(
                                    booksMuted
                                )

                            Picker(
                                "",
                                selection:
                                    $profile.financialYearEndMonth
                            ) {
                                ForEach(
                                    1...12,
                                    id: \.self
                                ) { month in
                                    Text(
                                        monthNames[
                                            month - 1
                                        ]
                                    )
                                    .tag(month)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 180)
                        }

                        VStack(
                            alignment: .leading,
                            spacing: 6
                        ) {
                            Text("YEAR-END DAY")
                                .font(
                                    .system(
                                        size: 9,
                                        weight: .medium
                                    )
                                )
                                .foregroundColor(
                                    booksMuted
                                )

                            Stepper(
                                value:
                                    $profile.financialYearEndDay,
                                in: 1...31
                            ) {
                                Text(
                                    "\(profile.financialYearEndDay)"
                                )
                                .frame(
                                    width: 30,
                                    alignment: .leading
                                )
                            }
                        }

                        Spacer()
                    }
                }

                BooksSectionCard(
                    title: "Reporting assessment",
                    subtitle:
                        "Advanced inputs are kept out of the way until the accountant needs them."
                ) {
                    DisclosureGroup(
                        "Public Interest Score inputs"
                    ) {
                        VStack(
                            alignment: .leading,
                            spacing: 14
                        ) {
                            VStack(
                                alignment: .leading,
                                spacing: 6
                            ) {
                                Text(
                                    "ACCOUNTING FRAMEWORK"
                                )
                                .font(
                                    .system(
                                        size: 9,
                                        weight: .medium
                                    )
                                )
                                .foregroundColor(
                                    booksMuted
                                )

                                Picker(
                                    "",
                                    selection:
                                        $profile.accountingFramework
                                ) {
                                    Text(
                                        "IFRS for SMEs"
                                    )
                                    .tag(
                                        "IFRS for SMEs"
                                    )

                                    Text("Full IFRS")
                                        .tag(
                                            "Full IFRS"
                                        )

                                    Text(
                                        "Accountant to determine"
                                    )
                                    .tag(
                                        "Accountant to determine"
                                    )
                                }
                                .labelsHidden()
                                .frame(width: 240)
                            }

                            HStack(
                                alignment: .top,
                                spacing: 14
                            ) {
                                BooksDoubleInput(
                                    label:
                                        "Average employees",
                                    value:
                                        Binding(
                                            get: {
                                                Double(
                                                    profile.averageEmployees
                                                )
                                            },
                                            set: {
                                                profile.averageEmployees =
                                                    max(
                                                        0,
                                                        Int($0)
                                                    )
                                            }
                                        )
                                )

                                BooksDoubleInput(
                                    label:
                                        "Annual turnover",
                                    value:
                                        $profile.annualTurnover
                                )
                            }

                            HStack(
                                alignment: .top,
                                spacing: 14
                            ) {
                                BooksDoubleInput(
                                    label:
                                        "Third-party liabilities",
                                    value:
                                        $profile.thirdPartyLiabilities
                                )

                                BooksDoubleInput(
                                    label:
                                        "Beneficial-interest holders",
                                    value:
                                        Binding(
                                            get: {
                                                Double(
                                                    profile.beneficialInterestHolders
                                                )
                                            },
                                            set: {
                                                profile.beneficialInterestHolders =
                                                    max(
                                                        0,
                                                        Int($0)
                                                    )
                                            }
                                        )
                                )
                            }

                            BooksInlineCallout(
                                symbol:
                                    "number.circle",
                                text:
                                    "Current Public Interest Score: \(profile.publicInterestScore)"
                            )
                        }
                        .padding(.top, 12)
                    }
                }

                HStack {
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundColor(booksMuted)

                    Spacer()

                    Button(
                        "Save company profile"
                    ) {
                        save()
                    }
                    .buttonStyle(
                        BooksPrimaryButtonStyle()
                    )
                    .disabled(vatInvalid)
                }
            }
            .padding(.bottom, 24)
        }
        .onAppear {
            profile = repository.profile
        }
    }

    private func save() {
        do {
            try repository.saveProfile(
                profile
            )

            status = "Company profile saved."
        } catch {
            status = error.localizedDescription
        }
    }
}


// MARK: - Entries

enum BooksEntryMode:
    String,
    CaseIterable,
    Identifiable {

    case expense = "Expense"
    case journal = "Manual journal"

    var id: String {
        rawValue
    }
}


struct JournalWorkspaceView: View {
    @ObservedObject private var repository =
        AccountingRepository.shared

    @State private var mode:
        BooksEntryMode = .expense

    @State private var date = Date()
    @State private var supplier = ""
    @State private var reference = ""
    @State private var notes = ""

    @State private var expenseAccount =
        "6100"

    @State private var paymentAccount =
        "1000"

    @State private var debitAccount =
        "1000"

    @State private var creditAccount =
        "4000"

    @State private var amount = 0.0
    @State private var vatAmount = 0.0
    @State private var status = ""

    private var expenseAccounts:
        [LedgerAccount] {

        repository.accounts.filter {
            $0.type == "Expense"
        }
    }

    private var entryValid:
        Bool {

        if amount <= 0 {
            return false
        }

        if mode == .journal {
            return debitAccount
                != creditAccount
        }

        return vatAmount <= amount
    }

    var body: some View {
        ScrollView {
            VStack(
                alignment: .leading,
                spacing: 16
            ) {
                Picker(
                    "Entry type",
                    selection: $mode
                ) {
                    ForEach(
                        BooksEntryMode.allCases
                    ) { item in
                        Text(item.rawValue)
                            .tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 360)

                BooksSectionCard(
                    title:
                        mode == .expense
                        ? "Expense details"
                        : "Journal details",
                    subtitle:
                        mode == .expense
                        ? "Capture the transaction using the total amount paid."
                        : "Manual journals require an equal debit and credit."
                ) {
                    HStack(
                        alignment: .top,
                        spacing: 14
                    ) {
                        VStack(
                            alignment: .leading,
                            spacing: 6
                        ) {
                            Text("DATE")
                                .font(
                                    .system(
                                        size: 9,
                                        weight: .medium
                                    )
                                )
                                .foregroundColor(
                                    booksMuted
                                )

                            DatePicker(
                                "",
                                selection: $date,
                                displayedComponents:
                                    .date
                            )
                            .labelsHidden()
                        }
                        .frame(
                            maxWidth: .infinity,
                            alignment: .leading
                        )

                        BooksTextInput(
                            label:
                                mode == .expense
                                ? "Supplier"
                                : "Description",
                            placeholder:
                                mode == .expense
                                ? "Supplier or payee"
                                : "Reason for the journal",
                            text: $supplier
                        )

                        BooksTextInput(
                            label: "Reference",
                            placeholder:
                                "Receipt, invoice or journal reference",
                            text: $reference
                        )
                    }

                    if mode == .expense {
                        expenseFields
                    } else {
                        journalFields
                    }

                    BooksTextInput(
                        label: "Notes",
                        placeholder:
                            "Optional internal note",
                        text: $notes
                    )
                }

                if !status.isEmpty {
                    BooksInlineCallout(
                        symbol:
                            status == "Entry posted."
                            ? "checkmark.circle"
                            : "exclamationmark.triangle",
                        text: status,
                        warning:
                            status != "Entry posted."
                    )
                }

                HStack {
                    Button("Clear") {
                        clear()
                    }
                    .buttonStyle(
                        BooksSecondaryButtonStyle()
                    )

                    Spacer()

                    Button(
                        mode == .expense
                        ? "Post expense"
                        : "Post journal"
                    ) {
                        post()
                    }
                    .buttonStyle(
                        BooksPrimaryButtonStyle()
                    )
                    .disabled(!entryValid)
                }
            }
            .padding(.bottom, 24)
        }
        .onAppear {
            repository.refresh()

            if !expenseAccounts.contains(
                where: {
                    $0.code == expenseAccount
                }
            ),
            let first = expenseAccounts.first {
                expenseAccount =
                    first.code
            }
        }
    }

    private var expenseFields:
        some View {

        VStack(
            alignment: .leading,
            spacing: 14
        ) {
            HStack(
                alignment: .top,
                spacing: 14
            ) {
                accountPicker(
                    label:
                        "EXPENSE ACCOUNT",
                    selection:
                        $expenseAccount,
                    accounts:
                        expenseAccounts
                )

                accountPicker(
                    label:
                        "PAYMENT ACCOUNT",
                    selection:
                        $paymentAccount,
                    accounts:
                        repository.accounts
                )
            }

            HStack(
                alignment: .top,
                spacing: 14
            ) {
                BooksDoubleInput(
                    label: "Total amount",
                    value: $amount
                )

                BooksDoubleInput(
                    label:
                        "VAT amount included",
                    value: $vatAmount,
                    disabled:
                        !repository.profile.vatRegistered
                )
            }

            if !repository.profile
                .vatRegistered {

                BooksInlineCallout(
                    symbol: "info.circle",
                    text:
                        "VAT capture is disabled because the company profile is not marked as VAT registered."
                )
            }
        }
    }

    private var journalFields:
        some View {

        VStack(
            alignment: .leading,
            spacing: 14
        ) {
            HStack(
                alignment: .top,
                spacing: 14
            ) {
                accountPicker(
                    label:
                        "DEBIT ACCOUNT",
                    selection:
                        $debitAccount,
                    accounts:
                        repository.accounts
                )

                accountPicker(
                    label:
                        "CREDIT ACCOUNT",
                    selection:
                        $creditAccount,
                    accounts:
                        repository.accounts
                )
            }

            BooksDoubleInput(
                label: "Amount",
                value: $amount
            )

            if debitAccount ==
                creditAccount {

                BooksInlineCallout(
                    symbol:
                        "exclamationmark.triangle",
                    text:
                        "Choose different debit and credit accounts.",
                    warning: true
                )
            }
        }
    }

    private func accountPicker(
        label: String,
        selection: Binding<String>,
        accounts: [LedgerAccount]
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
                .foregroundColor(booksMuted)

            Picker(
                "",
                selection: selection
            ) {
                ForEach(accounts) {
                    account in

                    Text(
                        account.displayName
                    )
                    .tag(account.code)
                }
            }
            .labelsHidden()
        }
        .frame(
            maxWidth: .infinity,
            alignment: .leading
        )
    }

    private func post() {
        do {
            if mode == .expense {
                try repository.postExpense(
                    date: date,
                    supplier: supplier,
                    reference: reference,
                    expenseAccount:
                        expenseAccount,
                    paymentAccount:
                        paymentAccount,
                    totalAmount: amount,
                    vatAmount:
                        repository.profile.vatRegistered
                        ? vatAmount
                        : 0,
                    notes: notes
                )
            } else {
                try repository.postManualJournal(
                    date: date,
                    reference: reference,
                    description: supplier,
                    debitAccount:
                        debitAccount,
                    creditAccount:
                        creditAccount,
                    amount: amount
                )
            }

            status = "Entry posted."
            clearValues()
        } catch {
            status =
                error.localizedDescription
        }
    }

    private func clear() {
        clearValues()
        status = ""
    }

    private func clearValues() {
        supplier = ""
        reference = ""
        notes = ""
        amount = 0
        vatAmount = 0
    }
}


// MARK: - Bank

enum BooksBankFilter:
    String,
    CaseIterable,
    Identifiable {

    case unreconciled = "Unreconciled"
    case all = "All"

    var id: String {
        rawValue
    }
}


struct BankWorkspaceView: View {
    @ObservedObject private var repository =
        AccountingRepository.shared

    @State private var filter:
        BooksBankFilter = .unreconciled

    @State private var status = ""

    private var filteredTransactions:
        [BankTransactionRow] {

        switch filter {
        case .unreconciled:
            return repository.bankTransactions
                .filter {
                    !$0.reconciled
                }

        case .all:
            return repository.bankTransactions
        }
    }

    private var reconciledCount:
        Int {

        repository.bankTransactions
            .filter {
                $0.reconciled
            }
            .count
    }

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 14
        ) {
            HStack {
                Picker(
                    "Transactions",
                    selection: $filter
                ) {
                    ForEach(
                        BooksBankFilter.allCases
                    ) { item in
                        Text(item.rawValue)
                            .tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)

                Spacer()

                Button(
                    "Import statement…"
                ) {
                    importCSV()
                }
                .buttonStyle(
                    BooksPrimaryButtonStyle()
                )
                .help(
                    "Import a CSV bank statement"
                )
            }

            HStack(spacing: 12) {
                BooksMetricCard(
                    label: "Imported",
                    value:
                        "\(repository.bankTransactions.count)",
                    note:
                        "Statement transactions"
                )

                BooksMetricCard(
                    label: "Reconciled",
                    value:
                        "\(reconciledCount)",
                    note:
                        "Marked as reviewed"
                )

                BooksMetricCard(
                    label: "Remaining",
                    value:
                        "\(repository.bankTransactions.count - reconciledCount)",
                    note:
                        "Still awaiting review"
                )
            }

            BooksSectionCard(
                title:
                    filter == .unreconciled
                    ? "Transactions needing attention"
                    : "All imported transactions",
                subtitle:
                    "Compare each line with the ledger before marking it reconciled."
            ) {
                if filteredTransactions.isEmpty {
                    BooksEmptyState(
                        symbol:
                            repository.bankTransactions.isEmpty
                            ? "arrow.down.doc"
                            : "checkmark.circle",
                        title:
                            repository.bankTransactions.isEmpty
                            ? "No statement imported"
                            : "Everything is reconciled",
                        message:
                            repository.bankTransactions.isEmpty
                            ? "Import a CSV statement to begin."
                            : "The unreconciled queue is clear."
                    )
                } else {
                    List(
                        filteredTransactions
                    ) { transaction in
                        Toggle(
                            isOn: Binding(
                                get: {
                                    transaction.reconciled
                                },
                                set: { value in
                                    update(
                                        transaction,
                                        reconciled:
                                            value
                                    )
                                }
                            )
                        ) {
                            HStack(spacing: 16) {
                                VStack(
                                    alignment: .leading,
                                    spacing: 4
                                ) {
                                    Text(
                                        transaction.description
                                    )
                                    .font(
                                        .system(
                                            size: 12,
                                            weight: .medium
                                        )
                                    )

                                    HStack(spacing: 8) {
                                        Text(
                                            accountingDisplayDateFormatter
                                                .string(
                                                    from:
                                                        transaction.date
                                                )
                                        )

                                        if !transaction.reference
                                            .isEmpty {

                                            Text("•")

                                            Text(
                                                transaction.reference
                                            )
                                        }
                                    }
                                    .font(
                                        .system(
                                            size: 10
                                        )
                                    )
                                    .foregroundColor(
                                        booksMuted
                                    )
                                }

                                Spacer()

                                Text(
                                    booksMoney(
                                        transaction.amount
                                    )
                                )
                                .font(
                                    .system(
                                        size: 12,
                                        weight: .semibold
                                    )
                                )
                                .frame(
                                    width: 130,
                                    alignment: .trailing
                                )
                            }
                            .padding(.vertical, 5)
                        }
                        .toggleStyle(.checkbox)
                    }
                    .listStyle(.plain)
                    .frame(minHeight: 300)
                }
            }

            if !status.isEmpty {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundColor(
                        booksMuted
                    )
            }
        }
        .onAppear {
            repository.refresh()
        }
    }

    private func importCSV() {
        let panel = NSOpenPanel()

        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            .commaSeparatedText
        ]

        guard panel.runModal() == .OK,
              let url = panel.url else {
            return
        }

        do {
            let count =
                try repository.importBankCSV(
                    from: url
                )

            status =
                "\(count) transaction(s) imported."
        } catch {
            status =
                error.localizedDescription
        }
    }

    private func update(
        _ transaction:
            BankTransactionRow,
        reconciled: Bool
    ) {
        do {
            try repository
                .setBankTransaction(
                    transaction.id,
                    reconciled:
                        reconciled
                )
        } catch {
            status =
                error.localizedDescription
        }
    }
}


// MARK: - Reports

enum BooksReportKind:
    String,
    CaseIterable,
    Identifiable {

    case trialBalance =
        "Trial Balance"

    case incomeStatement =
        "Income Statement"

    case balanceSheet =
        "Balance Sheet"

    case agedReceivables =
        "Aged Receivables"

    var id: String {
        rawValue
    }
}


struct ReportsWorkspaceView: View {
    @ObservedObject private var repository =
        AccountingRepository.shared

    @State private var report:
        BooksReportKind = .trialBalance

    @State private var status = ""

    private var rows:
        [ReportRow] {

        switch report {
        case .incomeStatement:
            return repository
                .incomeStatement()

        case .balanceSheet:
            return repository
                .balanceSheet()

        case .trialBalance:
            return repository
                .trialBalance()

        case .agedReceivables:
            return []
        }
    }

    private var keyMetric:
        String {

        switch report {
        case .trialBalance:
            let debit = rows.reduce(0) {
                $0 + $1.debit
            }

            let credit = rows.reduce(0) {
                $0 + $1.credit
            }

            return booksMoney(
                debit - credit
            )

        case .incomeStatement:
            let income = rows
                .filter {
                    $0.type == "Income"
                }
                .reduce(0) {
                    $0 + $1.balance
                }

            let expense = rows
                .filter {
                    $0.type == "Expense"
                }
                .reduce(0) {
                    $0 + $1.balance
                }

            return booksMoney(
                income - expense
            )

        case .balanceSheet:
            return "\(rows.count) accounts"

        case .agedReceivables:
            let total = repository
                .receivables()
                .reduce(0) {
                    $0 + $1.balance
                }

            return booksMoney(total)
        }
    }

    private var keyMetricLabel:
        String {

        switch report {
        case .trialBalance:
            return "Difference"

        case .incomeStatement:
            return "Net result"

        case .balanceSheet:
            return "Active balances"

        case .agedReceivables:
            return "Outstanding"
        }
    }

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 14
        ) {
            HStack {
                Picker(
                    "Report",
                    selection: $report
                ) {
                    ForEach(
                        BooksReportKind.allCases
                    ) { item in
                        Text(item.rawValue)
                            .tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 620)

                Spacer()

                Button(
                    "Export accountant pack"
                ) {
                    export()
                }
                .buttonStyle(
                    BooksPrimaryButtonStyle()
                )
            }

            HStack(spacing: 12) {
                BooksMetricCard(
                    label:
                        keyMetricLabel,
                    value:
                        keyMetric,
                    note:
                        report.rawValue
                )

                BooksMetricCard(
                    label: "Rows",
                    value:
                        report == .agedReceivables
                        ? "\(repository.receivables().count)"
                        : "\(rows.count)",
                    note:
                        "Included in this view"
                )
            }

            if report ==
                .agedReceivables {

                agedReceivables
            } else {
                accountReport
            }

            if !status.isEmpty {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundColor(
                        booksMuted
                    )
            }
        }
    }

    private var accountReport:
        some View {

        BooksSectionCard(
            title: report.rawValue,
            subtitle:
                "Figures come from the local double-entry ledger."
        ) {
            if rows.isEmpty {
                BooksEmptyState(
                    symbol: "chart.bar",
                    title: "No ledger activity",
                    message:
                        "Post an invoice, expense or journal entry to populate this report."
                )
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text("ACCOUNT")
                            .frame(
                                maxWidth:
                                    .infinity,
                                alignment:
                                    .leading
                            )

                        Text("DEBIT")
                            .frame(
                                width: 110,
                                alignment:
                                    .trailing
                            )

                        Text("CREDIT")
                            .frame(
                                width: 110,
                                alignment:
                                    .trailing
                            )

                        Text("BALANCE")
                            .frame(
                                width: 120,
                                alignment:
                                    .trailing
                            )
                    }
                    .font(
                        .system(
                            size: 9,
                            weight: .medium
                        )
                    )
                    .foregroundColor(
                        booksMuted
                    )
                    .padding(.bottom, 8)

                    Divider()

                    List(rows) { row in
                        HStack {
                            Text(
                                "\(row.code)  \(row.name)"
                            )
                            .frame(
                                maxWidth:
                                    .infinity,
                                alignment:
                                    .leading
                            )

                            Text(
                                booksMoney(
                                    row.debit
                                )
                            )
                            .frame(
                                width: 110,
                                alignment:
                                    .trailing
                            )

                            Text(
                                booksMoney(
                                    row.credit
                                )
                            )
                            .frame(
                                width: 110,
                                alignment:
                                    .trailing
                            )

                            Text(
                                booksMoney(
                                    row.balance
                                )
                            )
                            .font(
                                .system(
                                    size: 12,
                                    weight:
                                        .medium
                                )
                            )
                            .frame(
                                width: 120,
                                alignment:
                                    .trailing
                            )
                        }
                        .font(
                            .system(size: 11)
                        )
                        .padding(.vertical, 3)
                    }
                    .listStyle(.plain)
                    .frame(minHeight: 300)
                }
            }
        }
    }

    private var agedReceivables:
        some View {

        let receivables =
            repository.receivables()

        return BooksSectionCard(
            title: "Aged receivables",
            subtitle:
                "Outstanding invoices grouped by the number of days past due."
        ) {
            if receivables.isEmpty {
                BooksEmptyState(
                    symbol:
                        "checkmark.circle",
                    title:
                        "No outstanding invoices",
                    message:
                        "All recorded invoice balances are settled."
                )
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text("INVOICE")
                            .frame(
                                width: 120,
                                alignment:
                                    .leading
                            )

                        Text("CLIENT")
                            .frame(
                                maxWidth:
                                    .infinity,
                                alignment:
                                    .leading
                            )

                        Text("AGE")
                            .frame(
                                width: 70,
                                alignment:
                                    .trailing
                            )

                        Text("BALANCE")
                            .frame(
                                width: 130,
                                alignment:
                                    .trailing
                            )
                    }
                    .font(
                        .system(
                            size: 9,
                            weight: .medium
                        )
                    )
                    .foregroundColor(
                        booksMuted
                    )
                    .padding(.bottom, 8)

                    Divider()

                    List(receivables) {
                        row in

                        HStack {
                            Text(
                                row.invoiceNumber
                            )
                            .frame(
                                width: 120,
                                alignment:
                                    .leading
                            )

                            VStack(
                                alignment:
                                    .leading,
                                spacing: 3
                            ) {
                                Text(
                                    row.clientName
                                )

                                Text(
                                    accountingDisplayDateFormatter
                                        .string(
                                            from:
                                                row.dueDate
                                        )
                                )
                                .font(
                                    .system(
                                        size: 9
                                    )
                                )
                                .foregroundColor(
                                    booksMuted
                                )
                            }
                            .frame(
                                maxWidth:
                                    .infinity,
                                alignment:
                                    .leading
                            )

                            Text(row.bucket)
                                .frame(
                                    width: 70,
                                    alignment:
                                        .trailing
                                )

                            Text(
                                booksMoney(
                                    row.balance
                                )
                            )
                            .font(
                                .system(
                                    size: 12,
                                    weight:
                                        .medium
                                )
                            )
                            .frame(
                                width: 130,
                                alignment:
                                    .trailing
                            )
                        }
                        .font(
                            .system(size: 11)
                        )
                        .padding(.vertical, 4)
                    }
                    .listStyle(.plain)
                    .frame(minHeight: 300)
                }
            }
        }
    }

    private func export() {
        do {
            _ = try repository
                .exportDefaultAccountantPack()

            status =
                "Accountant pack exported."
        } catch {
            status =
                error.localizedDescription
        }
    }
}


// MARK: - Compliance

struct ComplianceWorkspaceView: View {
    @ObservedObject private var repository =
        AccountingRepository.shared

    let openCompany:
        () -> Void

    var body: some View {
        ScrollView {
            VStack(
                alignment: .leading,
                spacing: 16
            ) {
                HStack(
                    alignment: .top,
                    spacing: 14
                ) {
                    BooksSectionCard(
                        title:
                            "Public Interest Score",
                        subtitle:
                            "Calculated from the company profile."
                    ) {
                        Text(
                            "\(repository.profile.publicInterestScore)"
                        )
                        .font(
                            .system(
                                size: 46,
                                weight: .bold
                            )
                        )

                        Button(
                            "Review score inputs"
                        ) {
                            openCompany()
                        }
                        .buttonStyle(
                            BooksSecondaryButtonStyle()
                        )
                    }

                    BooksSectionCard(
                        title:
                            "Score components",
                        subtitle:
                            "A quick view of the four saved inputs."
                    ) {
                        scoreLine(
                            "Average employees",
                            value:
                                "\(repository.profile.averageEmployees)"
                        )

                        scoreLine(
                            "Turnover millions",
                            value:
                                String(
                                    format:
                                        "%.1f",
                                    repository.profile.annualTurnover
                                        / 1_000_000
                                )
                        )

                        scoreLine(
                            "Third-party liability millions",
                            value:
                                String(
                                    format:
                                        "%.1f",
                                    repository.profile.thirdPartyLiabilities
                                        / 1_000_000
                                )
                        )

                        scoreLine(
                            "Beneficial-interest holders",
                            value:
                                "\(repository.profile.beneficialInterestHolders)"
                        )
                    }
                }

                BooksInlineCallout(
                    symbol:
                        "calendar.badge.exclamationmark",
                    text:
                        "These are planning reminders generated from the saved year-end and incorporation date. Confirm filing dates with the company’s accountant."
                )

                BooksSectionCard(
                    title:
                        "Upcoming obligations",
                    subtitle:
                        "The nearest deadlines appear first."
                ) {
                    VStack(spacing: 0) {
                        ForEach(
                            repository
                                .complianceCalendar()
                        ) { item in
                            HStack(
                                alignment: .center,
                                spacing: 14
                            ) {
                                VStack(
                                    alignment:
                                        .leading,
                                    spacing: 4
                                ) {
                                    Text(item.title)
                                        .font(
                                            .system(
                                                size: 12,
                                                weight:
                                                    .medium
                                            )
                                        )

                                    Text(
                                        "\(item.category) — \(item.note)"
                                    )
                                    .font(
                                        .system(
                                            size: 10
                                        )
                                    )
                                    .foregroundColor(
                                        booksMuted
                                    )
                                }

                                Spacer()

                                BooksDeadlineBadge(
                                    date:
                                        item.dueDate
                                )

                                Text(
                                    accountingDisplayDateFormatter
                                        .string(
                                            from:
                                                item.dueDate
                                        )
                                )
                                .font(
                                    .system(
                                        size: 11,
                                        weight:
                                            .semibold
                                    )
                                )
                                .frame(
                                    width: 120,
                                    alignment:
                                        .trailing
                                )
                            }
                            .padding(.vertical, 11)

                            if item.id !=
                                repository
                                    .complianceCalendar()
                                    .last?.id {

                                Divider()
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 24)
        }
    }

    private func scoreLine(
        _ label: String,
        value: String
    ) -> some View {

        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(
                    booksMuted
                )

            Spacer()

            Text(value)
                .font(
                    .system(
                        size: 12,
                        weight: .semibold
                    )
                )
        }
    }
}


struct BooksDeadlineBadge: View {
    let date: Date

    private var days:
        Int {

        Calendar.current.dateComponents(
            [.day],
            from:
                Calendar.current
                    .startOfDay(
                        for: Date()
                    ),
            to:
                Calendar.current
                    .startOfDay(
                        for: date
                    )
        ).day ?? 0
    }

    private var text:
        String {

        if days < 0 {
            return "\(abs(days))d overdue"
        }

        if days == 0 {
            return "Today"
        }

        return "\(days)d"
    }

    var body: some View {
        Text(text)
            .font(
                .system(
                    size: 9,
                    weight: .semibold
                )
            )
            .foregroundColor(
                days < 0
                    ? booksWarning
                    : booksMuted
            )
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                days < 0
                    ? booksWarning.opacity(0.08)
                    : Color.black.opacity(0.035)
            )
            .overlay(
                Capsule()
                    .stroke(
                        days < 0
                            ? booksWarning.opacity(0.28)
                            : booksBorder,
                        lineWidth: 1
                    )
            )
    }
}


// MARK: - Records

struct RecordsWorkspaceView: View {
    @ObservedObject private var repository =
        AccountingRepository.shared

    @State private var linkedType =
        "General"

    @State private var linkedId = ""
    @State private var status = ""

    private let recordTypes = [
        "General",
        "Invoice",
        "Payment",
        "Expense",
        "Bank",
        "Tax",
        "CIPC"
    ]

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 14
        ) {
            BooksSectionCard(
                title:
                    "Archive a supporting document",
                subtitle:
                    "A copy is stored inside INV’s local application-support folder."
            ) {
                HStack(
                    alignment: .bottom,
                    spacing: 14
                ) {
                    VStack(
                        alignment: .leading,
                        spacing: 6
                    ) {
                        Text("DOCUMENT TYPE")
                            .font(
                                .system(
                                    size: 9,
                                    weight: .medium
                                )
                            )
                            .foregroundColor(
                                booksMuted
                            )

                        Picker(
                            "",
                            selection:
                                $linkedType
                        ) {
                            ForEach(
                                recordTypes,
                                id: \.self
                            ) { type in
                                Text(type)
                                    .tag(type)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }

                    BooksTextInput(
                        label:
                            "Linked reference",
                        placeholder:
                            "Invoice, payment or filing reference",
                        text: $linkedId
                    )

                    Button(
                        "Archive document…"
                    ) {
                        archive()
                    }
                    .buttonStyle(
                        BooksPrimaryButtonStyle()
                    )
                }
            }

            BooksSectionCard(
                title:
                    "Archived documents",
                subtitle:
                    "\(repository.sourceDocuments.count) document(s) stored locally."
            ) {
                if repository
                    .sourceDocuments
                    .isEmpty {

                    BooksEmptyState(
                        symbol:
                            "archivebox",
                        title:
                            "No supporting documents",
                        message:
                            "Archive receipts, statements and filing confirmations here."
                    )
                } else {
                    List(
                        repository
                            .sourceDocuments
                    ) { document in
                        Button {
                            NSWorkspace.shared.open(
                                URL(
                                    fileURLWithPath:
                                        document.storedPath
                                )
                            )
                        } label: {
                            HStack(spacing: 14) {
                                Image(
                                    systemName:
                                        "doc"
                                )
                                .foregroundColor(
                                    booksMuted
                                )

                                VStack(
                                    alignment:
                                        .leading,
                                    spacing: 4
                                ) {
                                    Text(
                                        document.fileName
                                    )
                                    .font(
                                        .system(
                                            size: 12,
                                            weight:
                                                .medium
                                        )
                                    )

                                    Text(
                                        "\(document.linkedType) \(document.linkedId)"
                                    )
                                    .font(
                                        .system(
                                            size: 10
                                        )
                                    )
                                    .foregroundColor(
                                        booksMuted
                                    )
                                }

                                Spacer()

                                VStack(
                                    alignment:
                                        .trailing,
                                    spacing: 4
                                ) {
                                    Text(
                                        "RETAIN UNTIL"
                                    )
                                    .font(
                                        .system(
                                            size: 8,
                                            weight:
                                                .medium
                                        )
                                    )
                                    .foregroundColor(
                                        booksMuted
                                    )

                                    Text(
                                        accountingDisplayDateFormatter
                                            .string(
                                                from:
                                                    document.retentionUntil
                                            )
                                    )
                                    .font(
                                        .system(
                                            size: 10
                                        )
                                    )
                                }
                            }
                            .foregroundColor(
                                booksInk
                            )
                            .padding(.vertical, 5)
                            .contentShape(
                                Rectangle()
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                    .frame(minHeight: 300)
                }
            }

            if !status.isEmpty {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundColor(
                        booksMuted
                    )
            }
        }
        .onAppear {
            repository.refresh()
        }
    }

    private func archive() {
        do {
            try repository
                .addSourceDocument(
                    linkedType:
                        linkedType,
                    linkedId:
                        linkedId
                )

            status =
                "Document archived."

            linkedId = ""
        } catch {
            status =
                error.localizedDescription
        }
    }
}
