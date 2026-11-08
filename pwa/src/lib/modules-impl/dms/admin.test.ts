import { describe, expect, it } from 'vitest';
import type { DmsRule } from '#lib/api/client';
import type { Masters } from './masters';
import { draftFromRule, draftToInput, emptyDraft, validateDraft } from './rule-draft';
import { sameId, suggestionValueText, targetMissing } from './suggestion';

const TYPE = '74EB9A68-0000-4000-8000-000000000001';
const masters: Masters = {
	types: [{ id: TYPE, name: 'Rechnung' }],
	tags: [{ id: 'aaaaaaaa-0000-4000-8000-000000000002', name: 'Steuer' }],
	fields: [],
	paths: [],
	contacts: [{ id: 'cccccccc-0000-4000-8000-000000000003', name: 'Muster GmbH' }]
};

describe('WP-F5 suggestion helpers', () => {
	it('ids differing only in letter case are the same id (the backend lowercases suggestion values)', () => {
		expect(sameId(TYPE, TYPE.toLowerCase())).toBe(true);
		expect(sameId(TYPE, undefined)).toBe(false);
		expect(sameId('', '')).toBe(false);
	});

	it('shows names from the master data, not ids', () => {
		expect(suggestionValueText({ kind: 'type', value: { document_type_id: TYPE.toLowerCase() } }, masters, 'de')).toBe('Rechnung');
		expect(suggestionValueText({ kind: 'correspondent', value: { contact_id: 'cccccccc-0000-4000-8000-000000000003' } }, masters, 'de')).toBe('Muster GmbH');
		expect(suggestionValueText({ kind: 'title', value: { title: 'Neu' } }, masters, 'de')).toBe('Neu');
		expect(suggestionValueText({ kind: 'date', value: { doc_date: '2026-03-04' } }, masters, 'en')).toContain('2026');
		// unknown target: the first characters of the id, never an empty cell
		expect(suggestionValueText({ kind: 'tag', value: { tag_id: 'deadbeef-0000-4000-8000-000000000009' } }, masters, 'de')).toBe('deadbeef');
	});

	it('flags a missing master data target as stale, but not while the list is not loaded', () => {
		expect(targetMissing({ kind: 'tag', value: { tag_id: 'deadbeef-0000-4000-8000-000000000009' } }, masters)).toBe(true);
		expect(targetMissing({ kind: 'tag', value: { tag_id: 'AAAAAAAA-0000-4000-8000-000000000002' } }, masters)).toBe(false);
		expect(targetMissing({ kind: 'tag', value: { tag_id: 'deadbeef-0000-4000-8000-000000000009' } }, { ...masters, tags: [] })).toBe(false);
		expect(targetMissing({ kind: 'title', value: { title: 'x' } }, masters)).toBe(false);
	});
});

describe('WP-F5 rule draft', () => {
	it('builds the strict request body of the contract', () => {
		const d = emptyDraft();
		d.name = '  Rechnungen ';
		d.conditions = [
			{ type: 'text_contains', text: 'Rechnung', caseSensitive: false },
			{ type: 'filename_regex', text: '^scan', caseSensitive: true },
			{ type: 'source_is', text: 'mail', caseSensitive: false }
		];
		d.documentTypeId = TYPE;
		d.dateMode = 'extracted';
		d.confidencePercent = 90;
		const body = draftToInput(d);
		expect(body.name).toBe('Rechnungen');
		expect(body.confidence).toBe(0.9);
		expect(body.mode).toBe('suggest');
		expect(body.conditions?.conditions).toEqual([
			{ type: 'text_contains', value: 'Rechnung', case_sensitive: false },
			{ type: 'filename_regex', pattern: '^scan', case_sensitive: true },
			{ type: 'source_is', value: 'mail', case_sensitive: false }
		]);
		expect(body.actions).toEqual({ document_type_id: TYPE, doc_date: 'extracted' });
	});

	it('clamps priority and confidence into the contract range', () => {
		const d = emptyDraft();
		d.priority = 5000;
		d.confidencePercent = 250;
		const body = draftToInput(d);
		expect(body.priority).toBe(1000);
		expect(body.confidence).toBe(1);
	});

	it('reports what is missing before a request is sent', () => {
		expect(validateDraft(emptyDraft())).toEqual(['nameRequired', 'conditionEmpty', 'noAction']);
		const d = emptyDraft();
		d.name = 'x';
		d.conditions[0].text = 'y';
		d.dateMode = 'fixed';
		expect(validateDraft(d)).toEqual(['dateRequired']);
		d.fixedDate = '2026-01-02';
		expect(validateDraft(d)).toEqual([]);
	});

	it('round-trips a stored rule and takes the spelling of the master list for ids', () => {
		const rule = {
			id: 'r1',
			name: 'Regel',
			priority: 3,
			enabled: false,
			mode: 'auto',
			confidence: 0.85,
			conditions: { version: 1, match: 'any', conditions: [{ type: 'text_regex', pattern: 'a|b', case_sensitive: false }] },
			actions: { document_type_id: TYPE.toLowerCase(), tag_ids: ['aaaaaaaa-0000-4000-8000-000000000002'], doc_date: '2026-05-06' },
			version: 2,
			created_at: '',
			updated_at: '',
			stats: { suggested: 0, open: 0, accepted: 0, rejected: 0, automatic: 0 }
		} as DmsRule;
		const draft = draftFromRule(rule, masters);
		expect(draft.documentTypeId).toBe(TYPE);
		expect(draft.confidencePercent).toBe(85);
		expect(draft.match).toBe('any');
		expect(draft.conditions[0]).toEqual({ type: 'text_regex', text: 'a|b', caseSensitive: false });
		expect(draft.dateMode).toBe('fixed');
		const back = draftToInput(draft);
		expect(back.actions).toEqual({ document_type_id: TYPE, tag_ids: ['aaaaaaaa-0000-4000-8000-000000000002'], doc_date: '2026-05-06' });
		expect(back.enabled).toBe(false);
	});
});
