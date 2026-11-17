import Image from 'next/image';
import { VERSION } from '../version';
export default function Home() {
  return (
    <main>
      <h1>tando next example v{VERSION}</h1>
      <Image src="/demo/pic.png" alt="square" width={64} height={64} />
    </main>
  );
}
