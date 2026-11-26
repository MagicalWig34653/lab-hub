# invoice-vectors

Synthetic conformance vectors for the invoice calculation core (WP-R0). All decimals are strings; compare numerically (expected values omit trailing zeros, e.g. "291.9").

The values were generated once from the reference implementation of the existing invoicing app (not part of this repository). These files are now the maintained source of truth; change them only together with a deliberate rule change.

- `rounding.json`: mode (`halfAwayFromZero`, `halfEven`, `towardZero`), scale, input, expected
- `document-totals.json`: lines/charges/discounts/priceMode (`net`|`gross`) -> totals per tax rate and overall
- `number-format.json`: template + context -> formatted number, counter scope, series key, parsed match, or error name
- `balances.json`: gross + payments (allocations per document id) + linked documents -> paid/open/total balance
