import { describe, expect, it } from "vitest";
import { extractReadableText } from "../src/parser/extractText";

describe("extractReadableText", () => {
	it("strips script and style blocks", () => {
		const html = `
			<html><head><style>body { color: red }</style></head>
			<body>
				<script>console.log('nope')</script>
				<p>Treadmill &amp; Leg Press</p>
			</body></html>
		`;
		const text = extractReadableText(html);
		expect(text).toContain("Treadmill & Leg Press");
		expect(text).not.toContain("console.log");
	});

	it("inserts line breaks at block-level boundaries", () => {
		const html = "<ul><li>ラットプルダウン</li><li>レッグプレス</li></ul>";
		const text = extractReadableText(html);
		expect(text.split("\n")).toEqual(
			expect.arrayContaining(["ラットプルダウン", "レッグプレス"]),
		);
	});

	it("decodes numeric entities", () => {
		const html = "<p>&#x30E9;&#x30C3;&#x30C8;</p>";
		expect(extractReadableText(html)).toBe("ラット");
	});
});
