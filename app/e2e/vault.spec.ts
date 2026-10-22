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

const payWith = (page: Page, asset: 'ETH' | 'WETH') =>
  page.getByRole('group', { name: 'Pay with' }).getByRole('button', { name: asset, exact: true }).click()

test('reads the vault, the cycle and the mechanics without a wallet', async ({ page }) => {
  const errors = watchErrors(page)
  await page.goto('/')
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('Put WETH to work at 10x on Aave.')
  await expect(page.locator('.kpi-label', { hasText: 'Net APY on your WETH' })).toBeVisible()
  await expect(page.locator('.breakdown')).toContainText('collateral earns')
  await expect(page.getByRole('heading', { name: 'The loop, as Aave holds it' })).toBeVisible()
  await expect(page.getByRole('heading', { name: 'Where the yield comes from' })).toBeVisible()
  // Regression: the legend lost its styles with the reference's chart section, so its swatches had no size or spacing
  const swatch = await page.locator('.legend i').first().boundingBox()
  expect(swatch?.width ?? 0).toBeGreaterThanOrEqual(8)
  for (const [tab, heading] of [
    ['Risks', 'What can go wrong'],
    ['Fees', 'Performance fee'],
    ['Contracts', 'Contracts'],
  ]) {
    await page.getByRole('tab', { name: tab }).click()
    await expect(page.getByRole('heading', { name: heading, exact: true })).toBeVisible()
  }
  await page.getByRole('tab', { name: 'Capacity' }).click()
  await expect(page.getByText('Largest deposit that fits right now')).toBeVisible()
  await nav(page, 'Stress test').click()
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('Stress test: exit before liquidation, and back.')
  await expect(page.getByRole('button', { name: 'Connect a wallet to run it' })).toBeVisible()
  await nav(page, 'How it works').click()
  await expect(page.getByRole('heading', { name: 'What runs here, and what is a stand-in' })).toBeVisible()
  // The page's old path still lands on it
  await page.goto('/emergency')
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('Stress test: exit before liquidation, and back.')
  expect(errors).toEqual([])
})

test('deposits Ether in one flow: join, wrap, approve, deposit', async ({ page }) => {
  const errors = watchErrors(page)
  await page.goto('/')
  await connect(page)
  await payWith(page, 'ETH')
  await amount(page, '1')
  await expect(page.locator('.row dt', { hasText: 'You receive' })).toBeVisible()
  await expect(page.locator('.stepper li .name')).toHaveText(['Join the whitelist', 'Wrap 1 ETH into WETH', 'Approve the vault', 'Deposit'])
  await expect(page.getByText(/Dashed outline: after this deposit/)).toBeVisible()
  await page.locator('details.hood summary').click()
  await expect(page.locator('.hood-body')).toContainText('WETH flash loan from the Uniswap V4 PoolManager')
  await expect(page.getByText('4 transactions: your wallet asks for each one in turn.')).toBeVisible()
  await page.getByRole('button', { name: 'Deposit 1 ETH' }).click()
  await expect(toast(page, 'WETH deposited')).toBeVisible()
  // The steps before the last report in the stepper, not in toasts of their own
  await expect(page.locator('.toast')).toHaveCount(1)
  await expect(page.locator('.position-state')).toHaveText('Your shares are worth')
  expect(errors).toEqual([])
})

test('stops a deposit above the wallet balance before the wallet is asked', async ({ page }) => {
  await page.goto('/')
  await connect(page)
  await payWith(page, 'WETH')
  await amount(page, '500')
  await expect(page.locator('.hint[data-tone="danger"]')).toContainText('More than your WETH balance')
  await expect(page.getByRole('button', { name: /deposit 500 weth/i })).toBeDisabled()
})

test('decodes a revert the chain raises after the preview passed', async ({ page }) => {
  await page.goto('/')
  await connect(page)
  await payWith(page, 'ETH')
  await amount(page, '0.2')
  await expect(page.locator('.row dt', { hasText: 'You receive' })).toBeVisible()
  const d = deployment()
  // Right after the app refreshes its reads, another account pushes the exit line: the preview still passes, and
  // the simulation against the chain is what stops the deposit
  await page.waitForResponse((r) => r.url().startsWith(RPC) && (r.request().postData() ?? '').includes('0x82ad56cb'))
  await sendAs(CAROL, d.operator, 'shock()')
  await page.getByRole('button', { name: 'Deposit 0.2 ETH' }).click()
  const failed = toast(page, 'Deposit WETH failed')
  await expect(failed).toBeVisible()
  await expect(failed).toContainText('below the exit line')
  await sendAs(CAROL, d.operator, 'restore()')
})

test('redeems every share with Max', async ({ page }) => {
  await page.goto('/')
  await connect(page)
  await page.getByRole('tab', { name: 'Withdraw' }).click()
  await page.getByRole('button', { name: 'Max' }).click()
  await expect(page.locator('.hint', { hasText: 'Max redeems all your shares' })).toBeVisible()
  await page.getByRole('button', { name: 'Redeem all shares' }).click()
  await expect(toast(page, 'Shares redeemed')).toBeVisible()
  await expect(page.locator('.position-state')).toHaveText('No vault shares yet')
})

test('runs the stress test: push the line, exit, reopen, loop again', async ({ page }) => {
  // The push in the revert test started the one-hour cooldown
  await advance(3_700)
  const errors = watchErrors(page)
  await page.goto('/stress-test')
  await connect(page)
  await page.getByRole('button', { name: 'Push the line' }).click()
  await expect(toast(page, 'Exit line raised')).toBeVisible()
  await expect(page.locator('.status', { hasText: 'Below the exit line' })).toBeVisible()
  await page.getByRole('button', { name: 'Run the health check' }).click()
  await expect(toast(page, 'Health check ran')).toBeVisible()
  await expect(page.locator('.status', { hasText: 'Emergency mode' }).first()).toBeVisible()

  await nav(page, 'Vault').click()
  await expect(page.locator('.callout', { hasText: 'The vault is in emergency mode' })).toBeVisible()
  await expect(page.locator('.hint[data-tone="danger"]')).toContainText('Deposits are closed while the vault is in emergency mode')

  await nav(page, 'Stress test').click()
  await page.getByRole('button', { name: 'Reopen the vault' }).click()
  await expect(toast(page, 'Vault reopened')).toBeVisible()
  await page.getByRole('button', { name: 'Loop again' }).click()
  await expect(toast(page, 'Position rebuilt')).toBeVisible()
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
  await payWith(page, 'ETH')
  await amount(page, '0.01')
  await page.getByRole('button', { name: 'Deposit 0.01 ETH' }).click()
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
  for (const tab of ['Deposit', 'Withdraw', 'Overview', 'Risks', 'Capacity', 'Fees', 'Contracts']) {
    await page.getByRole('tab', { name: tab }).click()
    expect(await overflow(), `vault page, ${tab} tab`).toBeLessThanOrEqual(0)
  }
  for (const name of ['Stress test', 'How it works']) {
    await nav(page, name).click()
    expect(await overflow(), name).toBeLessThanOrEqual(0)
  }
})

test('shows the not-deployed page for a chain without a deployment file', async ({ page }) => {
  test.skip(existsSync(new URL('../src/config/deployments/84532.json', import.meta.url)), 'Base Sepolia is deployed')
  await page.goto('http://localhost:5182/')
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('The vault is not deployed on Base Sepolia yet.')
})
