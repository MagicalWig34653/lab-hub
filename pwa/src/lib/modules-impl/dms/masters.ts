import { contactApi, dmsApi, type DmsMaster } from '#lib/api/client';

export interface Masters {
	types: { id: string; name: string }[];
	tags: { id: string; name: string }[];
	fields: DmsMaster[];
	/** Contacts serve as correspondents. Empty when the role may not read contacts. */
	contacts: { id: string; name: string }[];
}

/** Loads the selection lists. A list the user may not read (403) is empty instead of failing the page. */
export async function loadMasters(tenant: string): Promise<Masters> {
	const safe = async <T>(promise: Promise<{ items: T[] }>): Promise<T[]> => {
		try {
			return (await promise).items;
		} catch {
			return [];
		}
	};
	const [types, tags, fields, contacts] = await Promise.all([
		safe(dmsApi.types(tenant)),
		safe(dmsApi.tags(tenant)),
		safe(dmsApi.customFields(tenant)),
		safe(contactApi.list(tenant, { limit: 200 }))
	]);
	const named = (list: DmsMaster[]) => list.map((x) => ({ id: x.id, name: x.name ?? '' }));
	return { types: named(types), tags: named(tags), fields, contacts: contacts.map((c) => ({ id: c.id, name: c.display_name })) };
}

export function nameOf(list: readonly { id: string; name: string }[], id: string | null | undefined): string {
	return list.find((x) => x.id === id)?.name ?? '';
}
