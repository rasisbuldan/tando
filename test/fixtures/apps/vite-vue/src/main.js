import { createApp, h } from "vue";
import { createRouter, createWebHistory, RouterView } from "vue-router";

const Home = { render: () => h("p", "vite vue home") };
const About = { render: () => h("p", "vite vue about") };
const router = createRouter({
  history: createWebHistory(),
  routes: [{ path: "/", component: Home }, { path: "/about/team", component: About }],
});
createApp({ render: () => h(RouterView) }).use(router).mount("#app");
