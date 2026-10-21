import { existsSync } from 'node:fs'
import { expect, test, type Page } from '@playwright/test'
import { ALICE, CAROL, RPC, advance, deployment, rpc, sendAs } from './chain'

test.describe.configure({ mode: 'serial' })

/** Console errors and uncaught exceptions, collected per page. */
function watchErrors(page: Page): string[] {
  const errors: string[] = []
  page.on('console', (m) => {
    // A failed call logs its error on purpose (useTx); those tests check the toast instead
    if (m.type() === 'error' && !m.text().includes('ContractFunctionExecutionError') && !m.text().includes('HttpRequestError')) errors.push(m.text())
  })
  page.on('pageerror', (e) => errors.push(e.message))
  return errors
}

async function connect(page: Page) {
  await page.getByRole('banner').getByRole('button', { name: 'Connect wallet' }).click()
  await page.getByRole('dialog', { name: 'Connect a wallet' }).getByRole('button').filter({ hasText: /mock/i }).click()
  await expect(page.getByRole('banner').getByText('0x7099…79C8')).toBeVisible()
}

const nav = (page: Page, name: string) => page.getByRole('navigation', { name: 'Pages' }).getByRole('link', { name, exact: true })

const toast = (page: Page, title: string | RegExp) => page.locator('.toast').filter({ has: page.locator('.toast-title', { hasText: title }) })

async function amount(page: Page, value: string) {
  await page.locator('#amount').fill(value)
}

test('reads the vault, the cycle and the mechanics without a wallet', async ({ page }) => {
  const errors = watchErrors(page)
  await page.goto('/')
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('Ten times WETH on Aave, built in one transaction.')
  await expect(page.getByRole('heading', { name: 'The loop, as Aave holds it' })).toBeVisible()
  await expect(page.locator('.figure-label', { hasText: 'Leverage, target 10x' })).toBeVisible()
  await expect(page.getByRole('heading', { name: 'Aave WETH reserve' })).toBeVisible()
  // Regression: the legend lost its styles with the reference's chart section, so its swatches had no size or spacing
  const swatch = await page.locator('.legend i').first().boundingBox()
  expect(swatch?.width ?? 0).toBeGreaterThanOrEqual(8)
  await nav(page, 'Emergency').click()
  await expect(page.getByRole('heading', { name: 'Exit before liquidation, and back' })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Connect a wallet to run it' })).toBeVisible()
  await nav(page, 'How it works').click()
  await expect(page.getByRole('heading', { name: 'What runs here, and what is a stand-in' })).toBeVisible()
  expect(errors).toEqual([])
})

test('joins the whitelist, wraps ETH and deposits with a preview of the loop', async ({ page }) => {
  const errors = watchErrors(page)
  await page.goto('/')
  await connect(page)
  await page.getByRole('button', { name: 'Join the whitelist' }).click()
  await expect(toast(page, 'Whitelisted')).toBeVisible()

  await page.getByRole('tab', { name: 'Wrap ETH' }).click()
  await amount(page, '2')
  await page.getByRole('button', { name: 'Wrap ETH', exact: true }).click()
  await expect(toast(page, 'ETH wrapped')).toBeVisible()

  await page.getByRole('tab', { name: 'Deposit' }).click()
  await amount(page, '1')
  await expect(page.locator('.row dt', { hasText: 'Strategy collateral' })).toBeVisible()
  await expect(page.getByText(/Dashed outlines: the position after this deposit/)).toBeVisible()
  await expect(page.locator('.callout', { hasText: 'WETH flash loan from the Uniswap V4 PoolManager' })).toBeVisible()
  await page.getByRole('button', { name: 'Approve and deposit WETH' }).click()
  await expect(toast(page, 'WETH approved')).toBeVisible()
  await expect(toast(page, 'WETH deposited')).toBeVisible()
  await expect(page.locator('.position-state')).toHaveText('Your shares are worth')
  expect(errors).toEqual([])
})

test('stops a deposit above the wallet balance before the wallet is asked', async ({ page }) => {
  await page.goto('/')
  await connect(page)
  await page.getByRole('tab', { name: 'Deposit' }).click()
  await amount(page, '500')
  await expect(page.locator('.hint[data-tone="danger"]')).toContainText('More than your WETH balance')
  await expect(page.getByRole('button', { name: /deposit weth/i })).toBeDisabled()
})

test('decodes a revert the chain raises after the preview passed', async ({ page }) => {
  await page.goto('/')
  await connect(page)
  await page.getByRole('tab', { name: 'Deposit' }).click()
  await amount(page, '0.2')
  await expect(page.locator('.row dt', { hasText: 'Strategy collateral' })).toBeVisible()
  const d = deployment()
  // Right after the app refreshes its reads, another account shocks the thresholds: the preview still passes, and
  // the simulation against the chain is what stops the deposit
  await page.waitForResponse((r) => r.url().startsWith(RPC) && (r.request().postData() ?? '').includes('0x82ad56cb'))
  await sendAs(CAROL, d.operator, 'shock()')
  await page.getByRole('button', { name: /deposit weth/i }).click()
  const failed = toast(page, 'Deposit WETH failed')
  await expect(failed).toBeVisible()
  await expect(failed).toContainText('below the trip threshold')
  await sendAs(CAROL, d.operator, 'restore()')
})

test('redeems every share with Max', async ({ page }) => {
  await page.goto('/')
  await connect(page)
  await page.getByRole('tab', { name: 'Withdraw' }).click()
  await page.getByRole('button', { name: 'Max' }).click()
  await expect(page.locator('.hint', { hasText: 'Max redeems all your shares' })).toBeVisible()
  await page.getByRole('button', { name: 'Redeem shares' }).click()
  await expect(toast(page, 'Shares redeemed')).toBeVisible()
  await expect(page.locator('.position-state')).toHaveText('No vault shares yet')
})

test('runs the emergency cycle: shock, checkHealth, restore, reinvest', async ({ page }) => {
  // The shock in the revert test started the one-hour cooldown
  await advance(3_700)
  const errors = watchErrors(page)
  await page.goto('/emergency')
  await connect(page)
  await page.getByRole('button', { name: 'Shock the thresholds' }).click()
  await expect(toast(page, 'Thresholds raised')).toBeVisible()
  await expect(page.locator('.status', { hasText: 'Below the trip threshold' })).toBeVisible()
  await page.getByRole('button', { name: 'Call checkHealth()' }).click()
  await expect(toast(page, 'checkHealth() ran')).toBeVisible()
  await expect(page.locator('.status', { hasText: 'Emergency mode' })).toBeVisible()

  await nav(page, 'Vault').click()
  await expect(page.locator('.callout', { hasText: 'The vault is in emergency mode' })).toBeVisible()
  await page.getByRole('tab', { name: 'Deposit' }).click()
  await expect(page.locator('.hint[data-tone="danger"]')).toContainText('Deposits are closed while the vault is in emergency mode')

  await nav(page, 'Emergency').click()
  await page.getByRole('button', { name: 'Restore', exact: true }).click()
  await expect(toast(page, 'Restored')).toBeVisible()
  await page.getByRole('button', { name: 'Reinvest', exact: true }).click()
  await expect(toast(page, 'Reinvested')).toBeVisible()
  await expect(page.locator('.status', { hasText: 'Open for deposits' })).toBeVisible()
  expect(errors).toEqual([])
})

test('reports an unknown outcome when the receipt cannot be read', async ({ page }) => {
  await page.goto('/')
  await connect(page)
  await page.route(RPC, async (route) => {
    if ((route.request().postData() ?? '').includes('eth_getTransactionReceipt')) return route.fulfill({ status: 503, body: 'unavailable' })
    return route.continue()
  })
  await page.getByRole('tab', { name: 'Wrap ETH' }).click()
  await amount(page, '0.01')
  await page.getByRole('button', { name: 'Wrap ETH', exact: true }).click()
  const unknown = toast(page, 'Wrap ETH: outcome unknown')
  await expect(unknown).toBeVisible()
  await expect(unknown).toContainText('Check it on the explorer')
  await page.unroute(RPC)
})

test('warns about gas only once the balance is known to be zero', async ({ page }) => {
  const balance = await rpc<string>('eth_getBalance', [ALICE, 'latest'])
  await rpc('anvil_setBalance', [ALICE, '0x0'])
  try {
    await page.goto('/')
    await connect(page)
    await expect(page.locator('.callout[data-tone="warn"]', { hasText: 'no Local fork ETH for gas' })).toBeVisible()
  } finally {
    await rpc('anvil_setBalance', [ALICE, balance])
  }
})

// Regression: the amount input's intrinsic width set the action panel's minimum, so a 360 px screen scrolled sideways
test('fits a 360 px screen without horizontal scroll, on every page and tab', async ({ page }) => {
  await page.setViewportSize({ width: 360, height: 800 })
  await page.goto('/')
  await connect(page)
  await expect(page.locator('.row dt', { hasText: 'Wallet' })).toBeVisible()
  const overflow = () => page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth)
  for (const tab of ['Deposit', 'Withdraw', 'Wrap ETH']) {
    await page.getByRole('tab', { name: tab }).click()
    expect(await overflow(), `vault page, ${tab} tab`).toBeLessThanOrEqual(0)
  }
  for (const name of ['Emergency', 'How it works']) {
    await nav(page, name).click()
    expect(await overflow(), name).toBeLessThanOrEqual(0)
  }
})

test('shows the not-deployed page for a chain without a deployment file', async ({ page }) => {
  test.skip(existsSync(new URL('../src/config/deployments/84532.json', import.meta.url)), 'Base Sepolia is deployed')
  await page.goto('http://localhost:5182/')
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('The vault is not deployed on Base Sepolia yet.')
})
