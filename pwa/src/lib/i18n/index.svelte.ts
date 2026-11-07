import { de, type MessageKey } from './de';
import { en } from './en';
import { ApiError } from '#lib/api/errors';
import { WebAuthnError } from '#lib/webauthn';

export type Locale = 'de' | 'en';
export const locales: Locale[] = ['de', 'en'];
export type { MessageKey };

const catalogues: Record<Locale, Record<MessageKey, string>> = { de, en };
const STORAGE_KEY = 'lh.locale';

/** Interpolates `{name}` placeholders. */
export function format(template: string, params?: Record<string, string | number>): string {
	if (!params) return template;
	return template.replace(/\{(\w+)\}/g, (match, name: string) => (name in params ? String(params[name]) : match));
}

/** Language choice: stored choice > browser language > de. */
export function detectLocale(stored: string | null, browser: readonly string[]): Locale {
	if (stored === 'de' || stored === 'en') return stored;
	for (const tag of browser) {
		const base = tag.toLowerCase().split('-')[0];
		if (base === 'de' || base === 'en') return base;
	}
	return 'de';
}

function readStored(): string | null {
	try {
		return localStorage.getItem(STORAGE_KEY);
	} catch {
		return null;
	}
}

/** Module texts registered by frontend manifests (keys are not part of the core `MessageKey` type). */
const extra: Record<Locale, Record<string, string>> = { de: {}, en: {} };

export function registerMessages(messages: Record<Locale, Record<string, string>>): void {
	for (const locale of locales) Object.assign(extra[locale], messages[locale]);
}

class I18n {
	locale = $state<Locale>('de');

	init() {
		const browser = typeof navigator === 'undefined' ? [] : (navigator.languages ?? [navigator.language]);
		this.locale = detectLocale(readStored(), browser);
	}

	set(locale: Locale) {
		this.locale = locale;
		try {
			localStorage.setItem(STORAGE_KEY, locale);
		} catch {
			// storage is only a convenience
		}
	}

	t = (key: MessageKey, params?: Record<string, string | number>): string => format(catalogues[this.locale][key], params);

	/** Dynamic key (backend `label_key`, module texts): core or module catalogue, else the key itself. */
	tx = (key: string, params?: Record<string, string | number>): string => {
		const text = (catalogues[this.locale] as Record<string, string>)[key] ?? extra[this.locale][key];
		return text === undefined ? key : format(text, params);
	};

	has = (key: string): key is MessageKey => key in de;
}

export const i18n = new I18n();
if (typeof window !== 'undefined') i18n.init();

/** Like `t` for keys only known at runtime. */
export const tx = (key: string, params?: Record<string, string | number>) => i18n.tx(key, params);

export const t = (key: MessageKey, params?: Record<string, string | number>) => i18n.t(key, params);

/** Maps an error to a user text: API code -> `error.<code>`, then `error.status_<n>`, then generic. */
export function errorMessage(error: unknown): string {
	if (error instanceof ApiError) {
		const byCode = `error.${error.code}`;
		if (i18n.has(byCode)) return i18n.t(byCode);
		const byStatus = `error.status_${error.status}`;
		if (i18n.has(byStatus)) return i18n.t(byStatus);
		return i18n.t('error.generic');
	}
	if (error instanceof WebAuthnError) return i18n.t(`webauthn.${error.kind}` as MessageKey);
	return i18n.t('error.generic');
}
