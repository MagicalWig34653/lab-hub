import { beforeEach, describe, expect, it, vi } from 'vitest';

const tenantApi = vi.hoisted(() => ({ get: vi.fn(), modules: vi.fn() }));
vi.mock('#lib/api/client', async (original) => ({ ...(await original<object>()), tenantApi }));

import { session } from '#lib/session.svelte';
import { workspace } from '#lib/workspace.svelte';

const A = '11111111-1111-1111-1111-111111111111';
const B = '22222222-2222-2222-2222-222222222222';

function signIn() {
	session.apply({
		user: { id: 'u', handle: 'ada', display_name: 'Ada', is_operator: false },
		memberships: [
			{ tenant_id: A, name: 'A', role: 'owner' },
			{ tenant_id: B, name: 'B', role: 'member' }
		],
		kind: 'normal',
		expires_at: '2030-01-01T00:00:00Z',
		csrf_token: 'x'
	});
}

const modules = (effective: boolean) => ({
	items: [{ key: 'dms', requires: [], enhances: [], installed: true, enabled: effective, effective }],
	navigation: effective ? [{ module: 'dms', key: 'dms', label_key: 'nav.dms', path: '/dms' }] : []
});

beforeEach(() => {
	localStorage.clear();
	workspace.reset();
	tenantApi.get.mockReset();
	tenantApi.modules.mockReset();
	tenantApi.get.mockImplementation(async (id: string) => ({
		id,
		name: id === A ? 'A' : 'B',
		role: id === A ? 'owner' : 'member',
		permissions: id === A ? ['tenant.module.manage'] : ['tenant.tenant.read']
	}));
	tenantApi.modules.mockImplementation(async (id: string) => modules(id === A));
	signIn();
});

describe('workspace (tenant switch)', () => {
	it('starts with the first membership and derives permissions and navigation', async () => {
		await workspace.init();
		expect(workspace.activeId).toBe(A);
		expect(workspace.can('tenant.module.manage')).toBe(true);
		expect(workspace.navigation.items.map((i) => i.module)).toEqual(['dms']);
	});

	it('remembers the choice and prefers it on the next start', async () => {
		await workspace.init();
		await workspace.switchTo(B);
		workspace.reset();
		await workspace.init();
		expect(workspace.activeId).toBe(B);
	});

	it('ignores a remembered tenant the user is no longer a member of', async () => {
		localStorage.setItem('lh.tenant', '33333333-3333-3333-3333-333333333333');
		await workspace.init();
		expect(workspace.activeId).toBe(A);
	});

	it('a switch replaces permissions and modules; nothing of the old tenant stays', async () => {
		await workspace.init();
		await workspace.switchTo(B);
		expect(workspace.activeId).toBe(B);
		expect(workspace.can('tenant.module.manage')).toBe(false);
		expect(workspace.navigation.items).toEqual([]);
		expect(workspace.moduleEffective('dms')).toBe(false);
	});

	it('clears tenant data while the new tenant loads and ignores a stale response', async () => {
		await workspace.init();
		let release: (value: unknown) => void = () => {};
		tenantApi.get.mockImplementationOnce(() => new Promise((resolve) => (release = resolve)));
		const slow = workspace.switchTo(B);
		expect(workspace.detail).toBeNull();
		expect(workspace.modules).toBeNull();
		await workspace.switchTo(A); // second switch wins
		release({ id: B, name: 'B', role: 'member', permissions: [] });
		await slow;
		expect(workspace.activeId).toBe(A);
		expect(workspace.detail?.id).toBe(A);
	});

	it('AK-F2-2: refreshModules picks up a backend change without reload', async () => {
		await workspace.init();
		expect(workspace.moduleEffective('dms')).toBe(true);
		tenantApi.modules.mockResolvedValue(modules(false));
		await workspace.refreshModules();
		expect(workspace.moduleEffective('dms')).toBe(false);
		expect(workspace.navigation.items).toEqual([]);
	});

	it('an emergency session loads no tenant', async () => {
		session.apply({ ...session.current!, kind: 'recovery' });
		await workspace.init();
		expect(workspace.activeId).toBeNull();
		expect(tenantApi.get).not.toHaveBeenCalled();
	});

	it('reports a load error instead of throwing', async () => {
		tenantApi.get.mockRejectedValue(new Error('boom'));
		await workspace.init();
		expect(workspace.error).not.toBeNull();
		expect(workspace.loading).toBe(false);
	});
});
