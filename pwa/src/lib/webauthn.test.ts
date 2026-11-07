import { describe, expect, it } from 'vitest';
import { base64urlToBuffer, bufferToBase64url, toWebAuthnError } from './webauthn';

describe('webauthn helpers', () => {
	it('base64url round trip without padding', () => {
		const bytes = new Uint8Array([251, 255, 254, 1, 2]);
		const text = bufferToBase64url(bytes);
		expect(text).toBe('-__-AQI');
		expect([...new Uint8Array(base64urlToBuffer(text))]).toEqual([...bytes]);
	});

	it('maps DOMExceptions to error kinds', () => {
		expect(toWebAuthnError(new DOMException('x', 'NotAllowedError')).kind).toBe('cancelled');
		expect(toWebAuthnError(new DOMException('x', 'InvalidStateError')).kind).toBe('already_registered');
		expect(toWebAuthnError(new DOMException('x', 'SecurityError')).kind).toBe('unsupported');
		expect(toWebAuthnError(new Error('x')).kind).toBe('failed');
	});
});
