import { useEffect, useMemo, useState } from 'react'
import { useBlock, useConnection } from 'wagmi'
import { buildModel, pickTimes, type VaultModel } from '../lib/model'
import { useVaultData } from './useVaultData'

/** Wall-clock seconds, ticking once a second so projected balances move with Aave's interest. */
export function useNow(intervalMs = 1_000): bigint {
  const [now, setNow] = useState(() => BigInt(Math.floor(Date.now() / 1000)))
  useEffect(() => {
    const id = window.setInterval(() => setNow(BigInt(Math.floor(Date.now() / 1000))), intervalMs)
    return () => window.clearInterval(id)
  }, [intervalMs])
  return now
}

export function useModel(): { model: VaultModel | null; error: Error | null; isLoading: boolean } {
  const { address } = useConnection()
  const data = useVaultData(address)
  const now = useNow()
  // The latest block's timestamp: what the next call's simulation sees, and a floor for when it lands
  const block = useBlock({ watch: true })
  const chainTime = block.data?.timestamp
  const model = useMemo(() => {
    if (!data.static || !data.live) return null
    const times = pickTimes(now, chainTime, data.live.reserve.lastUpdateTimestamp)
    return buildModel(data.deployment, data.static, data.live, data.account, times.now, times.chainTime, times.chainKnown)
  }, [data.deployment, data.static, data.live, data.account, now, chainTime])
  return { model, error: (data.error as Error | null) ?? null, isLoading: data.isLoading }
}
