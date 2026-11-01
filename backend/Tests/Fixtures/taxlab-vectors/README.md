# taxlab-vectors

Synthetic conformance vectors for the invoice calculation core (WP-R0). All decimals are strings; compare numerically (the reference omits trailing zeros, e.g. "291.9").

Generated with the taxlab reference implementation on Linux: `scripts/spike-r0/generate-vectors.sh`.

- `rounding.json`: mode (`halfAwayFromZero`, `halfEven`, `towardZero`), scale, input, expected
- `document-totals.json`: lines/charges/discounts/priceMode (`net`|`gross`) -> totals per tax rate and overall
- `number-format.json`: template + context -> formatted number, counter scope, series key, parsed match, or error name
- `balances.json`: gross + payments (allocations per document id) + linked documents -> paid/open/total balance
