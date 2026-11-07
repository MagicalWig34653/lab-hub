import type { Locale } from '#lib/i18n/index.svelte';

/** Date and time for display in the UI language (`Intl`); an unparsable value is shown as it came. */
export function formatDateTime(value: string, locale: Locale): string {
	const date = new Date(value);
	if (Number.isNaN(date.getTime())) return value;
	return new Intl.DateTimeFormat(locale, { dateStyle: 'medium', timeStyle: 'short' }).format(date);
}

/** Recovery codes as a plain-text file body (one code per line) for the download. */
export function recoveryCodesFile(title: string, codes: readonly string[]): string {
	return `${title}\n\n${codes.join('\n')}\n`;
}

/** The invitation link: the backend sends an absolute link when it knows its public origin, else the token path is used. */
export function invitationLink(link: string | undefined, token: string, origin: string): string {
	if (link && /^https?:\/\//.test(link)) return link;
	return `${origin}${link && link.startsWith('/') ? link : `/invite/${token}`}`;
}

/** A calendar date (`yyyy-MM-dd`, no time zone) for display; shown as it came when unparsable. */
export function formatDate(value: string | null | undefined, locale: Locale): string {
	if (!value) return '';
	const date = new Date(`${value}T00:00:00Z`);
	if (Number.isNaN(date.getTime())) return value;
	return new Intl.DateTimeFormat(locale, { dateStyle: 'medium', timeZone: 'UTC' }).format(date);
}

/** File size with binary units. */
export function formatBytes(bytes: number, locale: Locale): string {
	const units = ['B', 'KiB', 'MiB', 'GiB'];
	let value = bytes;
	let unit = 0;
	while (value >= 1024 && unit < units.length - 1) {
		value /= 1024;
		unit++;
	}
	return `${new Intl.NumberFormat(locale, { maximumFractionDigits: unit === 0 ? 0 : 1 }).format(value)} ${units[unit]}`;
}
