<script lang="ts">
	import { page } from '$app/state';
	import { tx } from '#lib/i18n/index.svelte';
	import { workspace } from '#lib/workspace.svelte';
	import { P } from './permissions';

	/** Sub navigation of the DMS module. Entries need a permission to be shown; the backend still authorizes every call. */
	const entries = [
		{ path: '/dms', label: 'dms.nav.documents', permission: 'dms.document.read', exact: true },
		{ path: '/dms/review', label: 'dms.nav.review', permission: P.suggestionRead, exact: false },
		{ path: '/dms/rules', label: 'dms.nav.rules', permission: P.ruleRead, exact: false },
		{ path: '/dms/duplicates', label: 'dms.nav.duplicates', permission: 'dms.document.read', exact: false },
		{ path: '/dms/masters', label: 'dms.nav.masters', permission: 'dms.document.read', exact: false },
		{ path: '/dms/trash', label: 'dms.nav.trash', permission: P.documentTrash, exact: false },
		{ path: '/dms/integrity', label: 'dms.nav.integrity', permission: P.integrityRun, exact: false },
		{ path: '/dms/exports', label: 'dms.nav.exports', permission: P.exportRun, exact: false }
	] as const;

	const visible = $derived(entries.filter((e) => workspace.can(e.permission)));
	const isCurrent = (e: (typeof entries)[number]) => (e.exact ? page.url.pathname === e.path : page.url.pathname === e.path || page.url.pathname.startsWith(`${e.path}/`));
</script>

{#if workspace.moduleEffective('dms') && visible.length > 1}
	<nav aria-label={tx('dms.nav.label')} class="mb-4" data-testid="dms-nav">
		<ul class="flex flex-wrap gap-1">
			{#each visible as e (e.path)}
				<li>
					<a
						href={e.path}
						aria-current={isCurrent(e) ? 'page' : undefined}
						class="hover:bg-muted aria-[current=page]:bg-muted aria-[current=page]:font-medium inline-block rounded-md px-3 py-1.5 text-sm"
						data-testid={`dms-nav-${e.path.split('/')[2] ?? 'documents'}`}
					>
						{tx(e.label)}
					</a>
				</li>
			{/each}
		</ul>
	</nav>
{/if}
