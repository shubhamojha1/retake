import assert from 'node:assert/strict'
import { test } from 'node:test'

import { formatDuration } from '../src/lib/format.ts'

test('formatDuration renders m:ss', () => {
  assert.equal(formatDuration(0), '0:00')
  assert.equal(formatDuration(59_999), '0:59')
  assert.equal(formatDuration(61_000), '1:01')
})

test('formatDuration clamps negatives to zero', () => {
  assert.equal(formatDuration(-5), '0:00')
})
