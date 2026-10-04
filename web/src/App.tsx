import Rail from './components/Rail.tsx'
import { useRoute } from './hooks/useRoute.ts'
import { useVideo } from './hooks/useVideo.ts'
import { href } from './lib/route.ts'
import Create from './screens/Create.tsx'
import Generating from './screens/Generating.tsx'
import Projects from './screens/Projects.tsx'
import Result from './screens/Result.tsx'

/** One video: while it is made (or if it failed) the live steps, once it is done the result. */
function VideoPage({ id }: { id: string }) {
  const { video, problem } = useVideo(id)

  if (problem) {
    return (
      <div className="mx-auto max-w-[1120px] px-6 py-12 md:px-10">
        <p role="alert" className="rounded-xl border border-warn/40 bg-warn-bg px-4 py-3 text-sm text-warn">
          {problem}
        </p>
        <a href={href.create} className="mt-4 inline-block text-sm text-accent hover:underline">
          Make a video
        </a>
      </div>
    )
  }

  if (!video) return <p className="px-6 py-12 text-sm text-muted md:px-10">Loading…</p>

  return video.status === 'succeeded' ? <Result video={video} /> : <Generating video={video} />
}

export default function App() {
  const route = useRoute()

  return (
    <div className="flex min-h-screen flex-col md:flex-row">
      <Rail route={route} />
      <main className="min-w-0 flex-1 pb-20 md:pb-0">
        {route.name === 'create' && <Create />}
        {route.name === 'projects' && <Projects />}
        {route.name === 'video' && <VideoPage key={route.id} id={route.id} />}
      </main>
    </div>
  )
}
