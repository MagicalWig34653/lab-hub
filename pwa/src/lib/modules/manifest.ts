import type { Component } from 'svelte';

/** What the shell passes to a module icon (lucide icons accept these). */
export type IconProps = { class?: string; 'aria-hidden'?: 'true' | 'false' | boolean };

/**
 * Frontend half of a module (docs/FRONTEND.md section 4). The backend decides which modules are active and what the
 * navigation contains (`GET /api/v1/tenants/{t}/modules`); the manifest only adds what the backend cannot know:
 * the route prefix, an icon and the module's own texts. A module hooks in by adding its manifest to `registry.ts`.
 */
export interface ModuleManifest {
	/** Identical to the backend module key. */
	key: string;
	/** All routes of the module live below this prefix, e.g. `/dms` (checked by `routes.test.ts`). */
	routePrefix: string;
	icon: Component<IconProps>;
	/** Module texts, same keys in both languages (checked by `registry.test.ts`). Navigation labels use the backend `label_key`. */
	messages: { de: Record<string, string>; en: Record<string, string> };
}
