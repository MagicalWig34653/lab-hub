<script lang="ts">
	import { ApiError, dmsAdminApi, type DmsRule, type DmsRulePreview } from '#lib/api/client';
	import ErrorBanner from '#lib/components/app/ErrorBanner.svelte';
	import * as Alert from '#lib/components/ui/alert';
	import { Button } from '#lib/components/ui/button';
	import { Input } from '#lib/components/ui/input';
	import { errorMessage, i18n, tx } from '#lib/i18n/index.svelte';
	import type { Masters } from './masters';
	import {
		CONDITION_TEXT,
		CONDITION_TYPES,
		SOURCES,
		SOURCE_TEXT,
		draftFromRule,
		draftToInput,
		emptyDraft,
		isRegex,
		validateDraft,
		type DraftProblem,
		type RuleDraft
	} from './rule-draft';
	import { KIND_TEXT, suggestionValueText } from './suggestion';

	let {
		tenant,
		rule,
		masters,
		onsaved,
		oncancel
	}: { tenant: string; rule: DmsRule | null; masters: Masters; onsaved: () => void; oncancel: () => void } = $props();
	// svelte-ignore state_referenced_locally
	const tenantId = tenant;

	// svelte-ignore state_referenced_locally
	let draft = $state<RuleDraft>(rule ? draftFromRule(rule, masters) : emptyDraft());
	let saving = $state(false);
	let error = $state<string | null>(null);
	let fieldErrors = $state<{ field: string; code: string }[]>([]);
	let problems = $state<DraftProblem[]>([]);
	let previewing = $state(false);
	let preview = $state<DmsRulePreview | null>(null);
	/** Snapshot of the draft the preview belongs to: any later change makes the preview outdated. */
	let previewOf = $state<string | null>(null);
	let previewLimit = $state(100);

	const snapshot = $derived(JSON.stringify(draftToInput(draft)));
	const previewCurrent = $derived(preview !== null && previewOf === snapshot);
	/** An auto rule changes metadata by itself: it can only be saved after a dry run of exactly this version. */
	const needsPreview = $derived(draft.mode === 'auto' && !previewCurrent);

	const problemText = {
		nameRequired: 'dms.rule.problem.nameRequired',
		conditionEmpty: 'dms.rule.problem.conditionEmpty',
		noAction: 'dms.rule.problem.noAction',
		dateRequired: 'dms.rule.problem.dateRequired'
	} as const;
	const selectClass = 'border-input bg-background h-8 w-full rounded-lg border px-2 text-sm';

	function addCondition() {
		draft.conditions.push({ type: 'text_contains', text: '', caseSensitive: false });
	}

	function removeCondition(index: number) {
		draft.conditions.splice(index, 1);
	}

	function toggleTag(id: string) {
		draft.tagIds = draft.tagIds.includes(id) ? draft.tagIds.filter((x) => x !== id) : [...draft.tagIds, id];
	}

	function onTypeChange(index: number) {
		// the free text means something else for a regex, a source or a plain text: start empty when the kind changes
		draft.conditions[index].text = draft.conditions[index].type === 'source_is' ? SOURCES[0] : '';
	}

	function failure(e: unknown) {
		error = errorMessage(e);
		fieldErrors = e instanceof ApiError ? e.fieldErrors : [];
	}

	async function runPreview() {
		problems = validateDraft(draft);
		if (problems.length > 0) return;
		previewing = true;
		error = null;
		fieldErrors = [];
		const taken = snapshot;
		try {
			preview = await dmsAdminApi.previewDraft(tenantId, { ...draftToInput(draft), limit: Math.min(500, Math.max(1, Number(previewLimit) || 100)) });
			previewOf = taken;
		} catch (e) {
			preview = null;
			failure(e);
		} finally {
			previewing = false;
		}
	}

	async function save(event: SubmitEvent) {
		event.preventDefault();
		problems = validateDraft(draft);
		error = null;
		fieldErrors = [];
		if (problems.length > 0 || needsPreview) return;
		saving = true;
		try {
			const body = draftToInput(draft);
			if (rule) await dmsAdminApi.updateRule(tenantId, rule.id, body);
			else await dmsAdminApi.createRule(tenantId, body);
			onsaved();
		} catch (e) {
			failure(e);
		} finally {
			saving = false;
		}
	}

	const valueText = (kind: string, value: Record<string, string>) =>
		suggestionValueText({ kind: kind as keyof typeof KIND_TEXT, value }, masters, i18n.locale);
	const kindText = (kind: string) => (kind in KIND_TEXT ? tx(KIND_TEXT[kind as keyof typeof KIND_TEXT]) : kind);
	const conditionText = (type: string) => (type in CONDITION_TEXT ? tx(CONDITION_TEXT[type as keyof typeof CONDITION_TEXT]) : type);
</script>

<h2 class="mb-3 text-xl font-semibold" data-testid="rule-editor-title">{tx(rule ? 'dms.rule.edit' : 'dms.rule.new')}</h2>
<ErrorBanner message={error} />
{#if fieldErrors.length > 0}
	<ul class="text-destructive mb-3 list-disc pl-5 text-sm" data-testid="rule-field-errors">
		{#each fieldErrors as fe (fe.field + fe.code)}<li>{tx('dms.rule.fieldError', { field: fe.field, code: fe.code })}</li>{/each}
	</ul>
{/if}

<form onsubmit={save} class="space-y-5" novalidate data-testid="rule-form">
	<fieldset class="grid gap-3 sm:grid-cols-2">
		<legend class="mb-2 text-base font-medium">{tx('dms.rule.section.general')}</legend>
		<label class="block text-sm sm:col-span-2">
			<span class="mb-1 block">{tx('dms.rule.name')}</span>
			<Input bind:value={draft.name} maxlength={100} aria-invalid={problems.includes('nameRequired')} data-testid="rule-name" />
		</label>
		<label class="block text-sm">
			<span class="mb-1 block">{tx('dms.rule.priority')}</span>
			<Input type="number" min="-1000" max="1000" bind:value={draft.priority} data-testid="rule-priority" />
			<span class="text-muted-foreground mt-1 block text-xs">{tx('dms.rule.priorityHint')}</span>
		</label>
		<label class="block text-sm">
			<span class="mb-1 block">{tx('dms.rule.mode')}</span>
			<select class={selectClass} bind:value={draft.mode} data-testid="rule-mode">
				<option value="suggest">{tx('dms.rule.mode.suggest')}</option>
				<option value="auto">{tx('dms.rule.mode.auto')}</option>
			</select>
			<span class="text-muted-foreground mt-1 block text-xs">{tx(draft.mode === 'auto' ? 'dms.rule.mode.autoHint' : 'dms.rule.mode.suggestHint')}</span>
		</label>
		<label class="block text-sm">
			<span class="mb-1 block">{tx('dms.rule.confidence')}</span>
			<Input type="number" min="0" max="100" bind:value={draft.confidencePercent} data-testid="rule-confidence" />
		</label>
		<label class="flex items-center gap-2 self-end text-sm">
			<input type="checkbox" bind:checked={draft.enabled} data-testid="rule-enabled" />
			{tx('dms.rule.enabled')}
		</label>
	</fieldset>

	<fieldset class="space-y-3">
		<legend class="mb-2 text-base font-medium">{tx('dms.rule.section.conditions')}</legend>
		<label class="block text-sm">
			<span class="mb-1 block">{tx('dms.rule.match')}</span>
			<select class={`${selectClass} max-w-xs`} bind:value={draft.match} data-testid="rule-match">
				<option value="all">{tx('dms.rule.match.all')}</option>
				<option value="any">{tx('dms.rule.match.any')}</option>
			</select>
		</label>
		{#each draft.conditions as condition, index (index)}
			<div class="grid items-end gap-2 sm:grid-cols-[12rem_1fr_auto_auto]" data-testid="rule-condition">
				<label class="block text-sm">
					<span class="mb-1 block">{tx('dms.rule.cond.type')}</span>
					<select class={selectClass} bind:value={condition.type} onchange={() => onTypeChange(index)} data-testid="rule-cond-type">
						{#each CONDITION_TYPES as type (type)}<option value={type}>{conditionText(type)}</option>{/each}
					</select>
				</label>
				{#if condition.type === 'source_is'}
					<label class="block text-sm">
						<span class="mb-1 block">{tx('dms.rule.cond.value')}</span>
						<select class={selectClass} bind:value={condition.text} data-testid="rule-cond-value">
							{#each SOURCES as source (source)}<option value={source}>{tx(SOURCE_TEXT[source])}</option>{/each}
						</select>
					</label>
				{:else}
					<label class="block text-sm">
						<span class="mb-1 block">{tx(isRegex(condition.type) ? 'dms.rule.cond.pattern' : 'dms.rule.cond.value')}</span>
						<Input
							bind:value={condition.text}
							maxlength={200}
							class={isRegex(condition.type) ? 'font-mono' : ''}
							aria-invalid={problems.includes('conditionEmpty') && condition.text.trim() === ''}
							data-testid="rule-cond-value"
						/>
					</label>
				{/if}
				{#if condition.type === 'source_is'}
					<span></span>
				{:else}
					<label class="flex items-center gap-2 pb-1.5 text-sm">
						<input type="checkbox" bind:checked={condition.caseSensitive} />
						{tx('dms.rule.cond.caseSensitive')}
					</label>
				{/if}
				<Button type="button" variant="outline" size="sm" disabled={draft.conditions.length === 1} onclick={() => removeCondition(index)} data-testid="rule-cond-remove">
					{tx('dms.rule.cond.remove')}
				</Button>
			</div>
		{/each}
		<Button type="button" variant="outline" size="sm" disabled={draft.conditions.length >= 20} onclick={addCondition} data-testid="rule-cond-add">{tx('dms.rule.cond.add')}</Button>
		<p class="text-muted-foreground text-xs">{tx('dms.rule.regexHint')}</p>
	</fieldset>

	<fieldset class="grid gap-3 sm:grid-cols-2">
		<legend class="mb-2 text-base font-medium">{tx('dms.rule.section.actions')}</legend>
		<label class="block text-sm">
			<span class="mb-1 block">{tx('dms.field.correspondent')}</span>
			<select class={selectClass} bind:value={draft.correspondentId} data-testid="rule-act-corr">
				<option value="">{tx('dms.edit.none')}</option>
				{#each masters.contacts as c (c.id)}<option value={c.id}>{c.name}</option>{/each}
			</select>
		</label>
		<label class="block text-sm">
			<span class="mb-1 block">{tx('dms.field.type')}</span>
			<select class={selectClass} bind:value={draft.documentTypeId} data-testid="rule-act-type">
				<option value="">{tx('dms.edit.none')}</option>
				{#each masters.types as type (type.id)}<option value={type.id}>{type.name}</option>{/each}
			</select>
		</label>
		<label class="block text-sm">
			<span class="mb-1 block">{tx('dms.rule.act.path')}</span>
			<select class={selectClass} bind:value={draft.storagePathId} data-testid="rule-act-path">
				<option value="">{tx('dms.edit.none')}</option>
				{#each masters.paths as path (path.id)}<option value={path.id}>{path.name}</option>{/each}
			</select>
		</label>
		<label class="block text-sm">
			<span class="mb-1 block">{tx('dms.rule.act.title')}</span>
			<Input bind:value={draft.titleTemplate} maxlength={300} placeholder={'{match} {date}'} data-testid="rule-act-title" />
			<span class="text-muted-foreground mt-1 block text-xs">{tx('dms.rule.act.titleHint')}</span>
		</label>
		<label class="block text-sm">
			<span class="mb-1 block">{tx('dms.field.date')}</span>
			<select class={selectClass} bind:value={draft.dateMode} data-testid="rule-act-datemode">
				<option value="none">{tx('dms.edit.none')}</option>
				<option value="extracted">{tx('dms.rule.act.dateExtracted')}</option>
				<option value="fixed">{tx('dms.rule.act.dateFixed')}</option>
			</select>
		</label>
		{#if draft.dateMode === 'fixed'}
			<label class="block text-sm">
				<span class="mb-1 block">{tx('dms.rule.act.dateValue')}</span>
				<Input type="date" bind:value={draft.fixedDate} aria-invalid={problems.includes('dateRequired')} data-testid="rule-act-date" />
			</label>
		{/if}
		{#if masters.tags.length > 0}
			<fieldset class="text-sm sm:col-span-2">
				<legend class="mb-1">{tx('dms.field.tags')}</legend>
				<div class="flex flex-wrap gap-x-4 gap-y-1">
					{#each masters.tags as tag (tag.id)}
						<label class="flex items-center gap-2">
							<input type="checkbox" checked={draft.tagIds.includes(tag.id)} onchange={() => toggleTag(tag.id)} data-testid={`rule-act-tag-${tag.name}`} />
							{tag.name}
						</label>
					{/each}
				</div>
			</fieldset>
		{/if}
	</fieldset>

	{#if problems.length > 0}
		<ul class="text-destructive list-disc pl-5 text-sm" role="alert" data-testid="rule-problems">
			{#each problems as p (p)}<li>{tx(problemText[p])}</li>{/each}
		</ul>
	{/if}

	<section class="space-y-3 rounded-lg border p-3" aria-labelledby="rule-preview-title">
		<h3 id="rule-preview-title" class="text-base font-medium">{tx('dms.rule.preview.title')}</h3>
		<p class="text-muted-foreground text-xs">{tx('dms.rule.preview.hint')}</p>
		<div class="flex flex-wrap items-end gap-3">
			<label class="text-sm">
				<span class="mb-1 block">{tx('dms.rule.preview.limit')}</span>
				<Input type="number" min="1" max="500" class="w-28" bind:value={previewLimit} data-testid="rule-preview-limit" />
			</label>
			<Button type="button" variant="outline" disabled={previewing} onclick={runPreview} data-testid="rule-preview-run">{tx('dms.rule.preview.run')}</Button>
		</div>
		{#if preview}
			<div data-testid="rule-preview" data-current={previewCurrent}>
				<p role="status" class="text-sm" data-testid="rule-preview-summary">{tx('dms.rule.preview.summary', { checked: preview.checked, matched: preview.matched })}</p>
				{#if !previewCurrent}
					<p class="text-sm" data-testid="rule-preview-outdated">{tx('dms.rule.preview.outdated')}</p>
				{/if}
				{#if preview.timed_out > 0}
					<div class="my-2" data-testid="rule-preview-timeout">
						<Alert.Root variant="destructive"><Alert.Description>{tx('dms.rule.preview.timedOut', { count: preview.timed_out })}</Alert.Description></Alert.Root>
					</div>
				{/if}
				{#if preview.truncated}
					<p class="text-sm" data-testid="rule-preview-truncated">{tx('dms.rule.preview.truncated')}</p>
				{/if}
				{#if preview.items.length === 0}
					<p class="text-muted-foreground text-sm" data-testid="rule-preview-none">{tx('dms.rule.preview.none')}</p>
				{:else}
					<div class="overflow-x-auto">
						<table class="mt-2 w-full text-left text-sm" data-testid="rule-preview-table">
							<caption class="sr-only">{tx('dms.rule.preview.title')}</caption>
							<thead>
								<tr class="text-muted-foreground border-b">
									<th scope="col" class="py-1 pr-3">{tx('dms.field.title')}</th>
									<th scope="col" class="py-1 pr-3">{tx('dms.rule.preview.found')}</th>
									<th scope="col" class="py-1">{tx('dms.rule.preview.suggestions')}</th>
								</tr>
							</thead>
							<tbody>
								{#each preview.items as item (item.document_id)}
									<tr class="border-b align-top" data-testid="rule-preview-row">
										<td class="py-1 pr-3"><a class="underline-offset-2 hover:underline" href={`/dms/${item.document_id}`}>{item.title}</a></td>
										<td class="py-1 pr-3">
											{#each item.matches as m, i (i)}<div class="break-all"><span class="text-muted-foreground">{conditionText(m.type)}:</span> {m.matched}</div>{/each}
										</td>
										<td class="py-1">
											{#each item.suggestions as s, i (i)}<div>{kindText(s.kind)}: <strong>{valueText(s.kind, s.value)}</strong></div>{/each}
										</td>
									</tr>
								{/each}
							</tbody>
						</table>
					</div>
				{/if}
			</div>
		{/if}
	</section>

	{#if needsPreview}
		<p class="text-sm" role="status" data-testid="rule-auto-needs-preview">{tx('dms.rule.autoNeedsPreview')}</p>
	{:else if !previewCurrent}
		<p class="text-muted-foreground text-sm" data-testid="rule-no-preview-hint">{tx('dms.rule.noPreviewHint')}</p>
	{/if}

	<div class="flex flex-wrap gap-2">
		<Button type="submit" disabled={saving || needsPreview} data-testid="rule-save">{tx('dms.rule.save')}</Button>
		<Button type="button" variant="outline" onclick={oncancel} data-testid="rule-cancel">{tx('common.cancel')}</Button>
	</div>
</form>
