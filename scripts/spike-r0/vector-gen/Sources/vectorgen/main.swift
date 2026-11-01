import Foundation
import TaxlabCore
import TaxlabModel

// All inputs are synthetic. Decimals are written as strings, never as floating point numbers.
func dec(_ s: String) -> Decimal { Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))! }
func s(_ d: Decimal) -> String { "\(d)" }
func js(_ v: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [v], options: [])
    var t = String(decoding: data, as: UTF8.self)
    t.removeFirst(); t.removeLast()
    return t.replacingOccurrences(of: "\\/", with: "/")
}
func jsOpt(_ v: String?) -> String { v.map(js) ?? "null" }

// ---------- rounding ----------
struct RoundCase { let id: String; let mode: RoundingMode; let scale: Int; let value: String }
let roundTuples: [(String, RoundingMode, Int, String)] = [
    ("half-up-pos", .halfAwayFromZero, 2, "2.675"), ("half-up-neg", .halfAwayFromZero, 2, "-2.675"),
    ("half-up-below", .halfAwayFromZero, 2, "2.674"), ("half-even-down", .halfEven, 2, "2.665"),
    ("half-even-up", .halfEven, 2, "2.675"), ("half-even-neg", .halfEven, 2, "-0.125"),
    ("toward-zero-pos", .towardZero, 2, "9.999"), ("toward-zero-neg", .towardZero, 2, "-9.999"),
    ("scale0", .halfAwayFromZero, 0, "0.5"), ("scale0-neg", .halfAwayFromZero, 0, "-0.5"),
    ("scale3", .halfAwayFromZero, 3, "1.00049"), ("exact", .halfAwayFromZero, 2, "19.99"),
    ("zero", .halfAwayFromZero, 2, "0"), ("tiny", .halfAwayFromZero, 2, "0.004"),
] 
let roundCases: [RoundCase] = roundTuples.map { RoundCase(id: $0.0, mode: $0.1, scale: $0.2, value: $0.3) }

// ---------- document totals ----------
struct LineSpec { let rate: String; let price: String; let qty: String; var second: String? = nil; var discount: (kind: String, value: String)? = nil }
struct ChargeSpec { let rate: String; let amount: String }
struct DocCase {
    let id: String; let mode: PriceInputMode; let lines: [LineSpec]; var charges: [ChargeSpec] = []
    var discountPercent = "0"; var discountAmount: String? = nil
    var rounding: (RoundingMode, Int) = (.halfAwayFromZero, 2)
}
let docCases: [DocCase] = [
    DocCase(id: "net-single-19", mode: .net, lines: [LineSpec(rate: "19", price: "100", qty: "1")]),
    DocCase(id: "net-many-small-lines-round-on-sum", mode: .net, lines: (0..<7).map { _ in LineSpec(rate: "19", price: "0.333", qty: "1") }),
    DocCase(id: "net-mixed-rates", mode: .net, lines: [LineSpec(rate: "19", price: "49.99", qty: "3"), LineSpec(rate: "7", price: "12.5", qty: "2.5"), LineSpec(rate: "0", price: "80", qty: "1")]),
    DocCase(id: "gross-mixed-rates", mode: .gross, lines: [LineSpec(rate: "19", price: "119", qty: "1"), LineSpec(rate: "7", price: "10.70", qty: "3")]),
    DocCase(id: "gross-odd-cents", mode: .gross, lines: [LineSpec(rate: "19", price: "9.99", qty: "7"), LineSpec(rate: "19", price: "0.01", qty: "1")]),
    DocCase(id: "net-line-discount-percent", mode: .net, lines: [LineSpec(rate: "19", price: "200", qty: "2", discount: ("percent", "12.5"))]),
    DocCase(id: "net-line-discount-amount", mode: .net, lines: [LineSpec(rate: "19", price: "200", qty: "2", discount: ("amount", "30"))]),
    DocCase(id: "net-second-quantity", mode: .net, lines: [LineSpec(rate: "19", price: "15", qty: "2", second: "3.5")]),
    DocCase(id: "net-document-discount-percent", mode: .net, lines: [LineSpec(rate: "19", price: "100", qty: "1"), LineSpec(rate: "7", price: "50", qty: "1")], discountPercent: "10"),
    DocCase(id: "net-document-discount-amount", mode: .net, lines: [LineSpec(rate: "19", price: "100", qty: "1"), LineSpec(rate: "7", price: "50", qty: "1")], discountAmount: "15"),
    DocCase(id: "net-charges-not-discounted", mode: .net, lines: [LineSpec(rate: "19", price: "100", qty: "1")], charges: [ChargeSpec(rate: "19", amount: "5.9"), ChargeSpec(rate: "0", amount: "2")], discountPercent: "10"),
    DocCase(id: "net-negative-credit-note", mode: .net, lines: [LineSpec(rate: "19", price: "-45.55", qty: "3")]),
    DocCase(id: "net-half-even", mode: .net, lines: [LineSpec(rate: "19", price: "0.125", qty: "1"), LineSpec(rate: "7", price: "0.065", qty: "1")], rounding: (.halfEven, 2)),
    DocCase(id: "net-toward-zero", mode: .net, lines: [LineSpec(rate: "19", price: "10.019", qty: "1")], rounding: (.towardZero, 2)),
    DocCase(id: "empty", mode: .net, lines: []),
    DocCase(id: "net-fractional-rate", mode: .net, lines: [LineSpec(rate: "5.5", price: "99.99", qty: "3")]),
]

func buildInput(_ c: DocCase) -> DocumentInput {
    let lines = c.lines.map { l -> LineItem in
        var disc: LineDiscount? = nil
        if let d = l.discount { disc = d.kind == "percent" ? .percent(dec(d.value)) : .amount(dec(d.value)) }
        return LineItem(taxGroup: TaxGroup(id: "g\(l.rate)", name: "g", rate: dec(l.rate)), unitPrice: dec(l.price), quantity: dec(l.qty), secondQuantity: l.second.map(dec), discount: disc)
    }
    let charges = c.charges.map { AdditionalCharge(taxGroup: TaxGroup(id: "g\($0.rate)", name: "g", rate: dec($0.rate)), amount: dec($0.amount)) }
    var input = DocumentInput(priceMode: c.mode, lines: lines, charges: charges, documentDiscountPercent: dec(c.discountPercent), rounding: RoundingRule(mode: c.rounding.0, scale: c.rounding.1))
    input.documentDiscountAmount = c.discountAmount.map(dec)
    return input
}

// ---------- number format ----------
struct NumCase { let id: String; let template: String; var year = 2026; var month = 3; var counter = 42
    var abbr: String? = nil; var client: String? = nil; var project: String? = nil }
let numCases: [NumCase] = [
    NumCase(id: "year-month-counter5", template: "{YYYY}-{MM}-{N:5}"),
    NumCase(id: "short-year", template: "{YY}{N}"),
    NumCase(id: "prefix-literal", template: "RE-{YYYY}-{N:4}", counter: 7),
    NumCase(id: "abbr-client-project", template: "{ABBR}/{CLIENT}/{PROJECT}/{N:3}", counter: 4, abbr: "RE", client: "K007", project: "WEB"),
    NumCase(id: "escaped-braces", template: "{{{N}}}"),
    NumCase(id: "counter-overflow-digits", template: "{N:3}", counter: 123456),
    NumCase(id: "continuous", template: "R{N:6}", counter: 1),
    NumCase(id: "december", template: "{YYYY}{MM}-{N:3}", year: 2027, month: 12, counter: 999),
    NumCase(id: "error-unknown-token", template: "{FOO}{N}"),
    NumCase(id: "error-unbalanced", template: "{N"),
    NumCase(id: "error-no-counter", template: "{YYYY}"),
    NumCase(id: "error-two-counters", template: "{N}{N}"),
    NumCase(id: "error-zero-digits", template: "{N:0}"),
    NumCase(id: "error-missing-client", template: "{CLIENT}-{N}"),
    NumCase(id: "error-counter-zero", template: "{N}", counter: 0),
]
func scopeName(_ c: CounterScope) -> String { c.rawValue }

// ---------- balances ----------
struct BalCase { let id: String; let gross: String; let payments: [(String, String, [String: String])]; let linked: [(String, String)] }
let balCases: [BalCase] = [
    BalCase(id: "unpaid", gross: "119", payments: [], linked: []),
    BalCase(id: "partial-direct", gross: "119", payments: [("p1", "50", ["doc": "50"])], linked: []),
    BalCase(id: "overpaid", gross: "100", payments: [("p1", "120", ["doc": "120"])], linked: []),
    BalCase(id: "with-credit-note", gross: "200", payments: [("p1", "50", ["doc": "50"])], linked: [("cn", "-30")]),
    BalCase(id: "payment-split-over-documents", gross: "100", payments: [("p1", "100", ["doc": "40", "other": "60"])], linked: []),
]

// ---------- emit ----------
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
func write(_ name: String, _ json: String) {
    try! json.write(toFile: outDir + "/" + name, atomically: true, encoding: .utf8)
}
var count = 0

var r = "{\n  \"suite\": \"rounding\",\n  \"note\": \"Synthetic. Reference: TaxlabCore RoundingRule.apply. Values are decimal strings.\",\n  \"vectors\": [\n"
r += roundCases.map { c in
    count += 1
    let out = RoundingRule(mode: c.mode, scale: c.scale).apply(dec(c.value))
    return "    {\"id\": \(js(c.id)), \"mode\": \(js(c.mode.rawValue)), \"scale\": \(c.scale), \"input\": \(js(c.value)), \"expected\": \(js(s(out)))}"
}.joined(separator: ",\n") + "\n  ]\n}\n"
write("rounding.json", r)

var t = "{\n  \"suite\": \"document-totals\",\n  \"note\": \"Synthetic. Reference: TaxlabCore DocumentCalculator.calculate. Rounding only per tax rate on document level. Prices are in the input mode (net or gross). Decimal strings only.\",\n  \"vectors\": [\n"
t += docCases.map { c in
    count += 1
    let tot = DocumentCalculator.calculate(buildInput(c))
    let lines = c.lines.map { l -> String in
        let disc = l.discount.map { "{\"kind\": \(js($0.kind)), \"value\": \(js($0.value))}" } ?? "null"
        return "{\"taxRate\": \(js(l.rate)), \"unitPrice\": \(js(l.price)), \"quantity\": \(js(l.qty)), \"secondQuantity\": \(jsOpt(l.second)), \"discount\": \(disc)}"
    }.joined(separator: ", ")
    let charges = c.charges.map { "{\"taxRate\": \(js($0.rate)), \"amount\": \(js($0.amount))}" }.joined(separator: ", ")
    let byRate = tot.byRate.map { "{\"rate\": \(js(s($0.rate))), \"net\": \(js(s($0.net.amount))), \"tax\": \(js(s($0.tax.amount))), \"gross\": \(js(s($0.gross.amount)))}" }.joined(separator: ", ")
    return "    {\"id\": \(js(c.id)), \"input\": {\"priceMode\": \(js(c.mode.rawValue)), \"lines\": [\(lines)], \"charges\": [\(charges)], \"documentDiscountPercent\": \(js(c.discountPercent)), \"documentDiscountAmount\": \(jsOpt(c.discountAmount)), \"rounding\": {\"mode\": \(js(c.rounding.0.rawValue)), \"scale\": \(c.rounding.1)}},\n     \"expected\": {\"byRate\": [\(byRate)], \"net\": \(js(s(tot.net.amount))), \"tax\": \(js(s(tot.tax.amount))), \"gross\": \(js(s(tot.gross.amount))), \"documentDiscount\": \(js(s(tot.documentDiscount.amount)))}}"
}.joined(separator: ",\n") + "\n  ]\n}\n"
write("document-totals.json", t)

var n = "{\n  \"suite\": \"number-format\",\n  \"note\": \"Synthetic. Reference: TaxlabModel NumberFormat (format, counterScope, seriesKey, match). expected is either a string or {error}.\",\n  \"vectors\": [\n"
n += numCases.map { c in
    count += 1
    let ctx = NumberContext(year: c.year, month: c.month, counter: c.counter, abbreviation: c.abbr, clientNumber: c.client, projectCode: c.project)
    let input = "{\"template\": \(js(c.template)), \"year\": \(c.year), \"month\": \(c.month), \"counter\": \(c.counter), \"abbreviation\": \(jsOpt(c.abbr)), \"clientNumber\": \(jsOpt(c.client)), \"projectCode\": \(jsOpt(c.project))}"
    do {
        let f = try NumberFormat(template: c.template)
        let formatted = try f.format(ctx)
        let m = f.match(formatted)
        let match = m.map { "{\"year\": \($0.year.map(String.init) ?? "null"), \"month\": \($0.month.map(String.init) ?? "null"), \"counter\": \($0.counter)}" } ?? "null"
        return "    {\"id\": \(js(c.id)), \"input\": \(input),\n     \"expected\": {\"formatted\": \(js(formatted)), \"counterScope\": \(js(scopeName(f.counterScope))), \"seriesKey\": \(js(f.seriesKey(typeKey: "invoice", context: ctx))), \"match\": \(match)}}"
    } catch {
        return "    {\"id\": \(js(c.id)), \"input\": \(input),\n     \"expected\": {\"error\": \(js("\(error)"))}}"
    }
}.joined(separator: ",\n") + "\n  ]\n}\n"
write("number-format.json", n)

var b = "{\n  \"suite\": \"balances\",\n  \"note\": \"Synthetic. Reference: TaxlabCore Balances.compute for document id 'doc'. Payment.allocations map document id to amount.\",\n  \"vectors\": [\n"
b += balCases.map { c in
    count += 1
    let pays = c.payments.map { Payment(id: $0.0, amount: Money(dec($0.1)), documentID: nil, allocations: $0.2.mapValues { Money(dec($0)) }) }
    let linked = c.linked.map { LinkedDocument(id: $0.0, gross: Money(dec($0.1))) }
    let bal = Balances.compute(documentID: "doc", gross: Money(dec(c.gross)), payments: pays, linkedDocuments: linked)
    let pj = c.payments.map { p in "{\"id\": \(js(p.0)), \"amount\": \(js(p.1)), \"allocations\": {" + p.2.sorted { $0.key < $1.key }.map { "\(js($0.key)): \(js($0.value))" }.joined(separator: ", ") + "}}" }.joined(separator: ", ")
    let lj = c.linked.map { "{\"id\": \(js($0.0)), \"gross\": \(js($0.1))}" }.joined(separator: ", ")
    return "    {\"id\": \(js(c.id)), \"input\": {\"gross\": \(js(c.gross)), \"payments\": [\(pj)], \"linkedDocuments\": [\(lj)]},\n     \"expected\": {\"paid\": \(js(s(bal.paid.amount))), \"openBalance\": \(js(s(bal.openBalance.amount))), \"totalBalance\": \(js(s(bal.totalBalance.amount)))}}"
}.joined(separator: ",\n") + "\n  ]\n}\n"
write("balances.json", b)

print("vectors: \(count)")
