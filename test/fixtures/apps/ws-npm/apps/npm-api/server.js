const express = require("express");
const { greet } = require("@fixture/greet");
const app = express();
app.get("/", (req, res) => res.send(greet("npm workspace")));
app.get("/health", (req, res) => res.send("ok"));
app.listen(process.env.PORT || 3000);
