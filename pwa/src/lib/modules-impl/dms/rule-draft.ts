import type { DmsRule, DmsRuleInput } from '#lib/api/client';
import type { Masters } from './masters';

export const CONDITION_TYPES = ['text_contains', 'text_regex', 'filename_contains', 'filename_regex', 'sender_contains', 'source_is'] as const;
export type ConditionType = (typeof CONDITION_TYPES)[number];
export const SOURCES = ['upload', 'folder', 'mail', 'share_ext', 'api'] as const;

/** Literal keys (the unused-text test looks for quoted keys). */
export const CONDITION_TEXT = {
	text_contains: 'dms.rule.cond.text_contains',
	text_regex: 'dms.rule.cond.text_regex',
	filename_contains: 'dms.rule.cond.filename_contains',
	filename_regex: 'dms.rule.cond.filename_regex',
	sender_contains: 'dms.rule.cond.sender_contains',
	source_is: 'dms.rule.cond.source_is'
} as const;

export const SOURCE_TEXT = {
	upload: 'dms.rule.source.upload',
	folder: 'dms.rule.source.folder',
	mail: 'dms.rule.source.mail',
	share_ext: 'dms.rule.source.share_ext',
	api: 'dms.rule.source.api'
} as const;

export const isRegex = (type: ConditionType) => type === 'text_regex' || type === 'filename_regex';

export interface ConditionDraft {
	type: ConditionType;
	/** value for *_contains and source_is, pattern for *_regex */
	text: string;
	caseSensitive: boolean;
}

export interface RuleDraft {
	name: string;
	priority: number;
	enabled: boolean;
	mode: 'suggest' | 'auto';
	/** percent 0..100 (the contract has 0..1) */
	confidencePercent: number;
	match: 'all' | 'any';
	conditions: ConditionDraft[];
	correspondentId: string;
	documentTypeId: string;
	tagIds: string[];
	storagePathId: string;
	dateMode: 'none' | 'extracted' | 'fixed';
	fixedDate: string;
	titleTemplate: string;
}

export function emptyDraft(): RuleDraft {
	return {
		name: '',
		priority: 0,
		enabled: true,
		mode: 'suggest',
		confidencePercent: 80,
		match: 'all',
		conditions: [{ type: 'text_contains', text: '', caseSensitive: false }],
		correspondentId: '',
		documentTypeId: '',
		tagIds: [],
		storagePathId: '',
		dateMode: 'none',
		fixedDate: '',
		titleTemplate: ''
	};
}

/** The id as the master list spells it (select options carry the list's spelling; the rule may carry another letter case). */
function canon(list: readonly { id: string }[], id: string | undefined): string {
	return id ? (list.find((x) => x.id.toLowerCase() === id.toLowerCase())?.id ?? id) : '';
}

export function draftFromRule(rule: DmsRule, masters: Pick<Masters, 'types' | 'tags' | 'paths' | 'contacts'>): RuleDraft {
	const a = rule.actions;
	return {
		name: rule.name,
		priority: rule.priority,
		enabled: rule.enabled,
		mode: rule.mode,
		confidencePercent: Math.round(rule.confidence * 100),
		match: rule.conditions.match ?? 'all',
		conditions: rule.conditions.conditions.map((c) => ({
			type: c.type,
			text: (isRegex(c.type) ? c.pattern : c.value) ?? '',
			caseSensitive: c.case_sensitive ?? false
		})),
		correspondentId: canon(masters.contacts, a.correspondent_id),
		documentTypeId: canon(masters.types, a.document_type_id),
		tagIds: (a.tag_ids ?? []).map((t) => canon(masters.tags, t)),
		storagePathId: canon(masters.paths, a.storage_path_id),
		dateMode: a.doc_date === undefined ? 'none' : a.doc_date === 'extracted' ? 'extracted' : 'fixed',
		fixedDate: a.doc_date && a.doc_date !== 'extracted' ? a.doc_date : '',
		titleTemplate: a.title_template ?? ''
	};
}

/** The request body of the contract (`DmsRuleInput`); only keys that apply to a condition type are sent (strict schema). */
export function draftToInput(d: RuleDraft): DmsRuleInput {
	const actions: NonNullable<DmsRuleInput['actions']> = {};
	if (d.correspondentId) actions.correspondent_id = d.correspondentId;
	if (d.documentTypeId) actions.document_type_id = d.documentTypeId;
	if (d.tagIds.length > 0) actions.tag_ids = d.tagIds;
	if (d.storagePathId) actions.storage_path_id = d.storagePathId;
	if (d.dateMode === 'extracted') actions.doc_date = 'extracted';
	if (d.dateMode === 'fixed' && d.fixedDate) actions.doc_date = d.fixedDate;
	if (d.titleTemplate.trim()) actions.title_template = d.titleTemplate.trim();
	return {
		name: d.name.trim(),
		priority: Math.min(1000, Math.max(-1000, Math.round(Number(d.priority) || 0))),
		enabled: d.enabled,
		mode: d.mode,
		confidence: Math.min(100, Math.max(0, Math.round(Number(d.confidencePercent) || 0))) / 100,
		conditions: {
			version: 1,
			match: d.match,
			conditions: d.conditions.map((c) =>
				isRegex(c.type)
					? { type: c.type, pattern: c.text, case_sensitive: c.caseSensitive }
					: c.type === 'source_is'
						? { type: c.type, value: c.text, case_sensitive: false }
						: { type: c.type, value: c.text, case_sensitive: c.caseSensitive }
			)
		},
		actions
	};
}

export type DraftProblem = 'nameRequired' | 'conditionEmpty' | 'noAction' | 'dateRequired';

/** Client side checks before a request is sent (the backend validates again and wins). */
export function validateDraft(d: RuleDraft): DraftProblem[] {
	const problems: DraftProblem[] = [];
	if (d.name.trim() === '') problems.push('nameRequired');
	if (d.conditions.length === 0 || d.conditions.some((c) => c.text.trim() === '')) problems.push('conditionEmpty');
	if (d.dateMode === 'fixed' && !d.fixedDate) problems.push('dateRequired');
	else if (Object.keys(draftToInput(d).actions ?? {}).length === 0) problems.push('noAction');
	return problems;
}
