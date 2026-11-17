import { VERSION } from '../lib/version';
const items = Array.from({ length: 50 }, (_, i) => ({ id: i + 1, title: `Item ${i + 1}` }));
export default function Home() {
  return (
    <div>
      <h1>Bench app {VERSION}</h1>
      <img src="/logo.svg" alt="logo" width="64" height="64" />
      <ul>{items.map((it) => <li key={it.id}><a href={`/posts/${it.id}`}>{it.title}</a></li>)}</ul>
    </div>
  );
}
