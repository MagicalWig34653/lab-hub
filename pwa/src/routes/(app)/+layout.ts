import { redirect } from '@sveltejs/kit';
import { session } from '#lib/session.svelte';

/** Auth guard: every route in (app) needs a session; otherwise go to /login and come back afterwards. */
export async function load({ url }) {
	const current = session.current ?? (await session.refresh());
	if (!current) {
		redirect(307, `/login?next=${encodeURIComponent(url.pathname + url.search)}`);
	}
}
