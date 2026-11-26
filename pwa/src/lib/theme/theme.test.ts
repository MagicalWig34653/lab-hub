import { beforeEach, describe, expect, it, vi } from 'vitest';

const getPreferences = vi.fn();
const updatePreferences = vi.fn();
vi.mock('#lib/api/client', () => ({ meApi: { getPreferences: () => getPreferences(), updatePreferences: (b: unknown) => updatePreferences(b) } }));

const { ThemeStore } = await import('./theme.svelte');

// WP-ST7: the colour scheme stays per device (ST4), the accent belongs to the user account.
describe('ThemeStore', () => {
	beforeEach(() => {
		localStorage.clear();
		document.documentElement.className = '';
		document.documentElement.removeAttribute('style');
		getPreferences.mockReset();
		updatePreferences.mockReset();
	});

	it('AK-ST7-4 applies the accent of each user and caches it per user, not per device', async () => {
		const store = new ThemeStore();
		getPreferences.mockResolvedValueOnce({ accent: '#0d9488' });
		await store.attach('user-a');
		expect(document.documentElement.style.getPropertyValue('--ui-accent')).toBe('#0d9488');

		getPreferences.mockResolvedValueOnce({ accent: null });
		await store.attach('user-b');
		expect(store.accent).toBe('#2563eb');
		expect(document.documentElement.style.getPropertyValue('--ui-accent')).toBe('#2563eb');

		// a fresh page load of user A shows the cached colour before the server answers
		const reloaded = new ThemeStore();
		getPreferences.mockReturnValueOnce(new Promise(() => {}));
		void reloaded.attach('user-a');
		expect(reloaded.accent).toBe('#0d9488');
	});

	it('saves a chosen accent to the account and keeps the old one when saving fails', async () => {
		const store = new ThemeStore();
		getPreferences.mockResolvedValueOnce({ accent: null });
		await store.attach('user-a');
		updatePreferences.mockResolvedValueOnce({ accent: '#7c3aed' });
		await store.setAccent('#7C3AED');
		expect(updatePreferences).toHaveBeenCalledWith({ accent: '#7c3aed' });
		expect(store.accent).toBe('#7c3aed');

		updatePreferences.mockRejectedValueOnce(new Error('offline'));
		await expect(store.setAccent('#db2777')).rejects.toThrow();
		expect(store.accent).toBe('#7c3aed');
	});

	it('AK-ST4-1 colour scheme: system by default, a manual choice is kept per device', () => {
		const store = new ThemeStore();
		store.init();
		expect(store.mode).toBe('system');
		store.setMode('dark');
		expect(document.documentElement.classList.contains('dark')).toBe(true);
		expect(new ThemeStore().readMode()).toBe('dark');
		store.setMode('light');
		expect(document.documentElement.classList.contains('dark')).toBe(false);
	});
});
