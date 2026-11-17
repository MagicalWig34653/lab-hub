import type { DocumentListQuery, DmsDocumentKind, DmsDocumentSource, SearchQuery } from '#lib/api/client';
import { formatDate } from '#lib/format';
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
	title: 'dms.fact.title',
	// WP-D8
	counterparty: 'dms.fact.counterparty',
	contract_number: 'dms.fact.contract_number',
	period_start: 'dms.fact.period_start',
	period_end: 'dms.fact.period_end',
	term: 'dms.fact.term',
	notice_period: 'dms.fact.notice_period',
	auto_renewal: 'dms.fact.auto_renewal',
	recurring_amount: 'dms.fact.recurring_amount',
	payment_interval: 'dms.fact.payment_interval',
	policy_number: 'dms.fact.policy_number',
	premium: 'dms.fact.premium',
	notice_type: 'dms.fact.notice_type',
	tax_number: 'dms.fact.tax_number',
	tax_id: 'dms.fact.tax_id',
	objection_deadline: 'dms.fact.objection_deadline',
	settlement_amount: 'dms.fact.settlement_amount',
	balance_opening: 'dms.fact.balance_opening',
	balance_closing: 'dms.fact.balance_closing',
	amount_tax_7: 'dms.fact.amount_tax_7',
	amount_tax_19: 'dms.fact.amount_tax_19',
	payment_method: 'dms.fact.payment_method',
	insurer: 'dms.fact.insurer',
	authority: 'dms.fact.authority'
} as const;
export const AMOUNT_FACTS = new Set(['amount', 'amount_gross', 'amount_net', 'amount_tax', 'recurring_amount', 'premium', 'settlement_amount', 'balance_opening', 'balance_closing', 'amount_tax_7', 'amount_tax_19']);
export const DATE_FACTS = new Set(['date', 'due_date', 'deadline', 'period_start', 'period_end', 'objection_deadline']);
const DURATION_FACTS = new Set(['term', 'notice_period']);

/** Value texts of the enumerated facts (literal keys). */
const INTERVAL_LABEL: Record<string, string> = {
	monthly: 'dms.interval.monthly',
	quarterly: 'dms.interval.quarterly',
	semiannual: 'dms.interval.semiannual',
	yearly: 'dms.interval.yearly'
};
const NOTICE_TYPE_LABEL: Record<string, string> = {
	tax_assessment: 'dms.noticeType.tax_assessment',
	tax_prepayment: 'dms.noticeType.tax_prepayment',
	fee_notice: 'dms.noticeType.fee_notice',
	fine: 'dms.noticeType.fine',
	hearing: 'dms.noticeType.hearing',
	summons: 'dms.noticeType.summons',
	reminder: 'dms.noticeType.reminder',
	request: 'dms.noticeType.request',
	notice: 'dms.noticeType.notice'
};
const PAYMENT_METHOD_LABEL: Record<string, string> = {
	cash: 'dms.paymentMethod.cash',
	debit_card: 'dms.paymentMethod.debit_card',
	credit_card: 'dms.paymentMethod.credit_card',
	paypal: 'dms.paymentMethod.paypal',
	card: 'dms.paymentMethod.card'
};
const DURATION_UNIT = { Y: 'year', M: 'month', W: 'week', D: 'day' } as const;

/** ISO 8601 duration of the extractor (`P3M`, `P4W`, `P30D`, `P1Y`) as a localised text; anything else is returned unchanged. */
function formatDuration(value: string, locale: Locale): string {
	const m = /^P(\d{1,4})([YMWD])$/.exec(value);
	if (!m) return value;
	try {
		return new Intl.NumberFormat(locale, { style: 'unit', unit: DURATION_UNIT[m[2] as keyof typeof DURATION_UNIT], unitDisplay: 'long' }).format(Number(m[1]));
	} catch {
		return value;
	}
}

/** Display text of a fact value: amounts with currency (negative = refund or debit balance), dates, durations, enumerations, grouped IBAN. */
export function factValue(type: string, value: string, currency: string | null | undefined, locale: Locale, t: (key: string) => string): string {
	if (AMOUNT_FACTS.has(type)) return formatMoney(value, currency, locale) || value;
	if (DATE_FACTS.has(type)) return formatDate(value, locale) || value;
	if (DURATION_FACTS.has(type)) return value === 'indefinite' ? t('dms.term.indefinite') : formatDuration(value, locale);
	if (type === 'payment_interval') return value in INTERVAL_LABEL ? t(INTERVAL_LABEL[value]) : value;
	if (type === 'notice_type') return value in NOTICE_TYPE_LABEL ? t(NOTICE_TYPE_LABEL[value]) : value;
	if (type === 'payment_method') return value in PAYMENT_METHOD_LABEL ? t(PAYMENT_METHOD_LABEL[value]) : value;
	if (type === 'auto_renewal') return value === 'true' ? t('dms.bool.yes') : value === 'false' ? t('dms.bool.no') : value;
	if (type === 'iban') return value.replace(/\s+/g, '').replace(/(.{4})/g, '$1 ').trim();
	return value;
}

/** Origin of a document (contract `DmsDocumentSource`) with text keys. */
export const SOURCE_LABEL = {
	upload: 'dms.source.upload',
	mail: 'dms.source.mail',
	folder: 'dms.source.folder',
	share: 'dms.source.share',
	import: 'dms.source.import',
	api: 'dms.source.api',
	unknown: 'dms.source.unknown'
} as const satisfies Record<DmsDocumentSource, string>;
export const SOURCES = Object.keys(SOURCE_LABEL) as DmsDocumentSource[];

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
	/** Only documents with open suggestions (server filter `has_open_suggestions`). */
	open: boolean;
	source: DmsDocumentSource | '';
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
		open: sp.get('open') === '1',
		source: (SOURCES as string[]).includes(sp.get('source') ?? '') ? (sp.get('source') as DmsDocumentSource) : ''
	};
}

/**
 * Since WP-D9 the search route takes the same filters and sorting as the list. Only the trash stays on the list route
 * (`GET …/documents?trashed=true`); everything else runs on the search route (snippets, facets, several tags, document date).
 */
export function usesListRoute(f: OverviewFilters): boolean {
	return f.trash;
}

export function extendedActive(f: OverviewFilters): boolean {
	return Boolean(f.kind || f.min || f.max || f.cur || f.due || f.source) || f.sort !== 'received' || f.order !== 'desc';
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
		source: f.source || undefined,
		has_open_suggestions: f.open ? true : undefined,
		sort: apiSort[f.sort],
		order: f.order
	};
}

/** Sums per currency of the whole filtered set: the list query without cursor, one row, with `totals`. The search term only applies in the trash (title search). */
export function toTotalsQuery(f: OverviewFilters, today: string): DocumentListQuery {
	return { ...toListQuery({ ...f, q: f.trash ? f.q : '' }, today, null, 1), totals: true };
}

/** Parameters of `GET …/search`; the date range applies to the document date (`doc_date`). The default order (newest received first) keeps the server default (relevance). */
export function toSearchQuery(f: OverviewFilters, cursor: string | null, limit = 25, today: string = localToday()): SearchQuery {
	const apiSort = { received: 'created_at', date: 'extracted_date', amount: 'amount', due: 'due_date' } as const;
	const defaultSort = f.sort === 'received' && f.order === 'desc';
	return {
		q: f.q,
		cursor,
		limit,
		facets: true,
		document_type_id: f.type || undefined,
		correspondent_id: f.corr || undefined,
		tag_id: f.tags.join(',') || undefined,
		date_from: f.from || undefined,
		date_to: f.to || undefined,
		kind: f.kind || undefined,
		currency: f.cur || undefined,
		amount_min: f.min || undefined,
		amount_max: f.max || undefined,
		...dueRange(f.due, today),
		source: f.source || undefined,
		has_open_suggestions: f.open ? true : undefined,
		sort: defaultSort ? undefined : apiSort[f.sort],
		order: defaultSort ? undefined : f.order
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
