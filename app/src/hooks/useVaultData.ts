import { useMemo } from 'react'
import type { Address } from 'viem'
import { useBalance, useReadContracts } from 'wagmi'
import { deployment } from '../config/chain'
import type { Deployment } from '../config/deployment'
import { decodeLive, decodeStatic, liveReads, staticReads, type AccountData, type LiveData, type Read, type StaticData } from '../lib/reads'

export type { AccountData, LiveData, StaticData }

const REFRESH_MS = 6_000

/** Named reads, decoded back into an object by key, so an added read cannot shift the others. */
function useNamedReads<K extends string>(reads: Record<K, Read> | null, query: { enabled?: boolean; staleTime?: number; refetchInterval?: number }) {
  const keys = useMemo(() => (reads ? (Object.keys(reads) as K[]) : []), [reads])
  const res = useReadContracts({
    allowFailure: false,
    contracts: (reads ? keys.map((k) => reads[k]) : []) as never,
    query: { ...query, enabled: (query.enabled ?? true) && !!reads },
  })
  const data = useMemo(() => {
    const r = res.data as unknown as readonly unknown[] | undefined
    if (!r) return undefined
    return Object.fromEntries(keys.map((k, i) => [k, r[i]])) as Record<K, unknown>
  }, [res.data, keys])
  return { ...res, data }
}

export function useVaultData(account: Address | undefined) {
  const d = deployment as Deployment
  const st = useNamedReads(useMemo(() => staticReads(d), [d]), { staleTime: Infinity })
  const staticData = useMemo((): StaticData | undefined => (st.data ? decodeStatic(st.data) : undefined), [st.data])

  const category = staticData?.eModeCategory
  const reads = useMemo(() => (category === undefined ? null : liveReads(d, category, account)), [d, category, account])
  const live = useNamedReads(reads, { refetchInterval: REFRESH_MS })
  const eth = useBalance({ address: account, query: { enabled: !!account, refetchInterval: REFRESH_MS } })

  const liveData = useMemo((): LiveData | undefined => (live.data ? decodeLive(live.data, account) : undefined), [live.data, account])

  const accountData = useMemo((): AccountData | undefined => {
    if (!account || !liveData?.account) return undefined
    return { ...liveData.account, eth: eth.data?.value }
  }, [account, liveData, eth.data?.value])

  return {
    deployment: d,
    static: staticData,
    live: liveData,
    account: accountData,
    error: st.error ?? live.error,
    isLoading: st.isLoading || live.isLoading,
    dataUpdatedAt: live.dataUpdatedAt,
  }
}
