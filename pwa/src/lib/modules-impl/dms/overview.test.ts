import { describe, expect, it } from 'vitest';
import { activePreset, addDays, dueRange, factValue, formatMoney, normalizeAmount, parseFilters, presetRange, toListQuery, toSearchQuery, toTotalsQuery, usesListRoute } from './overview';

const parse = (query: string) => parseFilters(new URLSearchParams(query));

describe('WP-F4c filters in the URL', () => {
	it('defaults: search route, newest first', () => {
		const f = parse('');
		expect(f.sort).toBe('received');
		expect(f.order).toBe('desc');
		expect(usesListRoute(f)).toBe(false);
	});

	it('drops unknown or invalid values', () => {
		const f = parse('kind=banana&sort=zzz&due=never&min=abc&cur=eu');
		expect(f.kind).toBe('');
		expect(f.sort).toBe('received');
		expect(f.due).toBe('');
		expect(f.min).toBe('');
		expect(f.cur).toBe('');
	});

	it('only the trash needs the list route (D9: search takes all filters and sorting)', () => {
		expect(usesListRoute(parse('trash=1'))).toBe(true);
		for (const query of ['kind=invoice', 'min=10', 'due=overdue', 'sort=amount', 'source=mail', 'open=1', 'type=abc&tags=a,b&from=2026-01-01']) {
			expect(usesListRoute(parse(query)), query).toBe(false);
		}
	});

	it('due date sorts ascending by default, amount and date descending', () => {
		expect(parse('sort=due').order).toBe('asc');
		expect(parse('sort=amount').order).toBe('desc');
		expect(parse('sort=due&order=desc').order).toBe('desc');
	});

	it('builds the list query with the contract names', () => {
		const q = toListQuery(parse('kind=invoice&min=100&max=250,5&from=2026-11-01&to=2026-11-30&sort=amount&order=asc&type=t1&tags=a,b'), '2026-11-08', 'cur', 25);
		expect(q).toMatchObject({
			kind: 'invoice',
			amount_min: '100',
			amount_max: '250.5',
			extracted_from: '2026-11-01',
			extracted_to: '2026-11-30',
			sort: 'amount',
			order: 'asc',
			document_type_id: 't1',
			tag_id: 'a',
			cursor: 'cur'
		});
	});

	it('builds the search query with the document date and all tags', () => {
		const q = toSearchQuery(parse('q=miete&tags=a,b&from=2026-01-01'), null);
		expect(q).toMatchObject({ q: 'miete', tag_id: 'a,b', date_from: '2026-01-01', facets: true });
	});
});

describe('WP-F4d source, open suggestions, totals, search filters', () => {
	it('source is a URL filter; unknown values are dropped', () => {
		expect(parse('source=mail').source).toBe('mail');
		expect(parse('source=fax').source).toBe('');
	});

	it('list query carries source and has_open_suggestions', () => {
		expect(toListQuery(parse('source=share&open=1'), '2026-11-08', null)).toMatchObject({ source: 'share', has_open_suggestions: true });
		expect(toListQuery(parse(''), '2026-11-08', null).has_open_suggestions).toBeUndefined();
	});

	it('search query carries the extraction filters, source, open suggestions and the mapped sort', () => {
		const q = toSearchQuery(parse('q=x&kind=contract&cur=EUR&min=5&max=9&due=overdue&source=mail&open=1&sort=amount&order=asc&from=2026-01-01'), null, 25, '2026-11-08');
		expect(q).toMatchObject({
			q: 'x',
			kind: 'contract',
			currency: 'EUR',
			amount_min: '5',
			amount_max: '9',
			due_to: '2026-11-07',
			source: 'mail',
			has_open_suggestions: true,
			sort: 'amount',
			order: 'asc',
			date_from: '2026-01-01'
		});
	});

	it('the default order keeps the server default (relevance); other orders are sent', () => {
		expect(toSearchQuery(parse('q=x'), null, 25, '2026-11-08').sort).toBeUndefined();
		expect(toSearchQuery(parse('sort=received&order=asc'), null, 25, '2026-11-08')).toMatchObject({ sort: 'created_at', order: 'asc' });
	});

	it('totals query: whole filtered set, no cursor, one row, the recognised date range', () => {
		const q = toTotalsQuery(parse('kind=invoice&from=2026-01-01&to=2026-12-31&source=upload&q=abc'), '2026-11-08');
		expect(q).toMatchObject({ totals: true, limit: 1, kind: 'invoice', source: 'upload', extracted_from: '2026-01-01', extracted_to: '2026-12-31' });
		expect(q.q).toBeUndefined();
		expect(q.cursor ?? undefined).toBeUndefined();
		expect(toTotalsQuery(parse('trash=1&q=abc'), '2026-11-08')).toMatchObject({ trashed: true, q: 'abc' });
	});
});

describe('WP-F4d fact values per kind', () => {
	const t = (key: string) => key;
	it('amounts including negative refunds and balances, in the currency', () => {
		expect(factValue('settlement_amount', '-120.50', 'EUR', 'de', t)).toContain('120,50');
		expect(factValue('settlement_amount', '-120.50', 'EUR', 'de', t)).toMatch(/^-|−/);
		expect(factValue('balance_closing', '1234.00', 'EUR', 'en', t)).toContain('1,234.00');
		for (const type of ['recurring_amount', 'premium', 'balance_opening', 'amount_tax_7', 'amount_tax_19']) expect(factValue(type, '7.00', 'EUR', 'de', t), type).toContain('7,00');
	});

	it('dates and ISO durations', () => {
		expect(factValue('period_end', '2026-12-31', null, 'de', t)).toBe('31.12.2026');
		expect(factValue('objection_deadline', '2026-12-31', null, 'de', t)).toBe('31.12.2026');
		expect(factValue('notice_period', 'P3M', null, 'de', t)).toBe('3 Monate');
		expect(factValue('term', 'P1Y', null, 'en', t)).toBe('1 year');
		expect(factValue('notice_period', 'P4W', null, 'en', t)).toBe('4 weeks');
		expect(factValue('notice_period', 'P30D', null, 'de', t)).toBe('30 Tage');
		expect(factValue('term', 'indefinite', null, 'de', t)).toBe('dms.term.indefinite');
		expect(factValue('term', 'garbage', null, 'de', t)).toBe('garbage');
	});

	it('enumerations map to texts, unknown values stay as they are', () => {
		expect(factValue('payment_interval', 'quarterly', null, 'de', t)).toBe('dms.interval.quarterly');
		expect(factValue('auto_renewal', 'true', null, 'de', t)).toBe('dms.bool.yes');
		expect(factValue('auto_renewal', 'false', null, 'de', t)).toBe('dms.bool.no');
		expect(factValue('notice_type', 'tax_assessment', null, 'de', t)).toBe('dms.noticeType.tax_assessment');
		expect(factValue('payment_method', 'debit_card', null, 'de', t)).toBe('dms.paymentMethod.debit_card');
		expect(factValue('payment_method', 'bitcoin', null, 'de', t)).toBe('bitcoin');
	});

	it('IBAN is grouped by four, other text is unchanged', () => {
		expect(factValue('iban', 'DE89370400440532013000', null, 'de', t)).toBe('DE89 3704 0044 0532 0130 00');
		expect(factValue('counterparty', 'Muster GmbH', null, 'de', t)).toBe('Muster GmbH');
	});
});

describe('amounts', () => {
	it('accepts comma and point with at most two decimals', () => {
		expect(normalizeAmount('119,00')).toBe('119.00');
		expect(normalizeAmount(' 7.5 ')).toBe('7.5');
		expect(normalizeAmount('-3')).toBe('-3');
		expect(normalizeAmount('1,234')).toBeNull();
		expect(normalizeAmount('12.345')).toBeNull();
		expect(normalizeAmount('abc')).toBeNull();
	});

	it('formats the decimal string with the currency without a float round trip', () => {
		expect(formatMoney('119.00', 'EUR', 'de')).toContain('119,00');
		expect(formatMoney('9007199254740993.01', 'EUR', 'en')).toContain('9,007,199,254,740,993.01');
		expect(formatMoney(null, 'EUR', 'de')).toBe('');
		expect(formatMoney('5.00', null, 'de')).toBe('5.00');
	});
});

describe('time ranges', () => {
	it('presets: today, 7 days, month, year', () => {
		expect(presetRange('today', '2026-11-08')).toEqual({ from: '2026-11-08', to: '2026-11-08' });
		expect(presetRange('week', '2026-11-08')).toEqual({ from: '2026-11-02', to: '2026-11-08' });
		expect(presetRange('month', '2026-02-10')).toEqual({ from: '2026-02-01', to: '2026-02-28' });
		expect(presetRange('year', '2026-11-08')).toEqual({ from: '2026-01-01', to: '2026-12-31' });
		expect(activePreset({ from: '2026-11-01', to: '2026-11-30' }, '2026-11-08')).toBe('month');
		expect(activePreset({ from: '2026-11-03', to: '2026-11-30' }, '2026-11-08')).toBeNull();
	});

	it('due filters', () => {
		expect(dueRange('overdue', '2026-11-08')).toEqual({ due_to: '2026-11-07' });
		expect(dueRange('week', '2026-11-08')).toEqual({ due_from: '2026-11-08', due_to: '2026-11-14' });
		expect(dueRange('due', '2026-11-08')).toEqual({ due_to: '2026-11-08' });
		expect(dueRange('', '2026-11-08')).toEqual({});
		expect(addDays('2026-12-30', 3)).toBe('2027-01-02');
	});
});
