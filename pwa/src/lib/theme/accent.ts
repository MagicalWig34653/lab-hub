/**
 * Accent colour per user (WP-ST7). One colour chosen by the user yields four tokens: the fill (`primary`), the text on the
 * fill (`foreground`, white or black), the accent as text colour (`ink`, darkened/lightened until it reaches 4.5:1 on the
 * page, the sidebar and the soft tint) and the soft tint for active navigation and chips.
 * Design reference: TimeTrack (structure only, own implementation).
 */

export const DEFAULT_ACCENT = '#2563eb';
export const MIN_TEXT_CONTRAST = 4.5;
/** Controls (buttons) must stand out from the page (WCAG 1.4.11). */
export const MIN_FILL_CONTRAST = 3;

/** Page and sidebar background per scheme (must match `--background` / `--sidebar` in layout.css). */
export const SURFACES = {
	light: { background: '#ffffff', sidebar: '#fafafa' },
	dark: { background: '#09090b', sidebar: '#18181b' }
} as const;

/** Palette offered on the appearance page; ids are only labels for the UI, the account stores the colour. */
export const ACCENT_PRESETS = [
	{ id: 'blue', hex: '#2563eb' },
	{ id: 'indigo', hex: '#4f46e5' },
	{ id: 'violet', hex: '#7c3aed' },
	{ id: 'pink', hex: '#db2777' },
	{ id: 'red', hex: '#dc2626' },
	{ id: 'orange', hex: '#ea580c' },
	{ id: 'amber', hex: '#d97706' },
	{ id: 'green', hex: '#16a34a' },
	{ id: 'teal', hex: '#0d9488' },
	{ id: 'cyan', hex: '#0891b2' },
	{ id: 'slate', hex: '#475569' },
	{ id: 'graphite', hex: '#3f3f46' }
] as const;
export type AccentPresetId = (typeof ACCENT_PRESETS)[number]['id'];

export function normalizeHex(input: string): string | null {
	const match = /^#([0-9a-f]{3}|[0-9a-f]{6})$/i.exec(input.trim());
	if (!match) return null;
	const digits = match[1].toLowerCase();
	return '#' + (digits.length === 3 ? [...digits].map((d) => d + d).join('') : digits);
}

function rgb(hex: string): number[] {
	return [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16));
}

function luminance(hex: string): number {
	const [r, g, b] = rgb(hex).map((v) => {
		const c = v / 255;
		return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
	});
	return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/** WCAG contrast ratio of two `#rrggbb` colours. */
export function contrastRatio(a: string, b: string): number {
	const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
	return (hi + 0.05) / (lo + 0.05);
}

/** `share` percent of `top` over `base` in sRGB (same result as CSS `color-mix(in srgb, …)`). */
export function mix(top: string, share: number, base: string): string {
	const t = rgb(top);
	const b = rgb(base);
	return '#' + t.map((v, i) => Math.round(v * (share / 100) + b[i] * (1 - share / 100)).toString(16).padStart(2, '0')).join('');
}

export interface AccentTokens {
	primary: string;
	foreground: '#ffffff' | '#000000';
	/** fill on hover: moved away from the foreground, so the text gets more contrast, not less */
	hover: string;
	ink: string;
	/** CSS value of the soft tint (follows the background token) */
	soft: string;
	/** surfaces the ink was checked against (page, sidebar, soft tint on both) */
	checkedSurfaces: string[];
}

const textOn = (fill: string): '#ffffff' | '#000000' => (contrastRatio(fill, '#ffffff') >= contrastRatio(fill, '#000000') ? '#ffffff' : '#000000');

/** Moves `hex` towards `towards` in 5 % steps until `ok` holds. */
function shift(hex: string, towards: string, ok: (colour: string) => boolean): string {
	let colour = hex;
	for (let step = 1; step <= 20 && !ok(colour); step++) colour = mix(towards, step * 5, hex);
	return colour;
}

export function accentTokens(input: string, dark: boolean): AccentTokens | null {
	const hex = normalizeHex(input);
	if (!hex) return null;
	const { background, sidebar } = dark ? SURFACES.dark : SURFACES.light;
	const towards = dark ? '#ffffff' : '#000000';
	// A colour too close to the page (graphite on dark, yellow on white) is moved away until buttons stay visible.
	const primary = shift(hex, towards, (c) => contrastRatio(c, background) >= MIN_FILL_CONTRAST && contrastRatio(textOn(c), c) >= MIN_TEXT_CONTRAST);
	const share = dark ? 20 : 10;
	const checkedSurfaces = [background, sidebar, mix(primary, share, background), mix(primary, share, sidebar)];
	const ink = shift(primary, towards, (c) => checkedSurfaces.every((s) => contrastRatio(c, s) >= MIN_TEXT_CONTRAST));
	const foreground = textOn(primary);
	const hover = mix(foreground === '#ffffff' ? '#000000' : '#ffffff', 12, primary);
	return { primary, foreground, hover, ink, soft: `color-mix(in srgb, ${primary} ${share}%, var(--background))`, checkedSurfaces };
}
