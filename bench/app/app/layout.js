export const metadata = { title: 'bench app', description: 'tando benchmark workload' };
export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <body style={{ fontFamily: 'system-ui', margin: '2rem' }}>
        <nav><a href="/">home</a> | <a href="/about">about</a> | <a href="/posts/1">post 1</a></nav>
        <main>{children}</main>
      </body>
    </html>
  );
}
