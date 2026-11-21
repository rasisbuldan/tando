// a workspace package: its code (and its own dependency, ms) must be in the release
const ms = require("ms");
exports.greet = (who) => `hello ${who} from the greet package (${ms(60000)})`;
