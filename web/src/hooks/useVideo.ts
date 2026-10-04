import { useEffect, useState } from 'react'

import { ApiError, getVideo, listVideos } from '../lib/api.ts'
import { watchVideo } from '../lib/socket.ts'
import type { Video } from '../lib/types.ts'

const wordsFor = (error: unknown): string =>
  error instanceof ApiError ? error.problems.join(' ') : 'Something went wrong.'

/**
 * One video, kept up to date while the page is open: loaded once, then replaced by what the
 * server pushes (the whole job when it changes, the whole progress map as it moves).
 */
export function useVideo(id: string): { video: Video | null; problem: string | null } {
  const [video, setVideo] = useState<Video | null>(null)
  const [problem, setProblem] = useState<string | null>(null)

  useEffect(() => {
    let open = true
    setVideo(null)
    setProblem(null)

    // A pushed snapshot is newer than the first load, so the load only fills an empty page.
    getVideo(id).then(
      (loaded) => open && setVideo((now) => now ?? loaded),
      (error: unknown) => open && setProblem(wordsFor(error)),
    )

    const stop = watchVideo(id, {
      onVideo: (snapshot) => open && setVideo(snapshot),
      onProgress: (progress) => open && setVideo((now) => (now ? { ...now, progress } : now)),
      onRefused: () => open && setProblem('Video not found.'),
    })

    return () => {
      open = false
      stop()
    }
  }, [id])

  return { video, problem }
}

/** The latest videos, loaded once when the page opens. `videos` is null until they arrive. */
export function useVideos(limit: number): { videos: Video[] | null; problem: string | null } {
  const [videos, setVideos] = useState<Video[] | null>(null)
  const [problem, setProblem] = useState<string | null>(null)

  useEffect(() => {
    let open = true

    listVideos(limit).then(
      (loaded) => open && setVideos(loaded),
      (error: unknown) => open && setProblem(wordsFor(error)),
    )

    return () => {
      open = false
    }
  }, [limit])

  return { videos, problem }
}
