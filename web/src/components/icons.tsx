// Inline stroke icons (24 viewBox), no icon package. They are decoration: the control around
// one carries the accessible name.

import type { ReactNode } from 'react'

interface IconProps {
  size?: number
}

function Svg({ size = 20, strokeWidth = 1.75, children }: IconProps & { strokeWidth?: number; children: ReactNode }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={strokeWidth}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      {children}
    </svg>
  )
}

export const SparkIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8z" />
    <path d="M19 17v4M17 19h4" />
  </Svg>
)

export const FolderIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" />
  </Svg>
)

export const ArrowRightIcon = (props: IconProps) => (
  <Svg {...props} strokeWidth={2}>
    <path d="M5 12h14M13 6l6 6-6 6" />
  </Svg>
)

export const DownloadIcon = (props: IconProps) => (
  <Svg {...props} strokeWidth={2}>
    <path d="M12 4v11M7 11l5 5 5-5M5 20h14" />
  </Svg>
)

export const ChevronDownIcon = (props: IconProps) => (
  <Svg {...props} strokeWidth={2}>
    <path d="M6 9l6 6 6-6" />
  </Svg>
)

export const CheckIcon = (props: IconProps) => (
  <Svg {...props} strokeWidth={3}>
    <path d="M5 12l5 5 9-10" />
  </Svg>
)

export const AlertIcon = (props: IconProps) => (
  <Svg {...props} strokeWidth={2.5}>
    <path d="M12 7v6M12 17h.01" />
  </Svg>
)
