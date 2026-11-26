import { describe, expect, it } from 'vitest';
import { ACCENT_PRESETS, DEFAULT_ACCENT, accentTokens, contrastRatio, normalizeHex } from './accent';

// WP-ST7: accent colour per user. The tokens must keep text readable (WCAG 4.5:1) for every colour, light and dark.
describe('accent', () => {
	it('normalises #rgb and #rrggbb, rejects everything else', () => {
		expect(normalizeHex('#AbC')).toBe('#aabbcc');
		expect(normalizeHex(' #0D9488 ')).toBe('#0d9488');
		for (const bad of ['red', '#12345', '#gggggg', '2563eb', '#2563eb00', '']) expect(normalizeHex(bad)).toBeNull();
	});

	it('AK-ST7-3 ink and foreground reach 4.5:1 for every preset and extreme colours, light and dark', () => {
		const colours = [...ACCENT_PRESETS.map((p) => p.hex), '#ffff00', '#ffffff', '#000000', '#00ffff', '#111111'];
		for (const hex of colours) {
			for (const dark of [false, true]) {
				const tokens = accentTokens(hex, dark)!;
				expect(contrastRatio(tokens.foreground, tokens.primary), `${hex} fg`).toBeGreaterThanOrEqual(4.5);
				for (const surface of tokens.checkedSurfaces) {
					expect(contrastRatio(tokens.ink, surface), `${hex} ink on ${surface} dark=${dark}`).toBeGreaterThanOrEqual(4.5);
				}
			}
		}
	});

	it('keeps the chosen colour as ink when it is already readable', () => {
		expect(accentTokens('#1e3a8a', false)!.ink).toBe('#1e3a8a');
		expect(accentTokens('#fde047', false)!.ink).not.toBe('#fde047');
	});

	it('falls back to null for an invalid colour and has a valid default', () => {
		expect(accentTokens('nope', false)).toBeNull();
		expect(normalizeHex(DEFAULT_ACCENT)).toBe(DEFAULT_ACCENT);
		expect(new Set(ACCENT_PRESETS.map((p) => p.hex)).size).toBe(ACCENT_PRESETS.length);
	});
});

describe('accent hover', () => {
	it('AK-ST7-3 the hover fill keeps the foreground at 4.5:1 for every preset', () => {
		for (const { hex } of ACCENT_PRESETS) {
			const tokens = accentTokens(hex, false)!;
			expect(contrastRatio(tokens.foreground, tokens.hover), hex).toBeGreaterThanOrEqual(4.5);
		}
	});
});

describe('accent fill against the page', () => {
	it('AK-ST7-3 buttons stay distinguishable: the fill reaches 3:1 against the page, light and dark (review finding 12)', () => {
		const colours = [...ACCENT_PRESETS.map((p) => p.hex), '#ffff00', '#ffffff', '#000000', '#111111'];
		for (const hex of colours) {
			for (const dark of [false, true]) {
				const tokens = accentTokens(hex, dark)!;
				expect(contrastRatio(tokens.primary, dark ? '#09090b' : '#ffffff'), `${hex} dark=${dark}`).toBeGreaterThanOrEqual(3);
				expect(contrastRatio(tokens.foreground, tokens.primary), `${hex} fg dark=${dark}`).toBeGreaterThanOrEqual(4.5);
			}
		}
	});

	it('leaves a colour that already stands out untouched', () => {
		expect(accentTokens('#2563eb', false)!.primary).toBe('#2563eb');
		expect(accentTokens('#2563eb', true)!.primary).toBe('#2563eb');
		expect(accentTokens('#3f3f46', true)!.primary).not.toBe('#3f3f46');
	});
});
