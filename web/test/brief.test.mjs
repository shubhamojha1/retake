import assert from 'node:assert/strict'
import { test } from 'node:test'

import {
  buildBrief,
  DEFAULT_LENGTH_MS,
  IDEAS,
  LENGTHS,
  promptProblem,
  retryBrief,
  TONES,
} from '../src/lib/brief.ts'

test('buildBrief sends the trimmed prompt and the length in milliseconds', () => {
  assert.deepEqual(buildBrief({ prompt: '  Why tea is good  ', lengthMs: 30_000, tone: '' }), {
    prompt: 'Why tea is good',
    target_duration_ms: 30_000,
  })
})

test('buildBrief sends a tone only when one was chosen', () => {
  const body = buildBrief({ prompt: 'Tea', lengthMs: 45_000, tone: 'calm' })
  assert.equal(body.tone, 'calm')
  assert.equal('tone' in buildBrief({ prompt: 'Tea', lengthMs: 45_000, tone: '' }), false)
})

test('retryBrief asks for the same video again, from what the server kept', () => {
  assert.deepEqual(retryBrief({ prompt: 'Tea', target_duration_ms: 30_000, tone: 'calm' }), {
    prompt: 'Tea',
    target_duration_ms: 30_000,
    tone: 'calm',
  })
  assert.deepEqual(retryBrief({ prompt: 'Tea' }), { prompt: 'Tea', target_duration_ms: DEFAULT_LENGTH_MS })
  assert.equal(retryBrief({}), null)
})

test('promptProblem refuses a blank prompt and a very long one', () => {
  assert.match(promptProblem('   '), /Describe/)
  assert.match(promptProblem('x'.repeat(4001)), /4000/)
  assert.equal(promptProblem('Why tea is good'), null)
  assert.equal(promptProblem('x'.repeat(4000)), null)
})

test('every length is one the API takes (5 to 180 seconds), and the default is offered', () => {
  for (const { ms } of LENGTHS) assert.ok(ms >= 5_000 && ms <= 180_000, String(ms))
  assert.ok(LENGTHS.some(({ ms }) => ms === DEFAULT_LENGTH_MS))
})

test('the first tone means none, and tone values are plain words for the script prompt', () => {
  assert.equal(TONES[0].value, '')
  for (const { value } of TONES.slice(1)) assert.match(value, /^[a-z]+$/)
})

test('every idea has a label and a prompt the API would take', () => {
  for (const idea of IDEAS) {
    assert.ok(idea.label.length > 0)
    assert.equal(promptProblem(idea.prompt), null, idea.label)
  }
})
