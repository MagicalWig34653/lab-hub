import { tenantApi, type TenantDetail, type TenantModules } from '#lib/api/client';
import { errorMessage } from '#lib/i18n/index.svelte';
import { registry } from '#lib/modules/registry';
import { resolveNavigation, isModuleEffective } from '#lib/modules/resolve';
import { session } from '#lib/session.svelte';

const STORAGE_KEY = 'lh.tenant';

function readStored(): string | null {
	try {
		return localStorage.getItem(STORAGE_KEY);
	} catch {
		return null;
	}
}

function writeStored(id: string): void {
	try {
		localStorage.setItem(STORAGE_KEY, id);
	} catch {
		// storage is only a convenience
	}
}

/**
 * Active tenant with its permissions and modules (docs/FRONTEND.md section 5). Everything tenant-bound lives here, so a
 * tenant switch replaces it in one step and no module data of the previous tenant stays around. Roles only steer
 * visibility (`can`); authorization is the backend's.
 */
class Workspace {
	activeId = $state<string | null>(null);
	detail = $state<TenantDetail | null>(null);
	modules = $state<TenantModules | null>(null);
	loading = $state(false);
	error = $state<string | null>(null);
	private seq = 0;

	get memberships() {
		return session.current?.memberships ?? [];
	}

	get navigation() {
		return this.modules ? resolveNavigation(this.modules.navigation, this.modules.items, registry) : { items: [], unavailable: [] };
	}

	can(permission: string): boolean {
		return this.detail?.permissions.includes(permission) ?? false;
	}

	moduleEffective(key: string): boolean {
		return this.modules ? isModuleEffective(this.modules.items, key) : false;
	}

	/** Picks the tenant (remembered one if the user is still a member, else the first) and loads it. Emergency sessions skip it. */
	async init(): Promise<void> {
		if (session.isRecovery) return this.reset();
		const ids = this.memberships.map((m) => m.tenant_id);
		if (this.activeId && ids.includes(this.activeId) && this.detail) return;
		const stored = readStored();
		const id = (this.activeId && ids.includes(this.activeId) ? this.activeId : null) ?? (stored && ids.includes(stored) ? stored : ids[0]);
		if (!id) return this.reset();
		await this.activate(id);
	}

	async switchTo(id: string): Promise<void> {
		if (id === this.activeId || !this.memberships.some((m) => m.tenant_id === id)) return;
		await this.activate(id);
	}

	/** Re-reads modules and navigation (after toggling, on focus), so backend changes apply without a rebuild (AK-F2-2). */
	async refreshModules(): Promise<void> {
		const id = this.activeId;
		if (!id || session.isRecovery) return;
		const seq = this.seq;
		try {
			const modules = await tenantApi.modules(id);
			if (seq === this.seq && id === this.activeId) this.modules = modules;
		} catch {
			// keep the last known state; the next explicit load reports errors
		}
	}

	async reload(): Promise<void> {
		if (this.activeId) await this.activate(this.activeId);
	}

	private async activate(id: string): Promise<void> {
		const seq = ++this.seq;
		this.activeId = id;
		this.detail = null;
		this.modules = null;
		this.error = null;
		this.loading = true;
		try {
			const [detail, modules] = await Promise.all([tenantApi.get(id), tenantApi.modules(id)]);
			if (seq !== this.seq) return;
			this.detail = detail;
			this.modules = modules;
			writeStored(id);
		} catch (e) {
			if (seq === this.seq) this.error = errorMessage(e);
		} finally {
			if (seq === this.seq) this.loading = false;
		}
	}

	reset(): void {
		this.seq++;
		this.activeId = null;
		this.detail = null;
		this.modules = null;
		this.error = null;
		this.loading = false;
	}
}

export const workspace = new Workspace();
