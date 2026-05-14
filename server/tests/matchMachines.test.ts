import { describe, expect, it } from "vitest";
import { matchMachines } from "../src/parser/matchMachines";

describe("matchMachines", () => {
	it("returns empty candidates for empty input", () => {
		expect(matchMachines("")).toEqual([]);
		expect(matchMachines("   \n  ")).toEqual([]);
	});

	it("matches Japanese aliases", () => {
		const text = "当ジムにはラットプルダウンとレッグプレスがあります。";
		const ids = matchMachines(text).map((c) => c.id);
		expect(ids).toContain("lat_pulldown");
		expect(ids).toContain("leg_press");
	});

	it("matches English aliases case-insensitively", () => {
		const text = "Equipment: Smith Machine, Chest Press, lat pulldown";
		const ids = matchMachines(text).map((c) => c.id);
		expect(ids).toContain("smith_machine");
		expect(ids).toContain("chest_press");
		expect(ids).toContain("lat_pulldown");
	});

	it("dedupes the same machine even when multiple aliases appear", () => {
		const text = "ラットプルダウン Lat Pulldown ラットプル LATプル";
		const matches = matchMachines(text);
		const latMatches = matches.filter((c) => c.id === "lat_pulldown");
		expect(latMatches).toHaveLength(1);
		expect(latMatches[0]?.confidence).toBeGreaterThan(0.6);
	});

	it("does not let a generic alias eclipse a more specific one", () => {
		const text = "Smith Machine and Cable Machine are in zone A.";
		const ids = matchMachines(text).map((c) => c.id);
		expect(ids).toContain("smith_machine");
		expect(ids).toContain("cable_machine");
	});

	it("returns an empty array when no machine is mentioned", () => {
		const text = "ようこそ。フロントに受付がございます。";
		expect(matchMachines(text)).toEqual([]);
	});

	it("preserves the original alias surface form as matchedText", () => {
		const text = "今日のメニュー: シーテッドロー";
		const [first] = matchMachines(text);
		expect(first?.id).toBe("seated_row");
		expect(first?.matchedText).toBe("シーテッドロー");
	});
});
