import type { DocumentListQuery, DmsDocumentKind, SearchQuery } from '#lib/api/client';
import type { Locale } from '#lib/i18n/index.svelte';

/** Document kinds of the extractor (contract `DmsDocumentKind`), with their text keys (literal keys so the unused-text test sees them). */
export const KIND_LABEL = {
	invoice: 'dms.kind.invoice',
	receipt: 'dms.kind.receipt',
	contract: 'dms.kind.contract',
	letter: 'dms.kind.letter',
	bank_statement: 'dms.kind.bank_statement',
	insurance: 'dms.kind.insurance',
	tax_notice: 'dms.kind.tax_notice',
	reminder: 'dms.kind.reminder',
	other: 'dms.kind.other'
} as const satisfies Record<DmsDocumentKind, string>;
export const KINDS = Object.keys(KIND_LABEL) as DmsDocumentKind[];

/** Fact types of the contract with their text keys. */
export const FACT_LABEL = {
	invoice_number: 'dms.fact.invoice_number',
	reference: 'dms.fact.reference',
	date: 'dms.fact.date',
	due_date: 'dms.fact.due_date',
	deadline: 'dms.fact.deadline',
	amount: 'dms.fact.amount',
	amount_gross: 'dms.fact.amount_gross',
	amount_net: 'dms.fact.amount_net',
	amount_tax: 'dms.fact.amount_tax',
	iban: 'dms.fact.iban',
	vat_id: 'dms.fact.vat_id',
	seller: 'dms.fact.seller',
	title: 'dms.fact.title'
} as const;
export const AMOUNT_FACTS = new Set(['amount', 'amount_gross', 'amount_net', 'amount_tax']);
export const DATE_FACTS = new Set(['date', 'due_date', 'deadline']);

export type SortKey = 'received' | 'date' | 'amount' | 'due';
export type SortOrder = 'asc' | 'desc';
export type DueFilter = '' | 'overdue' | 'week' | 'due';
export type DatePreset = 'today' | 'week' | 'month' | 'year';

export interface OverviewFilters {
	q: string;
	type: string;
	corr: string;
	tags: string[];
	from: string;
	to: string;
	trash: boolean;
	kind: DmsDocumentKind | '';
	/** Amount range as validated decimal strings (empty = none). */
	min: string;
	max: string;
	cur: string;
	due: DueFilter;
	sort: SortKey;
	order: SortOrder;
	/** Only documents with open suggestions (filtered on the client from the suggestion list). */
	open: boolean;
}

const SORTS: SortKey[] = ['received', 'date', 'amount', 'due'];
const DUES: DueFilter[] = ['overdue', 'week', 'due'];

export const defaultOrder = (sort: SortKey): SortOrder => (sort === 'due' ? 'asc' : 'desc');

/** Accepts `1234.5`, `1.234,56`-free input: digits with an optional comma or point and at most two decimals. Returns the contract form or null. */
export function normalizeAmount(text: string): string | null {
	const t = text.trim().replace(',', '.');
	return /^-?\d{1,13}(\.\d{1,2})?$/.test(t) ? t : null;
}

/** Reads the filters from the URL (the URL is the state: reload, back button, bookmark). Unknown or invalid values are dropped. */
export function parseFilters(sp: URLSearchParams): OverviewFilters {
	const kind = sp.get('kind') ?? '';
	const sort = (SORTS as string[]).includes(sp.get('sort') ?? '') ? (sp.get('sort') as SortKey) : 'received';
	const order = sp.get('order') === 'asc' || sp.get('order') === 'desc' ? (sp.get('order') as SortOrder) : defaultOrder(sort);
	const due = (DUES as string[]).includes(sp.get('due') ?? '') ? (sp.get('due') as DueFilter) : '';
	const cur = (sp.get('cur') ?? '').toUpperCase();
	return {
		q: sp.get('q') ?? '',
		type: sp.get('type') ?? '',
		corr: sp.get('corr') ?? '',
		tags: (sp.get('tags') ?? '').split(',').filter(Boolean),
		from: sp.get('from') ?? '',
		to: sp.get('to') ?? '',
		trash: sp.get('trash') === '1',
		kind: (KINDS as string[]).includes(kind) ? (kind as DmsDocumentKind) : '',
		min: normalizeAmount(sp.get('min') ?? '') ?? '',
		max: normalizeAmount(sp.get('max') ?? '') ?? '',
		cur: /^[A-Z]{3}$/.test(cur) ? cur : '',
		due,
		sort,
		order,
		open: sp.get('open') === '1'
	};
}

/**
 * The list route (`GET …/documents`) is needed for extraction filters (kind, amount, due date), for sorting by date/amount/due date and
 * for the trash. Everything else runs on the search route (snippets, facets, several tags, document date).
 */
export function usesListRoute(f: OverviewFilters): boolean {
	return f.trash || extendedActive(f);
}

export function extendedActive(f: OverviewFilters): boolean {
	return Boolean(f.kind || f.min || f.max || f.cur || f.due) || f.sort !== 'received' || f.order !== 'desc';
}

export function hasAnyFilter(f: OverviewFilters): boolean {
	return Boolean(f.q || f.type || f.corr || f.tags.length || f.from || f.to || f.trash || f.open) || extendedActive(f);
}

// --- calendar helpers on `yyyy-MM-dd` strings (no time zone arithmetic beyond UTC date math) ---

export function localToday(now: Date = new Date()): string {
	const month = String(now.getMonth() + 1).padStart(2, '0');
	return `${now.getFullYear()}-${month}-${String(now.getDate()).padStart(2, '0')}`;
}

export function addDays(day: string, days: number): string {
	const d = new Date(`${day}T00:00:00Z`);
	d.setUTCDate(d.getUTCDate() + days);
	return d.toISOString().slice(0, 10);
}

/** Quick time ranges: today, the last 7 days (including today), the current calendar month and year. */
export function presetRange(preset: DatePreset, today: string): { from: string; to: string } {
	if (preset === 'today') return { from: today, to: today };
	if (preset === 'week') return { from: addDays(today, -6), to: today };
	const [year, month] = today.split('-');
	if (preset === 'month') {
		const last = new Date(Date.UTC(Number(year), Number(month), 0)).getUTCDate();
		return { from: `${year}-${month}-01`, to: `${year}-${month}-${String(last).padStart(2, '0')}` };
	}
	return { from: `${year}-01-01`, to: `${year}-12-31` };
}

export function activePreset(f: Pick<OverviewFilters, 'from' | 'to'>, today: string): DatePreset | null {
	for (const preset of ['today', 'week', 'month', 'year'] as const) {
		const r = presetRange(preset, today);
		if (r.from === f.from && r.to === f.to) return preset;
	}
	return null;
}

/** Due date filter: overdue = before today, week = today through the next 6 days, due = today or earlier (due and overdue). */
export function dueRange(due: DueFilter, today: string): { due_from?: string; due_to?: string } {
	if (due === 'overdue') return { due_to: addDays(today, -1) };
	if (due === 'week') return { due_from: today, due_to: addDays(today, 6) };
	if (due === 'due') return { due_to: today };
	return {};
}

/** Parameters of `GET …/documents` for the filters. The date range applies to the recognised document date (`extracted_*`); `q` matches the title only. */
export function toListQuery(f: OverviewFilters, today: string, cursor: string | null, limit = 25): DocumentListQuery {
	const apiSort = { received: 'created_at', date: 'extracted_date', amount: 'amount', due: 'due_date' } as const;
	return {
		trashed: f.trash,
		q: f.q || undefined,
		cursor,
		limit,
		document_type_id: f.type || undefined,
		correspondent_id: f.corr || undefined,
		tag_id: f.tags[0] || undefined,
		kind: f.kind || undefined,
		currency: f.cur || undefined,
		amount_min: f.min || undefined,
		amount_max: f.max || undefined,
		extracted_from: f.from || undefined,
		extracted_to: f.to || undefined,
		...dueRange(f.due, today),
		sort: apiSort[f.sort],
		order: f.order
	};
}

/** Parameters of `GET …/search`; the date range applies to the document date (`doc_date`). */
export function toSearchQuery(f: OverviewFilters, cursor: string | null, limit = 25): SearchQuery {
	return {
		q: f.q,
		cursor,
		limit,
		facets: true,
		document_type_id: f.type || undefined,
		correspondent_id: f.corr || undefined,
		tag_id: f.tags.join(',') || undefined,
		date_from: f.from || undefined,
		date_to: f.to || undefined
	};
}

/** An amount (decimal string) with its currency in the UI locale. The string is formatted exactly (no float round trip). */
export function formatMoney(amount: string | null | undefined, currency: string | null | undefined, locale: Locale): string {
	if (!amount) return '';
	if (!currency) return amount;
	try {
		return new Intl.NumberFormat(locale, { style: 'currency', currency }).format(amount as `${number}`);
	} catch {
		return `${amount} ${currency}`;
	}
}

/** True when a due date lies before today. */
export const isOverdue = (due: string | null | undefined, today: string): boolean => Boolean(due) && (due as string) < today;
