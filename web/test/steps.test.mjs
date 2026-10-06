import assert from 'node:assert/strict'
import { test } from 'node:test'

import { buildSteps, stoppedAt } from '../src/lib/steps.ts'

const states = (rows) => rows.map((row) => `${row.key}:${row.state}`)

const outline = [
  { narration: 'One.', query: 'a' },
  { narration: 'Two.', query: 'b' },
  { narration: 'Three.', query: 'c' },
]

const scriptDone = { status: 'done', scenes: 3, title: 'Tea', outline }

test('a job nobody started has every step queued', () => {
  const rows = buildSteps({ status: 'queued', progress: {}, error: null })
  assert.deepEqual(states(rows), ['script:queued', 'footage:queued', 'voice:queued', 'render:queued'])
})

test('a running job with no step reported yet is writing the script', () => {
  const rows = buildSteps({ status: 'running', progress: {}, error: null })
  assert.deepEqual(states(rows), ['script:running', 'footage:queued', 'voice:queued', 'render:queued'])
  assert.equal(rows[0].detail, 'Writing the script')
})

test('after the script, footage and voice-over run side by side and count the scenes done', () => {
  const progress = {
    steps: { script: scriptDone },
    scenes: {
      1: { stock: { status: 'done' }, voice: { status: 'done' } },
      2: { stock: { status: 'done' }, voice: { status: 'started' } },
      3: { stock: { status: 'started' } },
    },
  }

  const rows = buildSteps({ status: 'running', progress, error: null })

  assert.deepEqual(states(rows), ['script:done', 'footage:running', 'voice:running', 'render:queued'])
  assert.equal(rows[0].detail, '3 scenes for “Tea”')
  assert.equal(rows[1].detail, '2 of 3 pictures and clips ready')
  assert.equal(rows[1].pct, 67)
  assert.equal(rows[2].detail, '1 of 3 narrated and timed')
  assert.equal(rows[2].pct, 33)
})

test('footage is done when every scene has its footage', () => {
  const scenes = { 1: { stock: { status: 'done' } }, 2: { stock: { status: 'done' } }, 3: { stock: { status: 'done' } } }

  const rows = buildSteps({ status: 'running', progress: { steps: { script: scriptDone }, scenes }, error: null })

  assert.equal(rows[1].state, 'done')
})

test('the visuals row counts scenes by their visual step', () => {
  const scenes = { 1: { visual: { status: 'done' } }, 2: { visual: { status: 'done' } }, 3: { visual: { status: 'started' } } }

  const rows = buildSteps({ status: 'running', progress: { steps: { script: scriptDone }, scenes }, error: null })

  assert.equal(rows[1].name, 'Visuals')
  assert.equal(rows[1].state, 'running')
  assert.equal(rows[1].detail, '2 of 3 pictures and clips ready')
})

test('a job saved before generated images reported its pictures as stock, and still counts', () => {
  const scenes = { 1: { stock: { status: 'done' } }, 2: { stock: { status: 'done' } }, 3: { stock: { status: 'done' } } }

  const rows = buildSteps({ status: 'running', progress: { steps: { script: scriptDone }, scenes }, error: null })

  assert.equal(rows[1].state, 'done')
})

test('a failed visual step fails the Visuals row, with the scene and the reason', () => {
  const progress = {
    steps: { script: scriptDone },
    scenes: { 3: { visual: { status: 'failed', message: 'no stock footage or photo found for: "sea"' } } },
  }
  const error = { step: 'visual', scene: 3, message: 'no stock footage or photo found for: "sea"' }

  const rows = buildSteps({ status: 'failed', progress, error })

  assert.equal(rows[1].state, 'failed')
  assert.equal(rows[1].detail, 'Scene 3: no stock footage or photo found for: "sea"')
  assert.equal(stoppedAt(error), 'Stopped at finding the visuals (scene 3)')
})

test('rendering shows the share of frames done', () => {
  const progress = {
    steps: {
      script: scriptDone,
      assemble: { status: 'done' },
      render: { status: 'running', done: 120, total: 480 },
    },
    scenes: {
      1: { stock: { status: 'done' }, voice: { status: 'done' } },
      2: { stock: { status: 'done' }, voice: { status: 'done' } },
      3: { stock: { status: 'done' }, voice: { status: 'done' } },
    },
  }

  const rows = buildSteps({ status: 'running', progress, error: null })

  assert.deepEqual(states(rows), ['script:done', 'footage:done', 'voice:done', 'render:running'])
  assert.equal(rows[3].pct, 25)
  assert.equal(rows[3].detail, '25%')
})

test('putting the scenes together is already the render row', () => {
  const progress = { steps: { script: scriptDone, assemble: { status: 'started' } } }

  const rows = buildSteps({ status: 'running', progress, error: null })

  assert.equal(rows[3].state, 'running')
  assert.equal(rows[3].detail, 'Putting the scenes together')
})

test('a succeeded job has every step done', () => {
  const rows = buildSteps({ status: 'succeeded', progress: { steps: { render: { status: 'done' } } }, error: null })

  assert.deepEqual(states(rows), ['script:done', 'footage:done', 'voice:done', 'render:done'])
  assert.ok(rows.every((row) => row.pct === null))
})

test('a failed footage step fails the footage row, with the scene and the reason, and stops the rest', () => {
  const progress = {
    steps: { script: scriptDone },
    scenes: {
      1: { stock: { status: 'done' }, voice: { status: 'done' } },
      2: { stock: { status: 'started' }, voice: { status: 'started' } },
      3: { stock: { status: 'failed', message: 'no stock footage or photo found for: "sea"\nmore' } },
    },
  }
  const error = { step: 'stock', scene: 3, message: 'no stock footage or photo found for: "sea"' }

  const rows = buildSteps({ status: 'failed', progress, error })

  assert.deepEqual(states(rows), ['script:done', 'footage:failed', 'voice:queued', 'render:queued'])
  assert.equal(rows[1].detail, 'Scene 3: no stock footage or photo found for: "sea"')
  assert.equal(rows[2].detail, 'Stopped')
})

test('a failure from before the script (setup, the request) fails no row', () => {
  const error = { step: 'setup', scene: null, message: 'unknown profile "nope"' }

  const rows = buildSteps({ status: 'failed', progress: {}, error })

  assert.ok(rows.every((row) => row.state === 'queued'))
})

test('a failure in the render step fails the render row', () => {
  const progress = { steps: { script: scriptDone, assemble: { status: 'done' }, render: { status: 'started' } } }
  const error = { step: 'render', scene: null, message: 'renderer_not_found: no renderer' }

  const rows = buildSteps({ status: 'failed', progress, error })

  assert.equal(rows[3].state, 'failed')
  assert.equal(rows[3].detail, 'renderer_not_found: no renderer')
})

test('stoppedAt says where a job stopped', () => {
  assert.equal(stoppedAt({ step: 'voice', scene: 3, message: '' }), 'Stopped at the voice-over (scene 3)')
  assert.equal(stoppedAt({ step: 'script', scene: null, message: '' }), 'Stopped at the script')
  assert.equal(stoppedAt({ step: 'interrupted', scene: null, message: '' }), 'Stopped at a restart of the app')
  assert.equal(stoppedAt({ step: 'mystery', scene: null, message: '' }), 'Stopped at mystery')
})
