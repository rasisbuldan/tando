import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
const dir = fileURLToPath(new URL("../../../../../test/fixtures/json/", import.meta.url));
export const fixture = <T = any>(name: string): T => JSON.parse(readFileSync(dir + name + ".sample.json", "utf8")); // eslint-disable-line @typescript-eslint/no-explicit-any
