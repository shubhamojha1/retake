// Live updates of one video job over the Phoenix socket (api/lib/retake_web/channels/video_channel.ex).

import { Socket } from 'phoenix'

import type { Progress, Video } from './types.ts'

// One socket for the whole page; it reconnects by itself, and every channel joins again, which
// makes the server send the whole job once more.
let socket: Socket | null = null

function connection(): Socket {
  if (!socket) {
    socket = new Socket('/socket')
    socket.connect()
  }
  return socket
}

export interface VideoWatcher {
  /** The whole job: after joining, and when its status changes. */
  onVideo: (video: Video) => void
  /** The whole progress map, each time the server writes it. */
  onProgress: (progress: Progress) => void
  /** The server refused the join (no such video). */
  onRefused: (reason: string) => void
}

/** Starts watching a video; returns the function that stops. */
export function watchVideo(id: string, watcher: VideoWatcher): () => void {
  const channel = connection().channel(`video:${id}`)

  channel.on('video', (message: { data: Video }) => watcher.onVideo(message.data))
  channel.on('progress', (message: { progress: Progress }) => watcher.onProgress(message.progress))
  channel.join().receive('error', (reply: { reason?: string }) => watcher.onRefused(reply.reason ?? 'refused'))

  return () => {
    channel.leave()
  }
}
