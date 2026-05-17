import { Hono } from "hono";
import { requireImportAuthorization } from "./auth";
import { authImportTokenHandler } from "./routes/authImportToken";
import { healthHandler } from "./routes/health";
import { importGymMachinesHandler } from "./routes/importGymMachines";

const app = new Hono<{ Bindings: Env }>();

app.get("/health", healthHandler);
// Accepts either the long-lived PULSECUE_IMPORT_API_KEY (server/admin
// callers) or a short-lived token minted via /api/auth/import-token
// (future iOS clients). See server/src/auth.ts and
// Docs/import-token-endpoint-spec.md.
app.post(
	"/api/gym-machines/import",
	requireImportAuthorization,
	importGymMachinesHandler,
);
// Mint endpoint for short-lived bearer tokens used by the future
// iOS import client. Gated only by a placeholder attestation field
// today; production deployments must enforce real App Attest
// validation before public exposure (see server/README.md and
// Docs/import-token-endpoint-spec.md).
app.post("/api/auth/import-token", authImportTokenHandler);

app.notFound((c) =>
	c.json({ error: { code: "not_found", message: "Route not found" } }, 404),
);

app.onError((err, c) => {
	console.error("unhandled_error", err);
	return c.json(
		{ error: { code: "internal_error", message: "Unexpected server error" } },
		500,
	);
});

export default app;
