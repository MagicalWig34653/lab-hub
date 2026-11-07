/** Search snippet marker characters (contract `DmsSearchHit.snippet`): private-use code points, not HTML. */
export const MARK_START = '';
export const MARK_END = '';

export interface SnippetPart {
	text: string;
	mark: boolean;
}

/**
 * Splits a snippet at the markers into plain text parts. The parts are rendered as text nodes (`<mark>{text}</mark>`),
 * never as HTML, so markup inside a document text stays inert. Unbalanced markers are tolerated.
 */
export function parseSnippet(snippet: string | null | undefined): SnippetPart[] {
	if (!snippet) return [];
	const parts: SnippetPart[] = [];
	let mark = false;
	let buffer = '';
	const flush = () => {
		if (buffer) parts.push({ text: buffer, mark });
		buffer = '';
	};
	for (const char of snippet) {
		if (char === MARK_START) {
			flush();
			mark = true;
		} else if (char === MARK_END) {
			flush();
			mark = false;
		} else {
			buffer += char;
		}
	}
	flush();
	return parts;
}
