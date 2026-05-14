/**
 * Canonical machine catalog and alias table used by the gym machine
 * import parser. Each entry maps a list of aliases (Japanese + English
 * surface forms) to one canonical machine id. Aliases are matched
 * case-insensitively against normalized text; the longest matching
 * alias wins so that "Smith Machine" is not eclipsed by a generic
 * "Machine" entry.
 */

export type MachineId =
	| "bench_press"
	| "smith_machine"
	| "dumbbells"
	| "cable_machine"
	| "lat_pulldown"
	| "seated_row"
	| "chest_press"
	| "shoulder_press"
	| "leg_press"
	| "leg_extension"
	| "leg_curl"
	| "pec_deck"
	| "back_extension"
	| "pull_up_bar"
	| "treadmill"
	| "bike";

export interface MachineCatalogEntry {
	id: MachineId;
	aliases: string[];
}

export const MACHINE_CATALOG: MachineCatalogEntry[] = [
	{
		id: "bench_press",
		aliases: ["ベンチプレス", "Bench Press", "Flat Bench Press"],
	},
	{
		id: "smith_machine",
		aliases: ["スミスマシン", "Smith Machine"],
	},
	{
		id: "dumbbells",
		aliases: ["ダンベル", "Dumbbells", "Dumbbell"],
	},
	{
		id: "cable_machine",
		aliases: [
			"ケーブルマシン",
			"ケーブル",
			"Cable Machine",
			"Cable Crossover",
			"Cable Station",
		],
	},
	{
		id: "lat_pulldown",
		aliases: [
			"ラットプルダウン",
			"ラットプル",
			"LATプル",
			"Lat Pulldown",
			"Lat Pull-down",
			"Pulldown",
		],
	},
	{
		id: "seated_row",
		aliases: [
			"シーテッドロー",
			"ローイング",
			"ローイングマシン",
			"Seated Row",
			"Rowing Machine",
		],
	},
	{
		id: "chest_press",
		aliases: ["チェストプレス", "Chest Press"],
	},
	{
		id: "shoulder_press",
		aliases: ["ショルダープレス", "Shoulder Press"],
	},
	{
		id: "leg_press",
		aliases: ["レッグプレス", "Leg Press"],
	},
	{
		id: "leg_extension",
		aliases: ["レッグエクステンション", "Leg Extension"],
	},
	{
		id: "leg_curl",
		aliases: ["レッグカール", "Leg Curl"],
	},
	{
		id: "pec_deck",
		aliases: ["ペックデック", "ペックフライ", "Pec Deck", "Pec Fly"],
	},
	{
		id: "back_extension",
		aliases: ["バックエクステンション", "Back Extension"],
	},
	{
		id: "pull_up_bar",
		aliases: [
			"プルアップバー",
			"プルアップ",
			"懸垂バー",
			"懸垂",
			"Pull Up Bar",
			"Pull-up Bar",
			"Chin Up Bar",
		],
	},
	{
		id: "treadmill",
		aliases: [
			"トレッドミル",
			"ランニングマシン",
			"ランニングマシーン",
			"Treadmill",
		],
	},
	{
		id: "bike",
		aliases: [
			"エアロバイク",
			"フィットネスバイク",
			"バイク",
			"Exercise Bike",
			"Stationary Bike",
			"Bike",
		],
	},
];
