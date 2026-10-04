import { href } from '../lib/route.ts'
import type { Route } from '../lib/route.ts'
import { FolderIcon, SparkIcon } from './icons.tsx'
import type { ReactNode } from 'react'

function RailLink({ to, label, active, children }: { to: string; label: string; active: boolean; children: ReactNode }) {
  return (
    <a
      href={to}
      aria-label={label}
      aria-current={active ? 'page' : undefined}
      className={`flex size-11 items-center justify-center rounded-xl hover:bg-raised ${
        active ? 'bg-raised text-accent' : 'text-muted'
      }`}
    >
      {children}
    </a>
  )
}

/** The left rail on a wide screen, a bar along the bottom on a phone. */
export default function Rail({ route }: { route: Route }) {
  return (
    <nav
      aria-label="Primary"
      className="fixed inset-x-0 bottom-0 z-10 flex h-16 items-center justify-center gap-2 border-t border-rail bg-bg md:static md:h-auto md:min-h-screen md:w-[68px] md:flex-none md:flex-col md:justify-start md:gap-1.5 md:border-t-0 md:border-r md:py-4"
    >
      <a href={href.create} aria-label="Retake home" className="flex size-11 items-center justify-center md:mb-3">
        <span className="size-3.5 rounded-full bg-accent shadow-[0_0_0_5px_rgba(255,106,61,0.16)]" />
      </a>
      <RailLink to={href.create} label="Create" active={route.name === 'create'}>
        <SparkIcon />
      </RailLink>
      <RailLink to={href.projects} label="Projects" active={route.name !== 'create'}>
        <FolderIcon />
      </RailLink>
    </nav>
  )
}
