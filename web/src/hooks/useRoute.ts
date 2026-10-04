import { useEffect, useState } from 'react'

import { parseRoute } from '../lib/route.ts'
import type { Route } from '../lib/route.ts'

/** The page the address (after the "#") asks for; changes when the address does. */
export function useRoute(): Route {
  const [hash, setHash] = useState(() => window.location.hash)

  useEffect(() => {
    const onChange = () => setHash(window.location.hash)
    window.addEventListener('hashchange', onChange)
    return () => window.removeEventListener('hashchange', onChange)
  }, [])

  return parseRoute(hash)
}
