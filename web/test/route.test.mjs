import assert from 'node:assert/strict'
import { test } from 'node:test'

import { href, parseRoute } from '../src/lib/route.ts'

test('no hash, or a hash we do not know, is the Create page', () => {
  assert.deepEqual(parseRoute(''), { name: 'create' })
  assert.deepEqual(parseRoute('#'), { name: 'create' })
  assert.deepEqual(parseRoute('#/'), { name: 'create' })
  assert.deepEqual(parseRoute('#/nowhere'), { name: 'create' })
})

test('#/projects is the list of videos', () => {
  assert.deepEqual(parseRoute('#/projects'), { name: 'projects' })
  assert.deepEqual(parseRoute('#/projects/'), { name: 'projects' })
})

test('#/videos/:id is one video', () => {
  assert.deepEqual(parseRoute('#/videos/v-0123456789'), { name: 'video', id: 'v-0123456789' })
  assert.deepEqual(parseRoute('#/videos/v-0123456789?x=1'), { name: 'video', id: 'v-0123456789' })
})

test('an id with odd characters is not a video', () => {
  assert.deepEqual(parseRoute('#/videos/../etc'), { name: 'create' })
  assert.deepEqual(parseRoute('#/videos/a b'), { name: 'create' })
  assert.deepEqual(parseRoute('#/videos/'), { name: 'create' })
})

test('href builds what parseRoute reads', () => {
  assert.deepEqual(parseRoute(href.create), { name: 'create' })
  assert.deepEqual(parseRoute(href.projects), { name: 'projects' })
  assert.deepEqual(parseRoute(href.video('v-abc')), { name: 'video', id: 'v-abc' })
})
