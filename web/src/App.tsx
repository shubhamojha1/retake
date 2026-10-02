import { formatDuration } from './lib/format.ts'

export default function App() {
  return (
    <main className="mx-auto max-w-xl p-8">
      <h1 className="text-2xl font-semibold">Retake</h1>
      <p className="mt-2 text-sm text-neutral-500">
        Prompt to video. Target length {formatDuration(30_000)}.
      </p>
    </main>
  )
}
