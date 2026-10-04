// The app has three pages, chosen by the part of the address after "#" (no server setup needed).

export type Route = { name: 'create' } | { name: 'projects' } | { name: 'video'; id: string }

export const href = {
  create: '#/',
  projects: '#/projects',
  video: (id: string) => `#/videos/${id}`,
}

export function parseRoute(hash: string): Route {
  const path = hash.replace(/^#/, '').split('?')[0].replace(/\/+$/, '')

  if (path === '/projects') return { name: 'projects' }

  const video = /^\/videos\/([A-Za-z0-9_-]{1,64})$/.exec(path)
  if (video) return { name: 'video', id: video[1] }

  return { name: 'create' }
}
