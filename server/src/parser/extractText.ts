/**
 * Minimal HTML → readable text extractor for the gym machine import
 * parser. Strips script/style blocks, decodes common entities, and
 * collapses whitespace. This is intentionally lightweight; it does
 * not execute JavaScript or render the DOM. Pages that ship machine
 * lists only via JS will not be parsed accurately — surfaced as a
 * warning by the caller.
 */

const BLOCK_TAGS_RE =
	/<(script|style|noscript|template|svg|head)[\s\S]*?<\/\1\s*>/gi;
const BR_LIKE_TAGS_RE = /<(br|hr)\b[^>]*\/?>/gi;
const CLOSING_BLOCK_LEVEL_TAGS_RE =
	/<\/(p|div|section|article|header|footer|main|aside|li|ul|ol|h[1-6]|tr|td|th|table|nav|figure|figcaption|details|summary)\s*>/gi;
const ANY_TAG_RE = /<[^>]+>/g;
const NUMERIC_ENTITY_RE = /&#(x?[0-9a-f]+);/gi;
const NAMED_ENTITIES: Record<string, string> = {
	amp: "&",
	lt: "<",
	gt: ">",
	quot: '"',
	apos: "'",
	nbsp: " ",
	copy: "©",
	reg: "®",
	trade: "™",
	hellip: "…",
	mdash: "—",
	ndash: "–",
	yen: "¥",
};

export function extractReadableText(html: string): string {
	const stripped = html
		.replace(BLOCK_TAGS_RE, " ")
		.replace(BR_LIKE_TAGS_RE, "\n")
		.replace(CLOSING_BLOCK_LEVEL_TAGS_RE, "\n")
		.replace(ANY_TAG_RE, " ");

	const decoded = decodeEntities(stripped);

	return decoded
		.split(/\r?\n/)
		.map((line) => line.replace(/\s+/g, " ").trim())
		.filter((line) => line.length > 0)
		.join("\n");
}

function decodeEntities(input: string): string {
	return input
		.replace(NUMERIC_ENTITY_RE, (_, raw: string) => {
			const isHex = raw.startsWith("x") || raw.startsWith("X");
			const codepoint = Number.parseInt(isHex ? raw.slice(1) : raw, isHex ? 16 : 10);
			if (!Number.isFinite(codepoint) || codepoint < 0 || codepoint > 0x10ffff) {
				return "";
			}
			try {
				return String.fromCodePoint(codepoint);
			} catch {
				return "";
			}
		})
		.replace(/&([a-z]+);/gi, (match, name: string) => {
			const replacement = NAMED_ENTITIES[name.toLowerCase()];
			return replacement ?? match;
		});
}
