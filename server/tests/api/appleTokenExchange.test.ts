import { describe, expect, it } from "vitest";
import { APPLE_ISSUER } from "../../src/api/auth/apple";
import { base64urlDecode } from "../../src/api/auth/jwt";
import {
	AppleExchangeError,
	exchangeAppleAuthorizationCode,
	revokeAppleRefreshToken,
} from "../../src/api/auth/appleTokenExchange";
import { StaticJwksProvider } from "../../src/api/auth/jwks";
import { createTestSigner } from "./support/testSigner";
import {
	TEST_APPLE_CLIENT_ID,
	appleErrorResponse,
	appleTokenResponse,
	createTestAppleSigningKey,
	fakeAppleEndpoint,
} from "./support/appleProduction";

const NOW = 1_800_000_100;
const SUBJECT = "000123.abcdef.1234";

async function exchangeWith(
	responder: Parameters<typeof fakeAppleEndpoint>[0],
	overrides: {
		expectedSubject?: string;
		jwks?: StaticJwksProvider;
		code?: string;
	} = {},
) {
	const key = await createTestAppleSigningKey();
	const endpoint = fakeAppleEndpoint(responder);
	const result = exchangeAppleAuthorizationCode({
		authorizationCode: overrides.code ?? "test-authorization-code",
		config: key.config,
		expectedSubject: overrides.expectedSubject ?? SUBJECT,
		jwks: overrides.jwks ?? new StaticJwksProvider([]),
		fetchImpl: endpoint.fetchImpl,
		now: NOW,
	});
	return { result, endpoint, key };
}

describe("exchanging the authorization code", () => {
	it("returns the refresh token Apple issued", async () => {
		const { result } = await exchangeWith(() => appleTokenResponse());
		await expect(result).resolves.toMatchObject({
			refreshToken: "test-refresh-token",
			expiresIn: 3600,
		});
	});

	it("posts to Apple's fixed token endpoint and nowhere else", async () => {
		// The URL is a module constant. Nothing from the request reaches
		// `fetch`, so a caller cannot steer an outbound call.
		const { result, endpoint } = await exchangeWith(() => appleTokenResponse());
		await result;

		expect(endpoint.requests).toHaveLength(1);
		expect(endpoint.requests[0]?.url).toBe("https://appleid.apple.com/auth/token");
	});

	it("sends the grant Apple documents, with a freshly signed client secret", async () => {
		const { result, endpoint } = await exchangeWith(() => appleTokenResponse());
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

describe("revoking a refresh token", () => {
	it("posts to Apple's fixed revoke endpoint with the token hint", async () => {
		const key = await createTestAppleSigningKey();
		const endpoint = fakeAppleEndpoint(() => new Response("", { status: 200 }));

		const outcome = await revokeAppleRefreshToken({
			refreshToken: "stored-refresh-token",
			config: key.config,
			fetchImpl: endpoint.fetchImpl,
			now: NOW,
		});

		expect(outcome).toEqual({ status: "revoked" });
		expect(endpoint.requests[0]?.url).toBe("https://appleid.apple.com/auth/revoke");
		expect(endpoint.requests[0]?.form.token).toBe("stored-refresh-token");
		expect(endpoint.requests[0]?.form.token_type_hint).toBe("refresh_token");
	});

	it("treats a token Apple has already forgotten as done", async () => {
		const key = await createTestAppleSigningKey();
		const endpoint = fakeAppleEndpoint(() => appleErrorResponse("invalid_grant"));

		await expect(
			revokeAppleRefreshToken({
				refreshToken: "t",
				config: key.config,
				fetchImpl: endpoint.fetchImpl,
				now: NOW,
			}),
		).resolves.toEqual({ status: "alreadyInvalid" });
	});

	it("never reports an outage as a successful revocation", async () => {
		// Recording a revocation that did not happen is exactly the failure
		// Apple's requirement exists to prevent.
		const key = await createTestAppleSigningKey();
		for (const responder of [
			() => new Response("", { status: 503 }),
			() => appleErrorResponse("invalid_client"),
		]) {
			const endpoint = fakeAppleEndpoint(responder);
			await expect(
				revokeAppleRefreshToken({
					refreshToken: "t",
					config: key.config,
					fetchImpl: endpoint.fetchImpl,
					now: NOW,
				}),
			).resolves.toEqual({ status: "unavailable" });
		}
	});

	it("reports unavailable when the client secret cannot be signed", async () => {
		const key = await createTestAppleSigningKey({ privateKeyPem: "" });
		const endpoint = fakeAppleEndpoint(() => new Response("", { status: 200 }));

		await expect(
			revokeAppleRefreshToken({
				refreshToken: "t",
				config: key.config,
				fetchImpl: endpoint.fetchImpl,
				now: NOW,
			}),
		).resolves.toEqual({ status: "unavailable" });
		// And it did not reach Apple at all.
		expect(endpoint.requests).toHaveLength(0);
	});
});
