// End-to-end smoke test of the RUNNING system, with real services: asks the API for a very short
// video, follows it live over the websocket the page uses, and checks the MP4 comes back with
// byte-range support.
//
// It uses the network and takes minutes, so it is NOT part of `just test` or CI. Run it with
// `just e2e-smoke` while `just api` runs, with Kokoro up (`just kokoro`) and the provider keys
// in the environment of the API (`mix retake.video` explains which).
//
// Environment: API_URL (default http://localhost:4010), SMOKE_PROMPT, SMOKE_LENGTH_MS (default
// 5000, the shortest the API takes), SMOKE_TIMEOUT_MS (default 15 minutes).

import { Socket } from 'phoenix'

const API = process.env.API_URL ?? 'http://localhost:4010'
const PROMPT = process.env.SMOKE_PROMPT ?? 'Why tea is good for you'
const LENGTH_MS = Number(process.env.SMOKE_LENGTH_MS ?? 5_000)
const TIMEOUT_MS = Number(process.env.SMOKE_TIMEOUT_MS ?? 15 * 60 * 1000)

const say = (message) => console.log(message)

function fail(message) {
  console.error(`\nSMOKE FAILED: ${message}`)
  process.exit(1)
}

function check(condition, message) {
  if (!condition) fail(message)
  say(`  ok  ${message}`)
}

async function call(path, init) {
  let response
  try {
    response = await fetch(`${API}${path}`, init)
  } catch (error) {
    fail(`cannot reach ${API}${path} (${error.message}). Is \`just api\` running?`)
  }
  return response
}

// --- 1. the server is up ----------------------------------------------------------------

say('1. health')
const health = await call('/api/health')
check(health.status === 200, 'GET /api/health answers 200 (server and database are up)')

// --- 2. ask for a video ------------------------------------------------------------------

say(`2. POST /api/videos  (${LENGTH_MS} ms, "${PROMPT}")`)
const created = await call('/api/videos', {
  method: 'POST',
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify({ prompt: PROMPT, target_duration_ms: LENGTH_MS }),
})
check(created.status === 202, 'answers 202 (the video is made in the background)')

const { data: job } = await created.json()
check(/^v-[0-9a-f]{10}$/.test(job.id), `has an id (${job.id})`)
check(created.headers.get('location') === `/api/videos/${job.id}`, 'says where to look (Location header)')

const refused = await call('/api/videos', {
  method: 'POST',
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify({ prompt: '   ' }),
})
check(refused.status === 422, 'a blank prompt is refused with 422')

// --- 3. follow it live ---------------------------------------------------------------------

say('3. follow it over the websocket (what the page does)')
const socket = new Socket(`${API.replace(/^http/, 'ws')}/socket`, { transport: WebSocket })
socket.connect()

const channel = socket.channel(`video:${job.id}`)
let pushes = 0
let lastStep = null
let first = true

const finished = new Promise((resolve) => {
  channel.on('progress', ({ progress }) => {
    pushes += 1
    const step = progress.current?.step
    if (step && step !== lastStep) {
      lastStep = step
      say(`  ... ${step}${progress.current.scene ? ` (scene ${progress.current.scene})` : ''}`)
    }
  })

  channel.on('video', ({ data }) => {
    if (first) {
      first = false
      check(data.id === job.id, 'joined the channel and got the whole job first')
    }
    if (data.status === 'succeeded' || data.status === 'failed') resolve(data)
  })
})

channel
  .join()
  .receive('error', (reply) => fail(`the channel refused the join: ${JSON.stringify(reply)}`))
  .receive('timeout', () => fail('the channel join timed out'))

const timer = new Promise((_, reject) => setTimeout(() => reject(new Error('timeout')), TIMEOUT_MS))
const video = await Promise.race([finished, timer]).catch(() => fail(`no result within ${TIMEOUT_MS / 1000} s`))

check(pushes > 0, `got live progress (${pushes} pushes)`)
if (video.status === 'failed') {
  fail(`the video failed at ${video.error?.step}${video.error?.scene ? ` (scene ${video.error.scene})` : ''}:\n${video.error?.message}`)
}
check(video.status === 'succeeded', 'the video succeeded')

// --- 4. what came out ----------------------------------------------------------------------

say('4. the result')
check(typeof video.title === 'string' && video.title.length > 0, `has a title ("${video.title}")`)
check(video.duration_ms > 0, `has a length (${video.duration_ms} ms)`)
check(video.spec?.scenes?.length > 0, `has a spec with ${video.spec?.scenes?.length} scenes`)
check(video.progress?.steps?.render?.status === 'done', 'the progress ends with the render done')
check(video.video_url === `/api/videos/${job.id}/file`, 'says where the file is')

const again = await call(`/api/videos/${job.id}`)
check((await again.json()).data.status === 'succeeded', 'GET /api/videos/:id agrees')

const list = await call('/api/videos?limit=5')
check((await list.json()).data.some((item) => item.id === job.id), 'GET /api/videos lists it')

// --- 5. the file, by byte range -------------------------------------------------------------

say('5. GET the MP4, 100 bytes of it')
const slice = await call(video.video_url, { headers: { range: 'bytes=0-99' } })
check(slice.status === 206, 'a Range request answers 206')
check(/^bytes 0-99\/\d+$/.test(slice.headers.get('content-range') ?? ''), `Content-Range is ${slice.headers.get('content-range')}`)
check(slice.headers.get('content-type') === 'video/mp4', 'Content-Type is video/mp4')

const bytes = Buffer.from(await slice.arrayBuffer())
check(bytes.length === 100, 'got exactly 100 bytes')
check(bytes.subarray(4, 8).toString() === 'ftyp', 'they start like an MP4 file (ftyp)')

socket.disconnect()
say('\nSMOKE PASSED')
process.exit(0)
