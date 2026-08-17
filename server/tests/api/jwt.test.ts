import { describe, expect, it } from "vitest";
import {
	JwtMalformedError,
	base64urlEncode,
	decodeJwt,
} from "../../src/api/auth/jwt";

/** A token whose segments are whatever JSON the test names. */
function tokenWith(header: string, payload: string): string {
	const encode = (json: string) =>
		base64urlEncode(new TextEncoder().encode(json));
	return `${encode(header)}.${encode(payload)}.c2ln`;
}

describe("decodeJwt payload shape", () => {
	// `JSON.parse` returns whatever the token says, and a payload that is not
	// an object would flow on as if it were a claim set: `claims.iss` on
	// `null` throws a TypeError (a 500, not a 401), and on an array it reads
	// array members. A JWT whose payload is not a JSON object is not a JWT.
	const notObjects: Array<[string, string]> = [
		["null", "null"],
		["an array", '["iss","https://accounts.google.com"]'],
		["an empty array", "[]"],
		["a string", '"not-a-claim-set"'],
		["a number", "12345"],
		["a boolean", "true"],
	];

	for (const [description, payload] of notObjects) {
		it(`rejects a payload that is ${description}`, () => {
			expect(() => decodeJwt(tokenWith('{"alg":"RS256"}', payload))).toThrow(
				JwtMalformedError,
			);
		});
	}

	for (const [description, header] of notObjects) {
		it(`rejects a header that is ${description}`, () => {
			expect(() => decodeJwt(tokenWith(header, '{"sub":"1"}'))).toThrow(
				JwtMalformedError,
			);
		});
	}

	it("still accepts an ordinary object payload", () => {
		const decoded = decodeJwt(
			tokenWith('{"alg":"RS256","kid":"k1"}', '{"sub":"1","iss":"x"}'),
		);
		expect(decoded.header.alg).toBe("RS256");
		expect(decoded.header.kid).toBe("k1");
		expect(decoded.claims.sub).toBe("1");
	});

	it("rejects a header with no alg", () => {
		expect(() => decodeJwt(tokenWith('{"kid":"k1"}', '{"sub":"1"}'))).toThrow(
			JwtMalformedError,
		);
	});

	it("throws JwtMalformedError, never a raw TypeError", () => {
		// The type is what the routes map to 401. Anything else becomes a 500
		// and tells the caller they found a crash.
		for (const [, payload] of notObjects) {
			try {
				decodeJwt(tokenWith('{"alg":"RS256"}', payload));
				throw new Error("should not have decoded");
			} catch (error) {
				expect(error).toBeInstanceOf(JwtMalformedError);
			}
		}
	});
});
