import VideoCard from '../components/VideoCard.tsx'
import { useVideos } from '../hooks/useVideo.ts'
import { href } from '../lib/route.ts'

export default function Projects() {
  const { videos, problem } = useVideos(100)

  return (
    <div className="mx-auto w-full max-w-[1120px] px-6 py-12 md:px-10">
      <h1 className="text-[32px] leading-tight font-semibold tracking-[-0.025em]">Projects</h1>

      {problem && (
        <p role="alert" className="mt-6 rounded-xl border border-warn/40 bg-warn-bg px-4 py-3 text-[13px] text-warn">
          {problem}
        </p>
      )}

      {videos && videos.length === 0 && (
        <p className="mt-6 text-sm text-muted">
          No videos yet.{' '}
          <a href={href.create} className="text-accent hover:underline">
            Make the first one.
          </a>
        </p>
      )}

      <div className="mt-8 flex flex-wrap gap-5">
        {videos?.map((video) => (
          <VideoCard key={video.id} video={video} />
        ))}
      </div>
    </div>
  )
}
