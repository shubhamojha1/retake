import assert from 'node:assert/strict'
import { test } from 'node:test'

import { formatDuration, formatRange, shorten, timeAgo } from '../src/lib/format.ts'
import { toneFor } from '../src/lib/tone.ts'

test('formatDuration renders m:ss', () => {
  assert.equal(formatDuration(0), '0:00')
  assert.equal(formatDuration(59_999), '0:59')
  assert.equal(formatDuration(61_000), '1:01')
})

test('formatDuration clamps negatives to zero', () => {
  assert.equal(formatDuration(-5), '0:00')
})

test('formatRange joins two times', () => {
  assert.equal(formatRange(7_000, 15_000), '0:07–0:15')
})

test('timeAgo speaks in minutes, hours and days', () => {
  const now = new Date('2026-10-05T12:00:00Z')
  const ago = (seconds) => new Date(now.getTime() - seconds * 1000).toISOString()

  assert.equal(timeAgo(ago(5), now), 'just now')
  assert.equal(timeAgo(ago(5 * 60), now), '5 min ago')
  assert.equal(timeAgo(ago(3 * 3600), now), '3 h ago')
  assert.equal(timeAgo(ago(30 * 3600), now), 'yesterday')
  assert.equal(timeAgo(ago(4 * 86400), now), '4 days ago')
})

test('timeAgo copes with a time in the future and with nonsense', () => {
  const now = new Date('2026-10-05T12:00:00Z')

  assert.equal(timeAgo('2026-10-05T12:00:30Z', now), 'just now')
  assert.equal(timeAgo('not a date', now), '')
})

test('shorten keeps short text and cuts long text on one line', () => {
  assert.equal(shorten('  Why   tea\nis good  ', 40), 'Why tea is good')
  assert.equal(shorten('Why tea is good for you', 10), 'Why tea i…')
})

test('toneFor is one of the five card colours, and the same for the same id', () => {
  assert.match(toneFor('v-0123456789'), /^#[0-9A-F]{6}$/)
  assert.equal(toneFor('v-0123456789'), toneFor('v-0123456789'))
  assert.notEqual(new Set(['a', 'b', 'c', 'd', 'e', 'f', 'g'].map(toneFor)).size, 1)
})
