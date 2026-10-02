# Retake: product brief

## One line

A self-hostable, open-source AI video editor: turn a prompt into a short video
using any provider's API key, then refine it so only the scenes you changed are
regenerated and re-rendered.

## Who it's for

Creators and small teams making short explainer / tip / promo videos who want
control over cost, models and data, and who don't want to rent a closed
credit-based platform.

## What makes it different (in priority order)

1. **Precise, cheap edits.** Change one scene, pay for and re-render one scene.
   Content-hash caching of every generated asset.
2. **History.** Every change is a version. Later: branch, compare, merge.
3. **Transparent cost, any provider.** Bring your own keys. See what each step
   and each edit costs before you run it. Local models work too.
4. **Open format.** The video is a documented JSON spec (`spec/`), not a
   proprietary project file.

## What it is not (for now)

- Not a general-purpose timeline editor like Premiere or CapCut.
- Not a model company. Retake orchestrates other people's models.
- Not a hosted SaaS. Self-hosted first.

## Competitors to know

InVideo (Agent One / Agent Two), Higgsfield, HeyGen, Descript, OpusClip,
Captions, CapCut. Open source: MoneyPrinterTurbo, ShortGPT, Remotion
(source-available), Revideo, editly.
