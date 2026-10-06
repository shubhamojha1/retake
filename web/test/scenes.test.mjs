import assert from 'node:assert/strict'
import { test } from 'node:test'

import { credits, sceneRows, scenePlan } from '../src/lib/scenes.ts'

const spec = {
  title: 'Tea',
  output: { width: 1080, height: 1920, fps: 30 },
  assets: {
    'vis-1': { kind: 'video', license: { attribution: 'Video by Ann on Pixabay' } },
    'vis-2': { kind: 'image', license: { attribution: 'Photo by Bo on Pixabay' } },
    'vis-3': { kind: 'image', license: { attribution: 'Video by Ann on Pixabay' } },
  },
  scenes: [
    { id: 's1', duration_ms: 7_000, intent: { narration: 'One.', visual_query: 'steam' }, visual: { asset: 'vis-1' } },
    { id: 's2', duration_ms: 8_000, intent: { narration: 'Two.', visual_query: 'leaves' }, visual: { asset: 'vis-2' } },
    { id: 's3', duration_ms: 9_000, visual: { asset: 'vis-3' } },
  ],
}

test('sceneRows says where each scene starts and ends, and what it shows', () => {
  const rows = sceneRows(spec)

  assert.deepEqual(
    rows.map((row) => [row.n, row.startMs, row.endMs, row.kind]),
    [
      [1, 0, 7_000, 'video'],
      [2, 7_000, 15_000, 'image'],
      [3, 15_000, 24_000, 'image'],
    ],
  )
  assert.equal(rows[0].narration, 'One.')
  assert.equal(rows[1].query, 'leaves')
})

test('a scene with no intent still has a row, with empty words', () => {
  assert.deepEqual([sceneRows(spec)[2].narration, sceneRows(spec)[2].query], ['', ''])
})

test('credits lists each attribution once, in the order of the video', () => {
  assert.deepEqual(credits(spec), ['Video by Ann on Pixabay', 'Photo by Bo on Pixabay'])
})

const progress = {
  steps: {
    script: {
      status: 'done',
      scenes: 3,
      outline: [
        { narration: 'One.', query: 'a' },
        { narration: 'Two.', query: 'b' },
        { narration: 'Three.', query: 'c' },
      ],
    },
  },
  scenes: {
    1: { stock: { status: 'done' }, voice: { status: 'done' } },
    2: { stock: { status: 'done' }, voice: { status: 'started' } },
  },
}

test('scenePlan follows each scene’s footage and voice-over', () => {
  const plan = scenePlan(progress, false)

  assert.deepEqual(
    plan.map((scene) => [scene.n, scene.footage, scene.voice]),
    [
      [1, 'done', 'done'],
      [2, 'done', 'running'],
      [3, 'queued', 'queued'],
    ],
  )
  assert.equal(plan[0].narration, 'One.')
  assert.equal(plan[2].query, 'c')
})

test('scenePlan reads a scene’s visual step, and the older stock step too', () => {
  const plan = scenePlan(
    {
      steps: progress.steps,
      scenes: { 1: { visual: { status: 'done' } }, 2: { stock: { status: 'done' } }, 3: { visual: { status: 'started' } } },
    },
    false,
  )

  assert.deepEqual(plan.map((scene) => scene.footage), ['done', 'done', 'running'])
})

test('credits skips generated images, which have no attribution', () => {
  const withGenerated = {
    ...spec,
    assets: { ...spec.assets, 'vis-2': { kind: 'image', license: { name: 'AI-generated: flux' } } },
  }

  assert.deepEqual(credits(withGenerated), ['Video by Ann on Pixabay'])
})

test('scenePlan of a stopped job shows nothing as still running', () => {
  assert.equal(scenePlan(progress, true)[1].voice, 'queued')
})

test('scenePlan is empty before the script is written', () => {
  assert.deepEqual(scenePlan({}, false), [])
})
