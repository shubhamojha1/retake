// The API (api/lib/retake_web/controllers/video_controller.ex), as functions.

import type { BriefBody } from './brief.ts'
import type { Video } from './types.ts'

/** A request the server refused, or could not answer: `problems` are sentences for the user. */
export class ApiError extends Error {
  status: number
  problems: string[]

  constructor(status: number, problems: string[]) {
    super(problems.join(' '))
    this.status = status
    this.problems = problems
  }
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  let response: Response
  try {
    response = await fetch(path, init)
  } catch {
    throw new ApiError(0, ['Cannot reach the server. Is it running?'])
  }

  if (!response.ok) {
    const body: { errors?: string[] } = await response.json().catch(() => ({}))
    throw new ApiError(response.status, body.errors ?? [`The server answered ${response.status}.`])
  }

  const body: { data: T } = await response.json()
  return body.data
}

/** Asks for a video. It is made in the background: the answer is the job, still queued. */
export function createVideo(brief: BriefBody): Promise<Video> {
  return request<Video>('/api/videos', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(brief),
  })
}

export function getVideo(id: string): Promise<Video> {
  return request<Video>(`/api/videos/${encodeURIComponent(id)}`)
}

/** The latest jobs, newest first, without their specs. */
export function listVideos(limit = 20): Promise<Video[]> {
  return request<Video[]>(`/api/videos?limit=${limit}`)
}
