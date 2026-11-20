const express = require("express");
const app = express();
app.get("/", (req, res) => res.send("fixed port"));
app.listen(8000);
