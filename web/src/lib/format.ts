/** Milliseconds as m:ss, rounded down to whole seconds. */
export function formatDuration(ms: number): string {
  const total = Math.max(0, Math.floor(ms / 1000))
  const minutes = Math.floor(total / 60)
  const seconds = total % 60
  return `${minutes}:${String(seconds).padStart(2, '0')}`
}

/** A stretch of the video: "0:07–0:15". */
export function formatRange(startMs: number, endMs: number): string {
  return `${formatDuration(startMs)}–${formatDuration(endMs)}`
}

/** How long ago, in words: "just now", "5 min ago", "3 h ago", "yesterday", "4 days ago". */
export function timeAgo(iso: string, now: Date = new Date()): string {
  const then = new Date(iso).getTime()
  if (Number.isNaN(then)) return ''

  const seconds = Math.max(0, Math.floor((now.getTime() - then) / 1000))
  if (seconds < 60) return 'just now'

  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) return `${minutes} min ago`

  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours} h ago`

  const days = Math.floor(hours / 24)
  return days === 1 ? 'yesterday' : `${days} days ago`
}

/** One line of at most `max` characters, cut with an ellipsis. */
export function shorten(text: string, max: number): string {
  const line = text.trim().replace(/\s+/g, ' ')
  return line.length <= max ? line : `${line.slice(0, max - 1).trimEnd()}…`
}
