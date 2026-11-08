import type { Component } from 'svelte';

/** What the shell passes to a module icon (lucide icons accept these). */
export type IconProps = { class?: string; 'aria-hidden'?: 'true' | 'false' | boolean };

/** A navigation link a module contributes to the sidebar. */
export interface NavItemDef {
	id: string;
	path: string;
	/** Text key (module message or core key). */
	labelKey: string;
	icon?: Component<IconProps>;
	/** Tenant permission needed to see the link (visibility only). */
	permission?: string;
	testId?: string;
	/** Marks the link as current for these paths (default: the path or below). */
	matches?: RegExp;
	exact?: boolean;
}

/** A titled section of module links ("Dokumente", "Verwaltung"). */
export interface NavGroupDef {
	id: string;
	labelKey: string;
	items: NavItemDef[];
	defaultOpen?: boolean;
}

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
	/** Sidebar sections of the module (WP-F4c). Without them the shell shows the single backend entry. */
	navigation?: NavGroupDef[];
	/** Module texts, same keys in both languages (checked by `registry.test.ts`). Navigation labels use the backend `label_key`. */
	messages: { de: Record<string, string>; en: Record<string, string> };
}
