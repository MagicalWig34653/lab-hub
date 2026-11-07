import { describe, expect, it } from 'vitest';
import { readdirSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';
import type { NavigationEntry, TenantModuleItem } from '#lib/api/client';
import FileText from '@lucide/svelte/icons/file-text';
import type { ModuleManifest } from './manifest';
import { registry } from './registry';
import { isModuleEffective, isUnderPrefix, resolveNavigation } from './resolve';
import { classifyRoute } from './routes';

const manifest = (key: string, routePrefix = `/${key}`): ModuleManifest => ({
	key,
	routePrefix,
	icon: FileText,
	messages: { de: {}, en: {} }
});
const mod = (key: string, over: Partial<TenantModuleItem> = {}): TenantModuleItem => ({
	key,
	requires: [],
	enhances: [],
	installed: true,
	enabled: true,
	effective: true,
	...over
});
const nav = (module: string, path = `/${module}`): NavigationEntry => ({ module, key: module, label_key: `nav.${module}`, path });

describe('AK-F2-1 navigation shows only active modules with a frontend manifest', () => {
	it('keeps entries of effective modules that have a manifest, in backend order', () => {
		const result = resolveNavigation([nav('b'), nav('a')], [mod('a'), mod('b')], [manifest('a'), manifest('b')]);
		expect(result.items.map((i) => i.module)).toEqual(['b', 'a']);
		expect(result.unavailable).toEqual([]);
	});

	it('hides entries of modules that are not effective (switched off, operator off, dependency missing)', () => {
		const modules = [mod('a', { enabled: false, effective: false }), mod('b', { installed: false, effective: false })];
		const result = resolveNavigation([nav('a'), nav('b')], modules, [manifest('a'), manifest('b')]);
		expect(result.items).toEqual([]);
	});

	it('hides a manifest whose backend module is not active at all', () => {
		expect(resolveNavigation([], [], [manifest('a')]).items).toEqual([]);
	});

	it('reports an effective module without manifest as API/app only and shows no entry for it', () => {
		const result = resolveNavigation([nav('z')], [mod('z')], [manifest('a')]);
		expect(result.items).toEqual([]);
		expect(result.unavailable).toEqual(['z']);
	});

	it('drops a backend path outside the module route prefix', () => {
		const result = resolveNavigation([nav('a', '/settings/members'), nav('a', '/a/list')], [mod('a')], [manifest('a')]);
		expect(result.items.map((i) => i.path)).toEqual(['/a/list']);
	});

	it('isUnderPrefix matches whole segments only', () => {
		expect(isUnderPrefix('/dms', '/dms')).toBe(true);
		expect(isUnderPrefix('/dms/x', '/dms')).toBe(true);
		expect(isUnderPrefix('/dmsx', '/dms')).toBe(false);
	});

	it('isModuleEffective reads the effective flag', () => {
		expect(isModuleEffective([mod('a')], 'a')).toBe(true);
		expect(isModuleEffective([mod('a', { effective: false })], 'a')).toBe(false);
		expect(isModuleEffective([], 'a')).toBe(false);
	});
});

describe('module registry (hook-in point for DMS)', () => {
	it('keys and route prefixes are unique and prefixes do not overlap', () => {
		expect(new Set(registry.map((m) => m.key)).size).toBe(registry.length);
		for (const a of registry) {
			expect(a.routePrefix).toMatch(/^\/[a-z0-9-]+$/);
			for (const b of registry) if (a !== b) expect(isUnderPrefix(a.routePrefix, b.routePrefix)).toBe(false);
		}
	});

	it('manifest texts have the same keys in de and en', () => {
		for (const m of registry) expect(Object.keys(m.messages.en).sort(), m.key).toEqual(Object.keys(m.messages.de).sort());
	});

	it('the DMS placeholder route is registered', () => {
		expect(registry.find((m) => m.key === 'dms')?.routePrefix).toBe('/dms');
	});
});

describe('AK-F2-3 route classification', () => {
	function routes(dir: string): string[] {
		return readdirSync(dir).flatMap((name) => {
			const path = join(dir, name);
			if (statSync(path).isDirectory()) return routes(path);
			return name === '+page.svelte' ? [relative(join(process.cwd(), 'src', 'routes'), dir)] : [];
		});
	}

	it('every +page.svelte is a core route or lies below exactly one module prefix', () => {
		const all = routes(join(process.cwd(), 'src', 'routes'));
		expect(all.length).toBeGreaterThan(8);
		const unclassified = all.filter((route) => classifyRoute(route).kind === 'unclassified');
		expect(unclassified).toEqual([]);
		expect(all.some((route) => classifyRoute(route).kind === 'module')).toBe(true);
	});

	it('classifies samples', () => {
		expect(classifyRoute('(app)/dashboard')).toEqual({ kind: 'core' });
		expect(classifyRoute('(app)/settings/members')).toEqual({ kind: 'core' });
		expect(classifyRoute('(app)/dms/[id]')).toEqual({ kind: 'module', module: 'dms' });
		expect(classifyRoute('(app)/invoices')).toEqual({ kind: 'unclassified' });
	});

	it('flags a route claimed by two modules', () => {
		const result = classifyRoute('(app)/a/x', [manifest('a'), manifest('a2', '/a')]);
		expect(result.kind).toBe('unclassified');
	});
});
