import { expect, test } from '@playwright/test'
import { rpc } from './chain'

// Screenshots for review, not assertions: desktop and phone widths, light and dark, with a connected position.
//   E2E_RPC=http://127.0.0.1:8545 npx playwright test screens   (writes test-results/screens/*.png)
// Leaves the fork as it found it, so the other specs see the deployment state in any order
let snapshot = ''
test.beforeAll(async () => {
  snapshot = await rpc<string>('evm_snapshot')
})
test.afterAll(async () => {
  await rpc('evm_revert', [snapshot])
})

test('captures the pages at desktop and phone widths, light and dark', async ({ page }) => {
  await page.goto('/')
  await page.getByRole('banner').getByRole('button', { name: 'Connect wallet' }).click()
  await page.getByRole('dialog', { name: 'Connect a wallet' }).getByRole('button').filter({ hasText: /mock/i }).click()
  // The account reads first, so the flow is only shown once the balances are known
  await expect(page.locator('.row dt', { hasText: 'Wallet' })).toBeVisible()
  await page.getByRole('group', { name: 'Pay with' }).getByRole('button', { name: 'ETH', exact: true }).click()
  await page.locator('#amount').fill('0.5')
  await page.getByRole('button', { name: 'Deposit 0.5 ETH' }).click()
  await expect(page.locator('.toast-title', { hasText: 'WETH deposited' })).toBeVisible()
  // A typed amount, so the drawing shows its preview outline
  await page.locator('#amount').fill('0.25')

  for (const width of [1280, 768, 375, 360]) {
    for (const scheme of ['light', 'dark'] as const) {
      await page.setViewportSize({ width, height: 900 })
      await page.emulateMedia({ colorScheme: scheme, reducedMotion: 'reduce' })
      for (const [name, path] of [['vault', '/'], ['stress', '/stress-test'], ['how', '/how-it-works']] as const) {
        await page.getByRole('navigation', { name: 'Pages' }).getByRole('link', { name: { vault: 'Vault', stress: 'Stress test', how: 'How it works' }[name], exact: true }).click()
        await expect(page).toHaveURL(new RegExp(`${path}$`))
        await page.waitForTimeout(400)
        await page.screenshot({ path: `test-results/screens/${name}-${width}-${scheme}.png`, fullPage: true })
      }
      await page.getByRole('navigation', { name: 'Pages' }).getByRole('link', { name: 'Vault', exact: true }).click()
    }
  }
  // Keyboard focus, visible on the primary action
  await page.setViewportSize({ width: 1280, height: 900 })
  await page.emulateMedia({ colorScheme: 'light' })
  await page.getByRole('tab', { name: 'Deposit' }).focus()
  await page.keyboard.press('Tab')
  await page.screenshot({ path: 'test-results/screens/focus-1280-light.png' })
})
