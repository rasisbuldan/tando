export function SessionEnded() {
  return (
    <div role="alert" className="grid min-h-screen place-items-center bg-background p-4 text-center">
      <div>
        <h1 className="m-0 mb-2 text-xl leading-7 font-semibold">Session ended</h1>
        <p className="m-0 text-[14px] text-muted-foreground">Open the dashboard again with <code>tando-dash</code>.</p>
      </div>
    </div>
  );
}
