import type { Page } from '@playwright/test';

/**
 * Synthetic scan: a PDF whose only content is a JPEG image of rendered text (no text layer), so the worker has to run OCR.
 * The text is drawn on a canvas in the browser and wrapped into a minimal PDF here. No real data.
 */
export async function renderScanPdf(page: Page, lines: string[]): Promise<Buffer> {
	const base64 = await page.evaluate((text) => {
		const canvas = document.createElement('canvas');
		canvas.width = 1654; // A4 at 200 dpi
		canvas.height = 2339;
		const ctx = canvas.getContext('2d')!;
		ctx.fillStyle = '#fff';
		ctx.fillRect(0, 0, canvas.width, canvas.height);
		ctx.fillStyle = '#000';
		ctx.font = '64px "DejaVu Sans", Arial, Helvetica, sans-serif';
		text.forEach((line, i) => ctx.fillText(line, 120, 220 + i * 120));
		return canvas.toDataURL('image/jpeg', 0.92).split(',')[1];
	}, lines);
	return jpegToPdf(Buffer.from(base64, 'base64'), 1654, 2339);
}

/** One A4 page (595 x 842 pt) that shows the JPEG over the whole page. */
export function jpegToPdf(jpeg: Buffer, width: number, height: number): Buffer {
	const chunks: Buffer[] = [];
	const offsets: number[] = [];
	let length = 0;
	const push = (b: Buffer) => {
		chunks.push(b);
		length += b.length;
	};
	const obj = (n: number, body: string | Buffer) => {
		offsets[n] = length;
		push(Buffer.from(`${n} 0 obj\n`, 'latin1'));
		push(typeof body === 'string' ? Buffer.from(body, 'latin1') : body);
		push(Buffer.from('\nendobj\n', 'latin1'));
	};
	push(Buffer.from('%PDF-1.4\n', 'latin1'));
	obj(1, '<< /Type /Catalog /Pages 2 0 R >>');
	obj(2, '<< /Type /Pages /Kids [3 0 R] /Count 1 >>');
	obj(3, '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >>');
	obj(
		4,
		Buffer.concat([
			Buffer.from(`<< /Type /XObject /Subtype /Image /Width ${width} /Height ${height} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length ${jpeg.length} >>\nstream\n`, 'latin1'),
			jpeg,
			Buffer.from('\nendstream', 'latin1')
		])
	);
	const content = 'q 595 0 0 842 0 0 cm /Im0 Do Q';
	obj(5, `<< /Length ${content.length} >>\nstream\n${content}\nendstream`);
	const xref = length;
	let table = 'xref\n0 6\n0000000000 65535 f \n';
	for (let n = 1; n <= 5; n++) table += `${String(offsets[n]).padStart(10, '0')} 00000 n \n`;
	push(Buffer.from(`${table}trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`, 'latin1'));
	return Buffer.concat(chunks);
}
