// The tiger is page-mascot by Kamran Ahmed (MIT): https://github.com/nilbuild/page-mascot
// Used as its README describes: the Mascot component with the tiger's two sheets.
import { createRoot } from 'react-dom/client'
import { Mascot } from 'page-mascot'
import directions from './assets/tiger-directions.webp'
import reactions from './assets/tiger-reactions.webp'

const slot = document.getElementById('mascot')
if (slot) {
  createRoot(slot).render(
    <Mascot directions={directions} reactions={reactions} size={140} label="fast-ios tiger" />,
  )

  // One reaction per visit: when the measured numbers come on screen, the
  // tiger reacts once, as a click on it would. With reduced motion it stays
  // still.
  const card = document.querySelector('.stats')
  const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches
  if (card && !reduced) {
    const seen = new IntersectionObserver((entries) => {
      if (!entries.some((e) => e.isIntersecting)) return
      seen.disconnect()
      window.setTimeout(() => slot.querySelector<HTMLButtonElement>('button')?.click(), 600)
    })
    seen.observe(card)
  }
}
