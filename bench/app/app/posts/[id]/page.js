export const dynamic = 'force-dynamic';
export default async function Post({ params }) {
  const { id } = await params;
  const now = new Date().toISOString();
  return <div><h1>Post {id}</h1><p>Rendered at {now}</p></div>;
}
