import { meApi } from '#lib/api/client';
import { DEFAULT_ACCENT, accentTokens, normalizeHex } from './accent';

export type ThemeMode = 'system' | 'light' | 'dark';

/** Colour scheme per device (WP-ST4); read before first paint by static/theme-init.js, keep the key in sync there. */
const KEY_MODE = 'lh.theme';
/** Last known accent per user id (instant apply on the next load, also before the server answers). */
const accentKey = (user: string) => `lh.accent.${user}`;
/** Accent of the last user on this device, used by theme-init.js on the login page and before the session is known. */
const KEY_LAST_ACCENT = 'lh.accent';

function read(key: string): string | null {
	try {
		return localStorage.getItem(key);
	} catch {
		return null;
	}
}

function write(key: string, value: string | null): void {
	try {
		if (value === null) localStorage.removeItem(key);
		else localStorage.setItem(key, value);
	} catch {
		// storage blocked: the choice then lasts for this tab only
	}
}

/**
 * Appearance (WP-ST7): the colour scheme (system/light/dark) stays per device, the accent colour belongs to the user account
 * (`/me/preferences`) and is cached per user id. `attach` is called whenever a normal session is known.
 */
export class ThemeStore {
	mode = $state<ThemeMode>('system');
	accent = $state<string>(DEFAULT_ACCENT);
	/** true when the account has no own colour (the default is shown) */
	isDefault = $state(true);
	systemDark = $state(false);
	private user: string | null = null;
	private started = false;

	get dark(): boolean {
		return this.mode === 'dark' || (this.mode === 'system' && this.systemDark);
	}

	readMode(): ThemeMode {
		const stored = read(KEY_MODE);
		return stored === 'light' || stored === 'dark' ? stored : 'system';
	}

	init(): void {
		if (this.started || typeof window === 'undefined') return;
		this.started = true;
		this.mode = this.readMode();
		const last = normalizeHex(read(KEY_LAST_ACCENT) ?? '');
		if (last) this.useAccent(last, false);
		const query = window.matchMedia?.('(prefers-color-scheme: dark)');
		if (query) {
			this.systemDark = query.matches;
			query.addEventListener?.('change', (event) => {
				this.systemDark = event.matches;
				this.apply();
			});
		}
		this.apply();
	}

	setMode(mode: ThemeMode): void {
		this.init();
		this.mode = mode;
		write(KEY_MODE, mode === 'system' ? null : mode);
		this.apply();
	}

	/** Loads the accent of `user`: the cached colour at once, then the account's value. */
	async attach(user: string): Promise<void> {
		this.init();
		this.user = user;
		const cached = normalizeHex(read(accentKey(user)) ?? '');
		this.useAccent(cached ?? DEFAULT_ACCENT, !cached);
		try {
			const { accent } = await meApi.getPreferences();
			if (this.user === user) this.remember(user, accent ?? null);
		} catch {
			// offline or older server: keep the cache
		}
	}

	/** Called on sign-out: the next user starts from the default. */
	detach(): void {
		this.user = null;
		write(KEY_LAST_ACCENT, null);
		this.useAccent(DEFAULT_ACCENT, true);
	}

	/** Saves a colour (or `null` = default) to the account; on failure the previous colour stays and the error propagates. */
	async setAccent(input: string | null): Promise<void> {
		const hex = input === null ? null : normalizeHex(input);
		if (input !== null && !hex) throw new Error('invalid colour');
		const { accent } = await meApi.updatePreferences({ accent: hex });
		if (this.user) this.remember(this.user, accent ?? null);
		else this.useAccent(accent ?? DEFAULT_ACCENT, !accent);
	}

	private remember(user: string, accent: string | null): void {
		const hex = accent ? normalizeHex(accent) : null;
		write(accentKey(user), hex);
		write(KEY_LAST_ACCENT, hex);
		this.useAccent(hex ?? DEFAULT_ACCENT, !hex);
	}

	private useAccent(hex: string, isDefault: boolean): void {
		this.accent = hex;
		this.isDefault = isDefault;
		this.apply();
	}

	apply(): void {
		if (typeof document === 'undefined') return;
		const root = document.documentElement;
		root.classList.toggle('dark', this.dark);
		const tokens = accentTokens(this.accent, this.dark) ?? accentTokens(DEFAULT_ACCENT, this.dark)!;
		root.style.setProperty('--ui-accent', tokens.primary);
		root.style.setProperty('--ui-accent-foreground', tokens.foreground);
		root.style.setProperty('--ui-accent-ink', tokens.ink);
		root.style.setProperty('--ui-accent-soft', tokens.soft);
		// primary actions carry the accent (TimeTrack pattern)
		root.style.setProperty('--primary', tokens.primary);
		root.style.setProperty('--primary-foreground', tokens.foreground);
		root.style.setProperty('--primary-hover', tokens.hover);
		root.style.setProperty('--ring', tokens.ink);
		document.querySelector('meta[name="theme-color"]')?.setAttribute('content', this.dark ? '#09090b' : '#ffffff');
	}
}

export const theme = new ThemeStore();
