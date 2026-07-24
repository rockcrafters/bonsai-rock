# attribution

`bonsai-logo-light.svg` / `bonsai-logo-dark.svg` are the **Bonsai** logo,
copyright (c) Prism ML, Inc., from
[prism-ml/Bonsai-1.7B-gguf](https://huggingface.co/prism-ml/Bonsai-1.7B-gguf/blob/main/assets/bonsai-logo.svg)
(`assets/bonsai-logo.svg`), used under the **Apache-2.0** licence to identify the
model this rock bundles.

change from the original: the single source used a `<style>` block with a
`prefers-color-scheme` media query for its black/white fill. github strips
`<style>` from README-embedded SVGs, so it is split into two files with static
`fill="#000"` (light) and `fill="#fff"` (dark), selected via a `<picture>` in
the README. no paths were altered.

per the model's NOTICE: *Created using Bonsai by Prism ML.*
