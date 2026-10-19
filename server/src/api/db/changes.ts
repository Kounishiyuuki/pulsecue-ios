/**
 * Reads how many rows a write statement changed, from D1's `run()` result.
 *
 * Throws rather than guessing 0 when the shape is not what D1 returns: a
 * cleanup that silently reported "nothing deleted" would hide a broken sweep.
 */
export function changedRows(result: unknown): number {
	const changes = (result as { meta?: { changes?: unknown } } | null)?.meta
		?.changes;
	if (typeof changes !== "number") {
		throw new Error("write result did not report meta.changes");
	}
	return changes;
}
