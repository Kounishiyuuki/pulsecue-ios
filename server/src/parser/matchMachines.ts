import { MACHINE_CATALOG, type MachineId } from "./machines";

/**
 * One detected machine candidate. `confidence` is a heuristic score in
 * the inclusive range [0, 1] that combines the number of distinct
 * aliases that matched and how often they appeared.
 */
export interface MachineCandidate {
	id: MachineId;
	name: MachineId;
	matchedText: string;
	confidence: number;
}

interface FlatAlias {
	id: MachineId;
	alias: string;
	normalized: string;
}

type AccumulatedMatch = {
	id: MachineId;
	aliases: Set<string>;
	occurrences: number;
	firstMatchedText: string;
};

const FLAT_ALIASES: FlatAlias[] = MACHINE_CATALOG.flatMap((entry) =>
	entry.aliases.map((alias) => ({
		id: entry.id,
		alias,
		normalized: normalize(alias),
	})),
)
	// Longest aliases first so that "Lat Pulldown" beats a generic
	// "Pulldown" match for the same span.
	.sort((a, b) => b.normalized.length - a.normalized.length);

/**
 * Scans `text` for any known machine alias and returns one candidate
 * per machine id (deduplicated). The same character span is consumed
 * at most once, so overlapping aliases do not double-count.
 */
export function matchMachines(text: string): MachineCandidate[] {
	if (!text.trim()) return [];

	const normalizedText = normalize(text);
	const consumed = new Uint8Array(normalizedText.length);
	const matches = new Map<MachineId, AccumulatedMatch>();

	for (const { id, alias, normalized } of FLAT_ALIASES) {
		if (normalized.length === 0) continue;
		let cursor = 0;
		while (cursor <= normalizedText.length - normalized.length) {
			const found = normalizedText.indexOf(normalized, cursor);
			if (found === -1) break;
			const end = found + normalized.length;
			if (!isSpanFree(consumed, found, end)) {
				cursor = found + 1;
				continue;
			}
			markConsumed(consumed, found, end);

			const existing = matches.get(id);
			if (existing) {
				existing.aliases.add(alias);
				existing.occurrences += 1;
			} else {
				matches.set(id, {
					id,
					aliases: new Set([alias]),
					occurrences: 1,
					firstMatchedText: alias,
				});
			}
			cursor = end;
		}
	}

	return Array.from(matches.values())
		.map((match) => ({
			id: match.id,
			name: match.id,
			matchedText: match.firstMatchedText,
			confidence: scoreConfidence(match),
		}))
		.sort((a, b) => b.confidence - a.confidence || a.id.localeCompare(b.id));
}

function scoreConfidence(match: AccumulatedMatch): number {
	const aliasBonus = (match.aliases.size - 1) * 0.1;
	const occurrenceBonus = Math.min(0.2, (match.occurrences - 1) * 0.05);
	const score = 0.6 + aliasBonus + occurrenceBonus;
	return clamp(round2(score), 0.5, 0.95);
}

function isSpanFree(buffer: Uint8Array, start: number, end: number): boolean {
	for (let i = start; i < end; i += 1) {
		if (buffer[i] === 1) return false;
	}
	return true;
}

function markConsumed(buffer: Uint8Array, start: number, end: number): void {
	for (let i = start; i < end; i += 1) {
		buffer[i] = 1;
	}
}

function clamp(value: number, lower: number, upper: number): number {
	return Math.min(upper, Math.max(lower, value));
}

function round2(value: number): number {
	return Math.round(value * 100) / 100;
}

/**
 * Lower-cases ASCII, applies NFKC so that full-width Latin/halfwidth
 * Katakana collapse to a single form, and folds whitespace runs so
 * "Lat   Pulldown" still matches "Lat Pulldown".
 */
function normalize(input: string): string {
	return input.normalize("NFKC").toLowerCase().replace(/\s+/g, " ").trim();
}
