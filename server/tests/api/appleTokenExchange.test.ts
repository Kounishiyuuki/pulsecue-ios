import { describe, expect, it } from "vitest";
import { APPLE_ISSUER } from "../../src/api/auth/apple";
import { base64urlDecode } from "../../src/api/auth/jwt";
import {
	AppleExchangeError,
	exchangeAppleAuthorizationCode,
	revokeAppleRefreshToken,
} from "../../src/api/auth/appleTokenExchange";
import { StaticJwksProvider } from "../../src/api/auth/jwks";
import { type TestSigner, createTestSigner } from "./support/testSigner";
import {
	TEST_APPLE_CLIENT_ID,
	appleErrorResponse,
	appleTokenResponse,
	appleTokenResponseFor,
	createTestAppleSigningKey,
	fakeAppleEndpoint,
	signExchangeIdToken,
} from "./support/appleProduction";

const NOW = 1_800_000_100;
const SUBJECT = "000123.abcdef.1234";

/**
 * Drives a real exchange against a fake Apple.
 *
 * `responder` receives the signer whose JWKS the verifier is given, so a test
 * can mint an `id_token` that actually verifies — or deliberately one that
 * does not. The default is the happy path: a properly signed `id_token` for
 * the same subject the caller claims to have proved.
 */
async function exchangeWith(
	responder?: (context: {
		signer: TestSigner;
		key: Awaited<ReturnType<typeof createTestAppleSigningKey>>;
	}) => Response | Promise<Response>,
	overrides: {
		expectedSubject?: string;
		jwks?: StaticJwksProvider;
		code?: string;
	} = {},
) {
	const key = await createTestAppleSigningKey();
	const signer = await createTestSigner();
	const endpoint = fakeAppleEndpoint(() =>
		(responder ??
			(({ signer: s, key: k }) =>
				appleTokenResponseFor(s, {
					sub: SUBJECT,
					audience: k.config.clientId,
					now: NOW,
				})))({ signer, key }),
	);
	const result = exchangeAppleAuthorizationCode({
		authorizationCode: overrides.code ?? "test-authorization-code",
		config: key.config,
		expectedSubject: overrides.expectedSubject ?? SUBJECT,
		jwks: overrides.jwks ?? signer.jwks,
		fetchImpl: endpoint.fetchImpl,
		now: NOW,
	});
	return { result, endpoint, key, signer };
}

describe("exchanging the authorization code", () => {
	it("returns the refresh token Apple issued", async () => {
		const { result } = await exchangeWith();
		await expect(result).resolves.toMatchObject({
			refreshToken: "test-refresh-token",
			expiresIn: 3600,
		});
	});

	it("posts to Apple's fixed token endpoint and nowhere else", async () => {
		// The URL is a module constant. Nothing from the request reaches
		// `fetch`, so a caller cannot steer an outbound call.
		const { result, endpoint } = await exchangeWith();
		await result;

		expect(endpoint.requests).toHaveLength(1);
		expect(endpoint.requests[0]?.url).toBe("https://appleid.apple.com/auth/token");
	});

	it("sends the grant Apple documents, with a freshly signed client secret", async () => {
		const { result, endpoint } = await exchangeWith();
		await result;

		const form = endpoint.requests[0]?.form ?? {};
		expect(form.grant_type).toBe("authorization_code");
		expect(form.code).toBe("test-authorization-code");
		expect(form.client_id).toBe(TEST_APPLE_CLIENT_ID);

		// The secret is a real ES256 JWT, not a static string.
		const header = JSON.parse(
			new TextDecoder().decode(
				base64urlDecode((form.client_secret ?? "").split(".")[0] as string),
			),
		);
		expect(header.alg).toBe("ES256");
	});

	it("treats a spent or forged code as a bad credential", async () => {
		const { result } = await exchangeWith(() =>
			appleErrorResponse("invalid_grant"),
		);
		await expect(result).rejects.toMatchObject({ failure: "invalidGrant" });
	});

	it("treats a broken client secret as our problem, not the user's", async () => {
		const { result } = await exchangeWith(() =>
			appleErrorResponse("invalid_client"),
		);
		await expect(result).rejects.toMatchObject({ failure: "invalidClient" });
	});

	it("treats a 5xx as an outage rather than a verdict on the code", async () => {
		const { result } = await exchangeWith(
			() => new Response("upstream boom", { status: 503 }),
		);
		await expect(result).rejects.toMatchObject({
			failure: "providerUnavailable",
		});
	});

	it("treats an unreachable Apple as an outage", async () => {
		const key = await createTestAppleSigningKey();
		await expect(
			exchangeAppleAuthorizationCode({
				authorizationCode: "c",
				config: key.config,
				expectedSubject: SUBJECT,
				jwks: new StaticJwksProvider([]),
				fetchImpl: (async () => {
					throw new Error("network down");
				}) as unknown as typeof fetch,
				now: NOW,
			}),
		).rejects.toMatchObject({ failure: "providerUnavailable" });
	});

	it("does not trust an HTML error page as an OAuth verdict", async () => {
		const { result } = await exchangeWith(
			() => new Response("<html>gateway timeout</html>", { status: 504 }),
		);
		await expect(result).rejects.toMatchObject({
			failure: "providerUnavailable",
		});
	});
});

describe("validating Apple's response", () => {
	it("refuses a response with no refresh token", async () => {
		// Without it there is nothing to revoke at deletion, which is the only
		// reason the exchange happens at all.
		const { result } = await exchangeWith(() =>
			appleTokenResponse({ refresh_token: undefined }),
		);
		await expect(result).rejects.toMatchObject({ failure: "malformedResponse" });
	});

	it("refuses an empty or non-string refresh token", async () => {
		for (const refresh_token of ["", 42, null, ["a"]]) {
			const { result } = await exchangeWith(() =>
				appleTokenResponse({ refresh_token }),
			);
			await expect(result).rejects.toBeInstanceOf(AppleExchangeError);
		}
	});

	it("refuses an unexpected token type", async () => {
		const { result } = await exchangeWith(() =>
			appleTokenResponse({ token_type: "mac" }),
		);
		await expect(result).rejects.toMatchObject({ failure: "malformedResponse" });
	});

	it("refuses a body that is not JSON, or not an object", async () => {
		for (const body of ["not json", "[1,2,3]", "null", '"a string"']) {
			const { result } = await exchangeWith(
				() => new Response(body, { status: 200 }),
			);
			await expect(result).rejects.toMatchObject({
				failure: "malformedResponse",
			});
		}
	});

	it("refuses an empty 200 from the token endpoint", async () => {
		const { result } = await exchangeWith(
			() => new Response("", { status: 200 }),
		);
		await expect(result).rejects.toMatchObject({ failure: "malformedResponse" });
	});
});

describe("the id_token Apple returns alongside", () => {
	async function withIdToken(
		claims: Record<string, unknown>,
		options: { expectedSubject?: string; signWithOther?: boolean } = {},
	) {
		const signer = await createTestSigner();
		const other = await createTestSigner(signer.kid);
		const idToken = await (options.signWithOther ? other : signer).sign({
			iss: APPLE_ISSUER,
			aud: TEST_APPLE_CLIENT_ID,
			sub: SUBJECT,
			iat: NOW - 10,
			exp: NOW + 600,
			...claims,
		});
		return exchangeWith(() => appleTokenResponse({ id_token: idToken }), {
			expectedSubject: options.expectedSubject,
			jwks: signer.jwks,
		});
	}

	it("accepts one that agrees with the identity token already proved", async () => {
		const { result } = await withIdToken({});
		await expect(result).resolves.toMatchObject({
			refreshToken: "test-refresh-token",
		});
	});

	it("refuses when it names a different subject", async () => {
		// The attack: pair a victim's authorization code with the attacker's
		// own identity token. Nothing is stored and no session is issued.
		const { result } = await withIdToken({ sub: "999999.someone.else" });
		await expect(result).rejects.toMatchObject({ failure: "subjectMismatch" });
	});

	it("refuses one it cannot verify", async () => {
		const cases: Array<Record<string, unknown>> = [
			{ iss: "https://accounts.google.com" },
			{ aud: "com.someone.else" },
			{ exp: NOW - 3600 },
			{ sub: undefined },
		];
		for (const claims of cases) {
			const { result } = await withIdToken(claims);
			await expect(result).rejects.toBeInstanceOf(AppleExchangeError);
		}
	});

	it("refuses one signed by the wrong key", async () => {
		const { result } = await withIdToken({}, { signWithOther: true });
		await expect(result).rejects.toMatchObject({ failure: "malformedResponse" });
	});

	it("refuses an id_token that is not a string", async () => {
		const { result } = await exchangeWith(() =>
			appleTokenResponse({ id_token: 12345 }),
		);
		await expect(result).rejects.toMatchObject({ failure: "malformedResponse" });
	});
});

describe("nothing leaks", () => {
	it("keeps the code, the secret and the token out of every error", async () => {
		const key = await createTestAppleSigningKey();
		const endpoint = fakeAppleEndpoint(() =>
			appleErrorResponse("invalid_grant"),
		);
		const error = await exchangeAppleAuthorizationCode({
			authorizationCode: "secret-authorization-code",
			config: key.config,
			expectedSubject: SUBJECT,
			jwks: new StaticJwksProvider([]),
			fetchImpl: endpoint.fetchImpl,
			now: NOW,
		}).catch((e: Error) => e);

		const text = `${String(error)} ${(error as Error).stack ?? ""}`;
		expect(text).not.toContain("secret-authorization-code");
		expect(text).not.toContain(key.config.privateKeyPem.slice(40, 80));
		expect(text).not.toContain(endpoint.requests[0]?.form.client_secret ?? "@@");
	});

	it("does not echo Apple's error body", async () => {
		const { result } = await exchangeWith(
			() =>
				new Response(
					JSON.stringify({ error: "invalid_grant", error_description: "sensitive detail" }),
					{ status: 400 },
				),
		);
		const error = await result.catch((e: Error) => e);
		expect(String(error)).not.toContain("sensitive detail");
	});
});

describe("the id_token is required, not optional", () => {
	it("refuses a success response that omits id_token entirely", async () => {
		// Treating it as optional means an attacker who can suppress it — or
		// an Apple response shape nobody expected — skips the only check that
		// proves this code belonged to the person whose identity token arrived
		// with it. Make it optional again and this fails.
		const { result } = await exchangeWith(() => appleTokenResponse());
		await expect(result).rejects.toMatchObject({ failure: "malformedResponse" });
	});

	it("refuses an empty or non-string id_token", async () => {
		for (const id_token of ["", 12345, null, ["a"], { a: 1 }]) {
			const { result } = await exchangeWith(() =>
				appleTokenResponse({ id_token }),
			);
			await expect(result).rejects.toMatchObject({
				failure: "malformedResponse",
			});
		}
	});

	it("refuses a malformed id_token", async () => {
		for (const id_token of ["not.a.jwt", "onlyonesegment", "a.b"]) {
			const { result } = await exchangeWith(() =>
				appleTokenResponse({ id_token }),
			);
			await expect(result).rejects.toMatchObject({
				failure: "malformedResponse",
			});
		}
	});

	it("refuses one signed by a key Apple does not publish", async () => {
		const { result } = await exchangeWith(async ({ signer, key }) => {
			const impostor = await createTestSigner(signer.kid);
			return appleTokenResponse({
				id_token: await signExchangeIdToken(impostor, {
					sub: SUBJECT,
					audience: key.config.clientId,
					now: NOW,
				}),
			});
		});
		await expect(result).rejects.toMatchObject({ failure: "malformedResponse" });
	});

	it("refuses a wrong issuer, audience, expiry or missing sub", async () => {
		const bad: Array<[string, Record<string, unknown>]> = [
			["issuer", { iss: "https://accounts.google.com" }],
			["audience", { aud: "com.someone.else" }],
			["expired", { exp: NOW - 3600 }],
			["missing sub", { sub: undefined }],
			["empty sub", { sub: "" }],
			["non-string sub", { sub: 12345 }],
		];
		for (const [label, overrides] of bad) {
			const { result } = await exchangeWith(({ signer, key }) =>
				appleTokenResponseFor(signer, {
					sub: SUBJECT,
					audience: key.config.clientId,
					now: NOW,
					idTokenOverrides: overrides,
				}),
			);
			await expect(result, label).rejects.toMatchObject({
				failure: "malformedResponse",
			});
		}
	});

	it("does NOT demand a nonce on the exchange id_token", async () => {
		// Apple does not put one there — that request is authenticated by the
		// client secret. Requiring one would reject every real exchange.
		const { result } = await exchangeWith(({ signer, key }) =>
			appleTokenResponseFor(signer, {
				sub: SUBJECT,
				audience: key.config.clientId,
				now: NOW,
			}),
		);
		await expect(result).resolves.toMatchObject({ verifiedSubject: SUBJECT });
	});
});

describe("subject binding between the two tokens", () => {
	it("accepts only an exact match", async () => {
		const { result } = await exchangeWith(undefined, {
			expectedSubject: SUBJECT,
		});
		await expect(result).resolves.toMatchObject({ verifiedSubject: SUBJECT });
	});

	it("refuses any mismatch, however small", async () => {
		// The attack: pair a victim's authorization code with the attacker's
		// own identity token. Nothing is stored and no session is issued.
		for (const claimed of [
			"000123.abcdef.9999",
			"000123.abcdef.1234 ",
			"000123.ABCDEF.1234",
			"000123.abcdef.123",
			"",
		]) {
			const { result } = await exchangeWith(undefined, {
				expectedSubject: claimed,
			});
			await expect(result, claimed).rejects.toBeInstanceOf(AppleExchangeError);
		}
	});

	it("reports a mismatch distinctly from a malformed response", async () => {
		const { result } = await exchangeWith(undefined, {
			expectedSubject: "someone-else",
		});
		await expect(result).rejects.toMatchObject({ failure: "subjectMismatch" });
	});
});

describe("revoking a refresh token — success is HTTP 2xx and nothing else", () => {
	async function revokeWith(responder: Parameters<typeof fakeAppleEndpoint>[0]) {
		const key = await createTestAppleSigningKey();
		const endpoint = fakeAppleEndpoint(responder);
		const outcome = await revokeAppleRefreshToken({
			refreshToken: "stored-refresh-token",
			config: key.config,
			fetchImpl: endpoint.fetchImpl,
			now: NOW,
		});
		return { outcome, endpoint };
	}

	it("posts to Apple's fixed revoke endpoint with the token hint", async () => {
		const { outcome, endpoint } = await revokeWith(
			() => new Response("", { status: 200 }),
		);

		expect(outcome).toEqual({ status: "revoked" });
		expect(endpoint.requests[0]?.url).toBe("https://appleid.apple.com/auth/revoke");
		expect(endpoint.requests[0]?.form.token).toBe("stored-refresh-token");
		expect(endpoint.requests[0]?.form.token_type_hint).toBe("refresh_token");
	});

	it("accepts any 2xx, not just 200", async () => {
		for (const status of [200, 201, 204]) {
			const { outcome } = await revokeWith(
				() => new Response(status === 204 ? null : "", { status }),
			);
			expect(outcome, `status ${status}`).toEqual({ status: "revoked" });
		}
	});

	it("does NOT treat a 400 invalid_grant as already revoked", async () => {
		// This is the regression that matters. `invalid_grant` from the revoke
		// endpoint can equally mean the token belongs to a different client or
		// that the request was malformed — it is not evidence the token is
		// gone. Apple answers 2xx when it accepts a revoke, including for a
		// token it has already forgotten, so nothing is lost by refusing to
		// infer success from an error body.
		//
		// Restore the old `invalid_grant → alreadyInvalid → revoked` path and
		// this fails.
		const { outcome } = await revokeWith(() => appleErrorResponse("invalid_grant"));
		expect(outcome).toEqual({ status: "rejected" });
		expect(outcome.status).not.toBe("revoked");
	});

	it("treats every other 4xx as rejected, never revoked", async () => {
		const cases: Array<[number, Response]> = [
			[400, appleErrorResponse("invalid_request")],
			[400, appleErrorResponse("invalid_client")],
			[401, appleErrorResponse("invalid_client", 401)],
			[403, new Response("forbidden", { status: 403 })],
			[404, new Response("", { status: 404 })],
			[429, new Response("slow down", { status: 429 })],
		];
		for (const [label, response] of cases) {
			const { outcome } = await revokeWith(() => response.clone());
			expect(outcome, `status ${label}`).toEqual({ status: "rejected" });
		}
	});

	it("treats a 5xx as a service failure whatever the body claims", async () => {
		// A 500 carrying an `invalid_grant` body is still an outage. Reading
		// the code out of it would turn a bad minute at Apple into a permanent
		// "this token is gone".
		for (const response of [
			() => appleErrorResponse("invalid_grant", 500),
			() => appleErrorResponse("invalid_client", 502),
			() => new Response("", { status: 503 }),
			() => new Response("<html>gateway</html>", { status: 504 }),
		]) {
			const { outcome } = await revokeWith(response);
			expect(outcome).toEqual({ status: "retryable" });
		}
	});

	it("treats a malformed error body as a failure, not a success", async () => {
		for (const body of ["not json", "[1,2,3]", "", "null"]) {
			const { outcome } = await revokeWith(
				() => new Response(body, { status: 400 }),
			);
			expect(outcome).toEqual({ status: "rejected" });
		}
	});

	it("treats an unreachable Apple as retryable", async () => {
		const key = await createTestAppleSigningKey();
		const outcome = await revokeAppleRefreshToken({
			refreshToken: "t",
			config: key.config,
			fetchImpl: (async () => {
				throw new Error("network down");
			}) as unknown as typeof fetch,
			now: NOW,
		});
		expect(outcome).toEqual({ status: "retryable" });
	});

	it("reports retryable when the client secret cannot be signed", async () => {
		const key = await createTestAppleSigningKey({ privateKeyPem: "" });
		const endpoint = fakeAppleEndpoint(() => new Response("", { status: 200 }));

		const outcome = await revokeAppleRefreshToken({
			refreshToken: "t",
			config: key.config,
			fetchImpl: endpoint.fetchImpl,
			now: NOW,
		});

		expect(outcome).toEqual({ status: "retryable" });
		// And it never reached Apple.
		expect(endpoint.requests).toHaveLength(0);
	});

	it("never returns revoked for any non-2xx status", async () => {
		// The invariant stated directly, swept across the range.
		for (const status of [400, 401, 403, 404, 409, 429, 500, 502, 503, 504]) {
			const { outcome } = await revokeWith(
				() => new Response(JSON.stringify({ error: "invalid_grant" }), { status }),
			);
			expect(outcome.status, `status ${status}`).not.toBe("revoked");
		}
	});
});
