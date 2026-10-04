// What the Create page asks for, and the request body the API takes (POST /api/videos).
// Only options the API accepts are here: no voice, captions or music yet.

export const LENGTHS = [
  { label: '15 s', ms: 15_000 },
  { label: '30 s', ms: 30_000 },
  { label: '45 s', ms: 45_000 },
  { label: '60 s', ms: 60_000 },
  { label: '90 s', ms: 90_000 },
]

export const DEFAULT_LENGTH_MS = 45_000

/** "" means no tone asked for. */
export const TONES = [
  { label: 'Any', value: '' },
  { label: 'Calm', value: 'calm' },
  { label: 'Energetic', value: 'energetic' },
  { label: 'Funny', value: 'funny' },
  { label: 'Serious', value: 'serious' },
  { label: 'Friendly', value: 'friendly' },
]

/** Suggestions: a click fills the prompt box with the prompt. */
export const IDEAS = [
  { label: 'Explainer', prompt: 'A 45-second explainer on why we dream. Calm tone, night-sky footage, simple language.' },
  { label: 'Top 5 facts', prompt: 'Five surprising facts about octopuses, one per scene, with a punchy ending.' },
  { label: 'Story time', prompt: 'A short bedtime story about a lighthouse keeper and a lost whale.' },
  { label: 'Product promo', prompt: 'A friendly 30-second promo for a reusable coffee cup that keeps drinks hot for 12 hours.' },
  { label: 'News recap', prompt: 'A quick recap of how the first photo of a black hole was made, for a general audience.' },
]

export const MAX_PROMPT_LENGTH = 4000

export interface BriefForm {
  prompt: string
  lengthMs: number
  tone: string
}

export interface BriefBody {
  prompt: string
  target_duration_ms: number
  tone?: string
}

/** What is wrong with the prompt, in words, or null. The server checks again. */
export function promptProblem(prompt: string): string | null {
  const text = prompt.trim()
  if (text === '') return 'Describe the video you want.'
  if (text.length > MAX_PROMPT_LENGTH) return `The prompt can be at most ${MAX_PROMPT_LENGTH} characters.`
  return null
}

export function buildBrief(form: BriefForm): BriefBody {
  const body: BriefBody = { prompt: form.prompt.trim(), target_duration_ms: form.lengthMs }
  if (form.tone !== '') body.tone = form.tone
  return body
}

/** The request that would make a video again, from the brief the server kept; null if it has no prompt. */
export function retryBrief(brief: { prompt?: string; target_duration_ms?: number; tone?: string }): BriefBody | null {
  if (!brief.prompt) return null

  const body: BriefBody = { prompt: brief.prompt, target_duration_ms: brief.target_duration_ms ?? DEFAULT_LENGTH_MS }
  if (brief.tone) body.tone = brief.tone
  return body
}
