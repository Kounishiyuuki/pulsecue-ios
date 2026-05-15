import { Hono } from "hono";
import { requireImportApiKey } from "./auth";
import { healthHandler } from "./routes/health";
import { importGymMachinesHandler } from "./routes/importGymMachines";

const app = new Hono<{ Bindings: Env }>();

app.get("/health", healthHandler);
app.post(
	"/api/gym-machines/import",
	requireImportApiKey,
	importGymMachinesHandler,
);

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
