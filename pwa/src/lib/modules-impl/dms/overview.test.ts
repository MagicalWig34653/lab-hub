import { describe, expect, it } from 'vitest';
import { activePreset, addDays, dueRange, formatMoney, normalizeAmount, parseFilters, presetRange, toListQuery, toSearchQuery, usesListRoute } from './overview';

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

	it('extraction filters, sorting and trash switch to the list route', () => {
		expect(usesListRoute(parse('kind=invoice'))).toBe(true);
		expect(usesListRoute(parse('min=10'))).toBe(true);
		expect(usesListRoute(parse('due=overdue'))).toBe(true);
		expect(usesListRoute(parse('sort=amount'))).toBe(true);
		expect(usesListRoute(parse('trash=1'))).toBe(true);
		expect(usesListRoute(parse('type=abc&tags=a,b&from=2026-01-01'))).toBe(false);
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
