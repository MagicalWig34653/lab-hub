<script lang="ts">
	import { Button } from '#lib/components/ui/button';
	import { tx } from '#lib/i18n/index.svelte';

	let { tenant }: { tenant: string } = $props();
	// svelte-ignore state_referenced_locally
	const tenantId = tenant;

	const path = `/api/v1/tenants/${tenantId}/dms/share`;
	/** The real address of this hub (for the settings of the device); the curl example uses the placeholder host. */
	const endpoint = `${typeof location === 'undefined' ? '' : location.origin}${path}`;
	const curl = [
		`curl -X POST 'https://hub.example.org${path}?filename=scan.pdf' \\`,
		`  -H 'Authorization: Bearer lhp_YOUR_TOKEN' \\`,
		`  -H 'Content-Type: application/octet-stream' \\`,
		`  --data-binary @scan.pdf`
	].join('\n');

	let copied = $state<string | null>(null);
	async function copy(id: string, text: string) {
		try {
			await navigator.clipboard.writeText(text);
			copied = id;
		} catch {
			copied = `${id}-failed`;
		}
	}
</script>

<h1 class="mb-1 text-2xl font-semibold" data-testid="scanner-title">{tx('dms.scanner.title')}</h1>
<p class="text-muted-foreground mb-4 text-sm">{tx('dms.scanner.intro')}</p>

<div class="space-y-6">
	<section aria-labelledby="scanner-step1">
		<h2 id="scanner-step1" class="mb-1 text-base font-medium">{tx('dms.scanner.step1')}</h2>
		<p class="text-sm">
			{tx('dms.scanner.step1Text')}
			<a class="text-primary underline" href="/dms/tokens" data-testid="scanner-to-tokens">{tx('dms.scanner.toTokens')}</a>
		</p>
	</section>

	<section aria-labelledby="scanner-step2">
		<h2 id="scanner-step2" class="mb-1 text-base font-medium">{tx('dms.scanner.step2')}</h2>
		<dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-2 text-sm">
			<dt class="text-muted-foreground">{tx('dms.scanner.method')}</dt>
			<dd class="font-mono">{'POST'}</dd>
			<dt class="text-muted-foreground">{tx('dms.scanner.url')}</dt>
			<dd class="flex flex-wrap items-center gap-2">
				<code class="bg-muted rounded px-1.5 py-0.5 text-xs break-all" data-testid="scanner-endpoint">{endpoint}</code>
				<Button type="button" size="sm" variant="outline" onclick={() => copy('url', endpoint)} data-testid="scanner-copy-url">{tx('dms.scanner.copy')}</Button>
			</dd>
			<dt class="text-muted-foreground">{tx('dms.scanner.header')}</dt>
			<dd><code class="bg-muted rounded px-1.5 py-0.5 text-xs" data-testid="scanner-header">{'Authorization: Bearer lhp_…'}</code></dd>
			<dt class="text-muted-foreground">{tx('dms.scanner.body')}</dt>
			<dd>{tx('dms.scanner.bodyText')}</dd>
			<dt class="text-muted-foreground">{tx('dms.scanner.query')}</dt>
			<dd class="text-xs">{tx('dms.scanner.queryText')}</dd>
		</dl>
		{#if copied === 'url'}<p role="status" class="mt-1 text-sm">{tx('dms.tokens.copied')}</p>{/if}
	</section>

	<section aria-labelledby="scanner-step3">
		<h2 id="scanner-step3" class="mb-1 text-base font-medium">{tx('dms.scanner.step3')}</h2>
		<!-- Focusable so keyboard users can scroll the wide example (axe: scrollable-region-focusable). -->
		<!-- svelte-ignore a11y_no_noninteractive_tabindex -->
		<pre role="region" class="bg-muted overflow-x-auto rounded-md p-3 text-xs" tabindex="0" aria-label={tx('dms.scanner.curlLabel')} data-testid="scanner-curl">{curl}</pre>
		<div class="mt-2 flex items-center gap-2">
			<Button type="button" size="sm" variant="outline" onclick={() => copy('curl', curl)} data-testid="scanner-copy-curl">{tx('dms.scanner.copy')}</Button>
			{#if copied === 'curl'}<span role="status" class="text-sm">{tx('dms.tokens.copied')}</span>{/if}
			{#if copied?.endsWith('-failed')}<span role="alert" class="text-destructive text-sm">{tx('dms.tokens.copyFailed')}</span>{/if}
		</div>
		<p class="text-muted-foreground mt-2 text-xs">{tx('dms.scanner.curlNote')}</p>
	</section>

	<section aria-labelledby="scanner-step4">
		<h2 id="scanner-step4" class="mb-1 text-base font-medium">{tx('dms.scanner.step4')}</h2>
		<ul class="list-disc space-y-1 pl-5 text-sm">
			<li>{tx('dms.scanner.deviceScanner')}</li>
			<li>{tx('dms.scanner.deviceShare')}</li>
			<li>{tx('dms.scanner.idempotent')}</li>
		</ul>
	</section>

	<section aria-labelledby="scanner-step5">
		<h2 id="scanner-step5" class="mb-1 text-base font-medium">{tx('dms.scanner.step5')}</h2>
		<ul class="list-disc space-y-1 pl-5 text-sm">
			<li>{tx('dms.scanner.err201')}</li>
			<li>{tx('dms.scanner.err401')}</li>
			<li>{tx('dms.scanner.err404')}</li>
			<li>{tx('dms.scanner.err413')}</li>
			<li>{tx('dms.scanner.err415')}</li>
		</ul>
	</section>
</div>
