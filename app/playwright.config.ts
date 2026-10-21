import { defineConfig } from '@playwright/test'

// End-to-end tests against a local anvil fork of Base Sepolia with the vault deployed (scripts/local-chain.sh).
// The app connects with wagmi's mock connector as anvil's account 1, which the node signs for.
//   E2E_RPC=http://127.0.0.1:8545 npx playwright test
const rpc = process.env.E2E_RPC ?? 'http://127.0.0.1:8545'
export const E2E_ACCOUNT = '0x70997970C51812dc3A010C7d01b50e0d17dc79C8'

export default defineConfig({
  testDir: 'e2e',
  fullyParallel: false,
  workers: 1,
  timeout: 180_000,
  expect: { timeout: 45_000 },
  globalSetup: './e2e/global-setup.ts',
  globalTeardown: './e2e/global-teardown.ts',
  reporter: [['list']],
  use: { baseURL: 'http://localhost:5181', trace: 'retain-on-failure' },
  webServer: [
    {
      command: `VITE_CHAIN_ID=31337 VITE_RPC_URL=${rpc} VITE_E2E_ACCOUNT=${E2E_ACCOUNT} npx vite --port 5181 --strictPort`,
      url: 'http://localhost:5181',
      reuseExistingServer: true,
    },
    {
      // Base Sepolia with no deployment file: the not-deployed page
      command: 'VITE_CHAIN_ID=84532 npx vite --port 5182 --strictPort',
      url: 'http://localhost:5182',
      reuseExistingServer: true,
    },
  ],
})
