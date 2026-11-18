# Third-party notices

## page-mascot (tiger character)

The fast-ios tiger on the website, the social card, the favicon and the
README image is the tiger from page-mascot by Kamran Ahmed,
<https://github.com/nilbuild/page-mascot> (npm package `page-mascot` 0.1.0).
The site uses the `Mascot` component with the tiger's two sheets
(`tiger-directions.webp`, `tiger-reactions.webp`), as the project's README
describes. The favicon, social card and README image are crops of the
forward-facing cell of `tiger-directions.webp`.

The Mac app's icon (`packaging/app/AppIcon.icns`) and its menu-bar template
image (`packaging/app/MenuBarIcon*.png`) are made from the same cell by
`scripts/render-icon.swift`: the icon places it on a rounded square, the
template keeps only its dark line work.

The tiger is a stock page-mascot character: other sites can use it too.

```
MIT License

Copyright (c) 2026 Kamran Ahmed <https://kamran.fyi>

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## simslim

fast-ios follows simslim's launchd-store approach and copies its service
catalog. See `THIRD_PARTY_SIMSLIM_LICENSE` in the repository root.
