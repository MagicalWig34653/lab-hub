import type { DmsSuggestion } from '#lib/api/client';
import { formatDate } from '#lib/format';
import type { Locale } from '#lib/i18n/index.svelte';
import type { Masters } from './masters';

/** Ids from different routes may differ in letter case (the backend lowercases suggestion values); compare case-insensitively. */
export const sameId = (a: string | null | undefined, b: string | null | undefined) => !!a && !!b && a.toLowerCase() === b.toLowerCase();
const nameOf = (list: readonly { id: string; name: string }[], id: string | undefined) => list.find((x) => sameId(x.id, id))?.name ?? '';

/** Text keys per suggestion kind (literal keys so the unused-text test can see them). */
export const KIND_TEXT = {
	correspondent: 'dms.suggestion.kind.correspondent',
	type: 'dms.suggestion.kind.type',
	tag: 'dms.suggestion.kind.tag',
	date: 'dms.suggestion.kind.date',
	title: 'dms.suggestion.kind.title',
	path: 'dms.suggestion.kind.path'
} as const;

/** The proposed value of a suggestion as readable text (names from the master data, never raw ids when a name is known). */
export function suggestionValueText(s: Pick<DmsSuggestion, 'kind' | 'value'>, masters: Masters, locale: Locale): string {
	const v = s.value;
	switch (s.kind) {
		case 'correspondent':
			return nameOf(masters.contacts, v.contact_id) || (v.contact_name ?? '') || shortId(v.contact_id);
		case 'type':
			return nameOf(masters.types, v.document_type_id) || shortId(v.document_type_id);
		case 'tag':
			return nameOf(masters.tags, v.tag_id) || shortId(v.tag_id);
		case 'path':
			return nameOf(masters.paths, v.storage_path_id) || shortId(v.storage_path_id);
		case 'date':
			return formatDate(v.doc_date, locale) || (v.doc_date ?? '');
		case 'title':
			return v.title ?? '';
	}
}

function shortId(id: string | undefined): string {
	return id ? id.slice(0, 8) : '';
}

/**
 * Pre-check for the stale hint: the target of a master-data suggestion no longer exists. The backend decides on accept
 * (409 suggestion_stale); this only warns earlier. Contacts are not checked (the list is capped and role dependent).
 */
export function targetMissing(s: Pick<DmsSuggestion, 'kind' | 'value'>, masters: Masters): boolean {
	const v = s.value;
	const lacks = (list: { id: string }[], id: string | undefined) => list.length > 0 && !!id && !list.some((x) => sameId(x.id, id));
	switch (s.kind) {
		case 'type':
			return lacks(masters.types, v.document_type_id);
		case 'tag':
			return lacks(masters.tags, v.tag_id);
		case 'path':
			return lacks(masters.paths, v.storage_path_id);
		default:
			return false;
	}
}
