const app = require("fastify")();
app.get("/", async () => "fastify fixture");
app.listen({ port: process.env.PORT || 3000, host: "127.0.0.1" });
