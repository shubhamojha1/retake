// A video has no thumbnail yet, so its card gets one of five dark colours from the mockups,
// the same one every time for the same id.

const TONES = ['#1B2433', '#2A1F1B', '#172A27', '#2B2616', '#271B2E']

export function toneFor(seed: string): string {
  let hash = 0
  for (const char of seed) hash = (hash * 31 + (char.codePointAt(0) ?? 0)) >>> 0
  return TONES[hash % TONES.length]
}
