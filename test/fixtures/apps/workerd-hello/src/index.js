import { tag } from "./util.js";

export default {
  async fetch(request, env) {
    const path = new URL(request.url).pathname;
    if (path === "/health") return new Response("ok");
    if (path === "/env") return new Response(env.GREETING === undefined ? "unset" : env.GREETING);
    return new Response(tag);
  },
};
