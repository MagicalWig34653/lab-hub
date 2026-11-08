<script lang="ts">
	import { ApiError, dmsAdminApi, type DmsMaster, type MasterResource } from '#lib/api/client';
	import ConfirmDialog from '#lib/components/app/ConfirmDialog.svelte';
	import ErrorBanner from '#lib/components/app/ErrorBanner.svelte';
	import { Button } from '#lib/components/ui/button';
	import { Input } from '#lib/components/ui/input';
	import { errorMessage, tx } from '#lib/i18n/index.svelte';
	import { workspace } from '#lib/workspace.svelte';
	import { P } from './permissions';

	let { tenant }: { tenant: string } = $props();
	// svelte-ignore state_referenced_locally
	const tenantId = tenant;

	type FieldKind = 'text' | 'int' | 'bool' | 'color' | 'group' | 'datatype' | 'options';
	interface FieldDef {
		key: string;
		label: string;
		kind: FieldKind;
		required?: boolean;
		/** cannot be changed after creating (backend: 422 on PATCH) */
		createOnly?: boolean;
		hint?: string;
	}
	interface Section {
		resource: MasterResource;
		label: string;
		permission: string;
		fields: FieldDef[];
	}

	const DATA_TYPES = ['string', 'int', 'decimal', 'date', 'bool', 'select', 'contact'] as const;
	const sections: Section[] = [
		{
			resource: 'types',
			label: 'dms.masters.types',
			permission: P.masterManage,
			fields: [
				{ key: 'name', label: 'dms.masters.f.name', kind: 'text', required: true },
				{ key: 'code', label: 'dms.masters.f.code', kind: 'text', createOnly: true },
				{ key: 'description', label: 'dms.masters.f.description', kind: 'text' },
				{ key: 'default_retention_years', label: 'dms.masters.f.retentionYears', kind: 'int', hint: 'dms.masters.f.retentionHint' }
			]
		},
		{
			resource: 'tag-groups',
			label: 'dms.masters.tagGroups',
			permission: P.tagManage,
			fields: [
				{ key: 'name', label: 'dms.masters.f.name', kind: 'text', required: true },
				{ key: 'exclusive', label: 'dms.masters.f.exclusive', kind: 'bool' }
			]
		},
		{
			resource: 'tags',
			label: 'dms.masters.tags',
			permission: P.tagManage,
			fields: [
				{ key: 'name', label: 'dms.masters.f.name', kind: 'text', required: true },
				{ key: 'group_id', label: 'dms.masters.f.group', kind: 'group' },
				{ key: 'color', label: 'dms.masters.f.color', kind: 'color' }
			]
		},
		{
			resource: 'storage-paths',
			label: 'dms.masters.paths',
			permission: P.masterManage,
			fields: [
				{ key: 'name', label: 'dms.masters.f.name', kind: 'text', required: true },
				{ key: 'template', label: 'dms.masters.f.template', kind: 'text', required: true, hint: 'dms.masters.f.templateHint' }
			]
		},
		{
			resource: 'custom-fields',
			label: 'dms.masters.fields',
			permission: P.masterManage,
			fields: [
				{ key: 'name', label: 'dms.masters.f.name', kind: 'text', required: true },
				{ key: 'code', label: 'dms.masters.f.code', kind: 'text', required: true, createOnly: true },
				{ key: 'data_type', label: 'dms.masters.f.dataType', kind: 'datatype', required: true, createOnly: true },
				{ key: 'options', label: 'dms.masters.f.options', kind: 'options', hint: 'dms.masters.f.optionsHint' }
			]
		}
	];

	let active = $state<MasterResource>('types');
	const section = $derived(sections.find((s) => s.resource === active) as Section);
	const canManage = $derived(workspace.can(section.permission));

	let items = $state<DmsMaster[]>([]);
	let groups = $state<DmsMaster[]>([]);
	let loading = $state(true);
	let error = $state<string | null>(null);
	let saved = $state(false);
	/** `undefined`: no form; `null`: creating; a row: editing it. */
	let editing = $state<DmsMaster | null | undefined>(undefined);
	let values = $state<Record<string, string | boolean>>({});
	let formError = $state<string | null>(null);
	let formFieldErrors = $state<{ field: string; code: string }[]>([]);
	let saving = $state(false);
	let deleting = $state<DmsMaster | null>(null);
	let deleteBusy = $state(false);
	let deleteError = $state<string | null>(null);
	let seq = 0;

	const text = (row: DmsMaster, key: string): string => {
		const v = (row as Record<string, unknown>)[key];
		return v === undefined || v === null ? '' : Array.isArray(v) ? v.join(', ') : String(v);
	};

	async function load() {
		const mine = ++seq;
		loading = true;
		error = null;
		try {
			const result = await dmsAdminApi.masters(tenantId, active);
			if (active === 'tags') groups = (await dmsAdminApi.masters(tenantId, 'tag-groups').catch(() => ({ items: [] }))).items;
			if (mine !== seq) return;
			items = result.items;
		} catch (e) {
			if (mine === seq) error = errorMessage(e);
		} finally {
			if (mine === seq) loading = false;
		}
	}

	function select(resource: MasterResource) {
		active = resource;
		editing = undefined;
		saved = false;
		items = [];
		void load();
	}

	void load();

	function startEdit(row: DmsMaster | null) {
		editing = row;
		saved = false;
		formError = null;
		formFieldErrors = [];
		const next: Record<string, string | boolean> = {};
		for (const f of section.fields) {
			const raw = row ? (row as Record<string, unknown>)[f.key] : undefined;
			next[f.key] = f.kind === 'bool' ? raw === true : f.kind === 'options' ? (Array.isArray(raw) ? raw.join(', ') : '') : raw === undefined || raw === null ? '' : String(raw);
		}
		if (!row && active === 'custom-fields') next.data_type = 'string';
		values = next;
	}

	/** Body of the request: on edit only changed fields that may change; empty optional fields are left out when creating. */
	function buildBody(): Record<string, unknown> {
		const body: Record<string, unknown> = {};
		for (const f of section.fields) {
			if (editing && f.createOnly) continue;
			const v = values[f.key];
			if (f.kind === 'bool') body[f.key] = v === true;
			else if (f.kind === 'int') {
				if (v !== '') body[f.key] = Number(v);
			} else if (f.kind === 'options') {
				const list = String(v).split(',').map((x) => x.trim()).filter(Boolean);
				if (values.data_type === 'select' || list.length > 0) body[f.key] = list;
			} else if (f.kind === 'group' || f.kind === 'color') {
				if (v !== '') body[f.key] = v;
				else if (editing) body[f.key] = null;
			} else if (v !== '' || f.required) body[f.key] = String(v).trim();
		}
		return body;
	}

	async function save(event: SubmitEvent) {
		event.preventDefault();
		formError = null;
		formFieldErrors = [];
		const missing = section.fields.find((f) => f.required && !(editing && f.createOnly) && String(values[f.key] ?? '').trim() === '');
		if (missing) {
			formError = tx('dms.masters.required', { field: tx(missing.label) });
			return;
		}
		saving = true;
		try {
			const body = buildBody();
			if (editing) await dmsAdminApi.updateMaster(tenantId, active, editing.id, body);
			else await dmsAdminApi.createMaster(tenantId, active, body);
			editing = undefined;
			saved = true;
			await load();
		} catch (e) {
			formError = errorMessage(e);
			formFieldErrors = e instanceof ApiError ? e.fieldErrors : [];
		} finally {
			saving = false;
		}
	}

	async function confirmDelete() {
		if (!deleting) return;
		deleteBusy = true;
		deleteError = null;
		try {
			await dmsAdminApi.deleteMaster(tenantId, active, deleting.id);
			deleting = null;
			await load();
		} catch (e) {
			deleteError = e instanceof ApiError && e.status === 409 ? tx('dms.masters.inUse') : errorMessage(e);
		} finally {
			deleteBusy = false;
		}
	}

	const groupName = (id: string) => groups.find((g) => g.id === id)?.name ?? '';
	const selectClass = 'border-input bg-background h-8 w-full rounded-lg border px-2 text-sm';
	const cell = (row: DmsMaster, f: FieldDef): string =>
		f.kind === 'bool' ? tx((row as Record<string, unknown>)[f.key] === true ? 'dms.masters.yes' : 'dms.masters.no') : f.kind === 'group' ? groupName(text(row, f.key)) : text(row, f.key);
</script>

<h1 class="mb-1 text-2xl font-semibold" data-testid="masters-title">{tx('dms.masters.title')}</h1>
<p class="text-muted-foreground mb-4 text-sm">{tx('dms.masters.intro')}</p>

<div role="group" aria-label={tx('dms.masters.sections')} class="mb-4 flex flex-wrap gap-2">
	{#each sections as s (s.resource)}
		<Button type="button" size="sm" variant={active === s.resource ? 'default' : 'outline'} aria-pressed={active === s.resource} class="transition-none" onclick={() => select(s.resource)} data-testid={`masters-tab-${s.resource}`}>
			{tx(s.label)}
		</Button>
	{/each}
</div>

<ErrorBanner message={error} />
{#if saved}<p role="status" class="mb-3 text-sm" data-testid="masters-saved">{tx('dms.masters.saved')}</p>{/if}
{#if active === 'tags'}<p class="text-muted-foreground mb-3 text-xs" data-testid="masters-merge-note">{tx('dms.masters.mergeNote')}</p>{/if}
{#if active === 'types'}<p class="text-muted-foreground mb-3 text-xs">{tx('dms.masters.retentionNote')}</p>{/if}

{#if editing !== undefined}
	<form onsubmit={save} class="mb-5 space-y-3 rounded-lg border p-3" novalidate data-testid="masters-form">
		<h2 class="text-base font-medium">{tx(editing ? 'dms.masters.edit' : 'dms.masters.new')}</h2>
		{#each section.fields as f (f.key)}
			{#if !(editing && f.createOnly)}
				<label class="block text-sm">
					{#if f.kind === 'bool'}
						<span class="flex items-center gap-2">
							<input type="checkbox" bind:checked={values[f.key] as boolean} data-testid={`masters-f-${f.key}`} />
							{tx(f.label)}
						</span>
					{:else}
						<span class="mb-1 block">{tx(f.label)}</span>
						{#if f.kind === 'group'}
							<select class={selectClass} bind:value={values[f.key] as string} data-testid={`masters-f-${f.key}`}>
								<option value="">{tx('dms.edit.none')}</option>
								{#each groups as g (g.id)}<option value={g.id}>{g.name}</option>{/each}
							</select>
						{:else if f.kind === 'datatype'}
							<select class={selectClass} bind:value={values[f.key] as string} data-testid={`masters-f-${f.key}`}>
								{#each DATA_TYPES as dt (dt)}<option value={dt}>{dt}</option>{/each}
							</select>
						{:else if f.kind === 'color'}
							<Input bind:value={values[f.key] as string} placeholder="#3366cc" maxlength={7} data-testid={`masters-f-${f.key}`} />
						{:else if f.kind === 'int'}
							<Input type="number" min="0" max="100" bind:value={values[f.key] as string} data-testid={`masters-f-${f.key}`} />
						{:else}
							<Input bind:value={values[f.key] as string} data-testid={`masters-f-${f.key}`} />
						{/if}
					{/if}
					{#if f.hint}<span class="text-muted-foreground mt-1 block text-xs">{tx(f.hint)}</span>{/if}
				</label>
			{/if}
		{/each}
		{#if formError}<p role="alert" class="text-destructive text-sm" data-testid="masters-form-error">{formError}</p>{/if}
		{#if formFieldErrors.length > 0}
			<ul class="text-destructive list-disc pl-5 text-sm">
				{#each formFieldErrors as fe (fe.field + fe.code)}<li>{tx('dms.rule.fieldError', { field: fe.field, code: fe.code })}</li>{/each}
			</ul>
		{/if}
		<div class="flex gap-2">
			<Button type="submit" disabled={saving} data-testid="masters-save">{tx('dms.edit.save')}</Button>
			<Button type="button" variant="outline" onclick={() => (editing = undefined)} data-testid="masters-cancel">{tx('common.cancel')}</Button>
		</div>
	</form>
{:else if canManage}
	<Button type="button" class="mb-4" onclick={() => startEdit(null)} data-testid="masters-new">{tx('dms.masters.new')}</Button>
{:else}
	<p class="text-muted-foreground mb-3 text-xs">{tx('dms.masters.readOnly')}</p>
{/if}

{#if loading}
	<p class="text-muted-foreground text-sm">{tx('common.loading')}</p>
{:else if items.length === 0 && !error}
	<p class="text-muted-foreground" data-testid="masters-empty">{tx('dms.masters.empty')}</p>
{:else}
	<div class="overflow-x-auto">
		<table class="w-full text-left text-sm" data-testid="masters-table">
			<caption class="sr-only">{tx(section.label)}</caption>
			<thead>
				<tr class="text-muted-foreground border-b">
					{#each section.fields as f (f.key)}<th scope="col" class="py-2 pr-3">{tx(f.label)}</th>{/each}
					<th scope="col" class="py-2"><span class="sr-only">{tx('dms.actions.title')}</span></th>
				</tr>
			</thead>
			<tbody>
				{#each items as row (row.id)}
					<tr class="border-b" data-testid="masters-row">
						{#each section.fields as f (f.key)}<td class="py-2 pr-3 break-words">{cell(row, f)}</td>{/each}
						<td class="py-2">
							{#if canManage}
								<div class="flex gap-2">
									<Button type="button" size="sm" variant="outline" onclick={() => startEdit(row)} data-testid="masters-edit">{tx('dms.masters.rename')}</Button>
									<Button type="button" size="sm" variant="outline" onclick={() => ((deleting = row), (deleteError = null))} data-testid="masters-delete">{tx('dms.rule.delete')}</Button>
								</div>
							{/if}
						</td>
					</tr>
				{/each}
			</tbody>
		</table>
	</div>
{/if}

<ConfirmDialog
	open={deleting !== null}
	title={tx('dms.masters.deleteTitle')}
	confirmLabel={tx('dms.rule.delete')}
	destructive
	busy={deleteBusy}
	error={deleteError}
	testid="masters-delete-dialog"
	onconfirm={confirmDelete}
	oncancel={() => (deleting = null)}
>
	<p>{tx('dms.masters.deleteText', { name: deleting ? text(deleting, 'name') : '' })}</p>
</ConfirmDialog>
