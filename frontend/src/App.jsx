import { useState, useEffect, useRef, useMemo, memo } from 'react'
import { useMetrics } from './hooks/useMetrics'
import {
  LineChart, Line, BarChart, Bar, XAxis, YAxis,
  Tooltip, ResponsiveContainer
} from 'recharts'

const API = import.meta.env.VITE_API_URL || 'http://localhost:8000'

// ── Helpers ──────────────────────────────────────────────────────────────────

function pct(v) { return `${Math.round(v ?? 0)}%` }
function barColor(v) {
  if (v > 80) return '#f85149'
  if (v > 60) return '#e3b341'
  return '#3fb950'
}

function MetricBar({ value, max = 100 }) {
  const pctVal = Math.min(Math.round((value / max) * 100), 100)
  return (
    <div style={{ background: '#21262d', borderRadius: 3, height: 5, overflow: 'hidden' }}>
      <div style={{
        width: `${pctVal}%`, height: '100%',
        background: barColor(pctVal), transition: 'width 0.6s',
        borderRadius: 3,
      }} />
    </div>
  )
}

function KpiCard({ label, value, sub, trend, trendUp }) {
  return (
    <div style={styles.kpiCard}>
      <div style={styles.kpiLabel}>{label}</div>
      <div style={styles.kpiVal}>{value}</div>
      <div style={styles.kpiSub}>{sub}</div>
      {trend && (
        <div style={{ ...styles.kpiTrend, color: trendUp ? '#3fb950' : '#e3b341' }}>
          {trend}
        </div>
      )}
    </div>
  )
}

// Memoized components for performance
const NodeRow = memo(({ node }) => (
  <div style={styles.nodeRow}>
    <div style={styles.nodeHeader}>
      <div style={{ ...styles.nodeIcon, background: node.type === 'master' ? '#0d2818' : '#051220', color: node.type === 'master' ? '#3fb950' : '#58a6ff', borderColor: node.type === 'master' ? '#238636' : '#1f4a7a' }}>
        {node.type === 'master' ? 'M' : 'W'}
      </div>
      <div>
        <div style={{ fontFamily: 'monospace', fontSize: 12, color: '#e6edf3' }}>{node.name || node.host}</div>
        <div style={{ fontSize: 10, color: '#484f58' }}>{node.ip || node.host}</div>
      </div>
      <div style={{ marginLeft: 'auto' }}>
        <span style={{ ...styles.statusBadge, ...(node.status === 'ok' ? styles.statusOk : styles.statusErr) }}>
          {node.status === 'ok' ? 'READY' : 'UNREACHABLE'}
        </span>
      </div>
    </div>
    <div style={styles.nodeMetrics}>
      {[
        ['CPU', Math.round(node.cpu_idle_pct ? 100 - node.cpu_idle_pct : 0)],
        ['MEM', Math.round(node.mem_used_pct ?? 0)],
        ['DISK', Math.round(node.disk_used_pct ?? 0)],
        ['LOAD', node.load1 ?? 0],
      ].map(([label, val]) => (
        <div key={label}>
          <div style={{ fontSize: 10, color: '#484f58', marginBottom: 3 }}>{label}</div>
          <MetricBar value={label === 'LOAD' ? val * 10 : val} />
          <div style={{ fontFamily: 'monospace', fontSize: 10, color: '#8b949e', marginTop: 2 }}>
            {label === 'LOAD' ? val : pct(val)}
          </div>
        </div>
      ))}
    </div>
  </div>
))

const CPUChart = memo(({ data }) => (
  <ResponsiveContainer width="100%" height={180}>
    <LineChart data={data}>
      <XAxis dataKey="t" tick={{ fontSize: 10, fill: '#484f58' }} />
      <YAxis domain={[0, 100]} tick={{ fontSize: 10, fill: '#484f58' }} tickFormatter={v => v + '%'} />
      <Tooltip contentStyle={{ background: '#21262d', border: '1px solid #30363d', fontSize: 12 }} />
      <Line type="monotone" dataKey="v" stroke="#58a6ff" strokeWidth={1.5} dot={false} name="Avg CPU" />
    </LineChart>
  </ResponsiveContainer>
))

const ResourceChart = memo(({ data }) => (
  <ResponsiveContainer width="100%" height={160}>
    <BarChart data={data}>
      <XAxis dataKey="name" tick={{ fontSize: 9, fill: '#484f58' }} />
      <YAxis domain={[0, 100]} tick={{ fontSize: 9, fill: '#484f58' }} tickFormatter={v => v + '%'} />
      <Tooltip contentStyle={{ background: '#21262d', border: '1px solid #30363d', fontSize: 12 }} />
      <Bar dataKey="CPU" fill="#1f4a7a" />
      <Bar dataKey="MEM" fill="#1a2b0a" />
      <Bar dataKey="Disk" fill="#2d1f08" />
    </BarChart>
  </ResponsiveContainer>
))

// ── Main App ─────────────────────────────────────────────────────────────────

export default function App() {
  const { nodes, connected, lastTs } = useMetrics()
  const [cpuHistory, setCpuHistory] = useState(
    Array.from({ length: 12 }, (_, i) => ({ t: `-${11 - i}m`, v: 0 }))
  )
  const [logs, setLogs] = useState([
    { ts: '--:--:--', tag: 'INFO', msg: 'Agent started — waiting for first scrape…' },
  ])
  const [aiInput, setAiInput] = useState('')
  const [aiLoading, setAiLoading] = useState(false)
  const [aiResponse, setAiResponse] = useState(null)
  const [clock, setClock] = useState(new Date().toTimeString().slice(0, 8))

  // Rolling CPU history
  useEffect(() => {
    if (!nodes.length) return
    const avgCpu = nodes.reduce((a, n) => a + (n.cpu_idle_pct ? 100 - n.cpu_idle_pct : 0), 0) / nodes.length
    const now = new Date().toTimeString().slice(0, 5)
    setCpuHistory(prev => [...prev.slice(1), { t: now, v: Math.round(avgCpu) }])
  }, [nodes])

  // Live clock update
  useEffect(() => {
    const interval = setInterval(() => {
      setClock(new Date().toTimeString().slice(0, 8))
    }, 1000)
    return () => clearInterval(interval)
  }, [])

  const avgCpu = useMemo(() => 
    nodes.length
      ? Math.round(nodes.reduce((a, n) => a + (n.cpu_idle_pct ? 100 - n.cpu_idle_pct : 0), 0) / nodes.length)
      : 0,
    [nodes]
  )
  
  const avgMem = useMemo(() =>
    nodes.length
      ? Math.round(nodes.reduce((a, n) => a + (n.mem_used_pct ?? 0), 0) / nodes.length)
      : 0,
    [nodes]
  )

  const barData = useMemo(() => 
    nodes.map(n => ({
      name: n.name?.replace('worker-node-', 'W').replace('master-ctrl-', 'M') ?? n.host,
      CPU: Math.round(n.cpu_idle_pct ? 100 - n.cpu_idle_pct : 0),
      MEM: Math.round(n.mem_used_pct ?? 0),
      Disk: Math.round(n.disk_used_pct ?? 0),
    })),
    [nodes]
  )

  async function sendAI() {
    if (!aiInput.trim()) return
    setAiLoading(true)
    setAiResponse(null)
    addLog('RUN', `[ai-agent] ${aiInput.slice(0, 60)}`)
    try {
      const res = await fetch(`${API}/api/ai/run`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          prompt: aiInput,
          context: { nodes, avgCpu, avgMem },
        }),
      })
      const data = await res.json()
      setAiResponse(data.result)
      addLog('OK', `[ai-agent] ${data.result?.intent ?? 'Done'}`)
    } catch (e) {
      setAiResponse({ message: `Error: ${e.message}` })
      addLog('ERR', `[ai-agent] ${e.message}`)
    } finally {
      setAiLoading(false)
      setAiInput('')
    }
  }

  async function runPlaybook(playbook, limit = 'all') {
    addLog('RUN', `[playbook] Starting ${playbook} → limit=${limit}`)
    try {
      const res = await fetch(`${API}/api/playbook/run`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ playbook, limit }),
      })
      const data = await res.json()
      addLog(data.rc === 0 ? 'OK' : 'ERR', `[playbook] ${playbook} rc=${data.rc}`)
    } catch (e) {
      addLog('ERR', `[playbook] ${e.message}`)
    }
  }

  function addLog(tag, msg) {
    const ts = new Date().toTimeString().slice(0, 8)
    setLogs(prev => [{ ts, tag, msg }, ...prev].slice(0, 50))
  }

  return (
    <div style={styles.shell}>
      {/* ── Topbar ── */}
      <div style={styles.topbar}>
        <span style={styles.logo}>⬡ ansible/<strong>ai-agent</strong></span>
        <span style={{ ...styles.pill, color: connected ? '#3fb950' : '#f85149' }}>
          <span style={{ ...styles.dot, background: connected ? '#3fb950' : '#f85149' }} />
          {connected ? 'Live' : 'Reconnecting…'}
        </span>
        <span style={styles.badge}>{nodes.length} Nodes</span>
        <span style={{ marginLeft: 'auto', fontSize: 11, color: '#484f58', fontFamily: 'monospace' }}>
          {lastTs ? new Date(lastTs * 1000).toTimeString().slice(0, 8) : '--:--:--'} UTC
        </span>
      </div>

      {/* ── Body ── */}
      <div style={styles.body}>

        {/* KPIs */}
        <div style={styles.row4}>
          <KpiCard label="Total Nodes" value={nodes.length} sub="Scraped live"
            trend={nodes.length ? '↑ All reachable' : '● Waiting…'} trendUp />
          <KpiCard label="Avg CPU" value={pct(avgCpu)} sub="Cluster-wide"
            trend={avgCpu > 70 ? '↑ High load' : '● Normal'} trendUp={avgCpu < 70} />
          <KpiCard label="Avg Memory" value={pct(avgMem)} sub="Cluster-wide"
            trend={avgMem > 80 ? '↑ Pressure' : '● Normal'} trendUp={avgMem < 80} />
          <KpiCard label="Scrape interval" value="5s" sub="node_exporter"
            trend="● Prometheus format" trendUp />
        </div>

        {/* Node fleet + CPU chart */}
        <div style={styles.row2main}>
          <div style={styles.card}>
            <div style={styles.cardTitle}>Node Fleet <span style={styles.tag}>Live</span></div>
            {nodes.length === 0 && (
              <p style={{ color: '#484f58', fontSize: 12, marginTop: 8 }}>
                Waiting for first scrape… ensure node_exporter is running on your nodes.
              </p>
            )}
            {nodes.map(n => (
              <NodeRow key={n.host} node={n} />
            ))}
          </div>

          <div style={styles.card}>
            <div style={styles.cardTitle}>Cluster CPU — 12 min rolling</div>
            <CPUChart data={cpuHistory} />

            <div style={{ ...styles.cardTitle, marginTop: 16 }}>Resource distribution</div>
            <ResourceChart data={barData} />
          </div>
        </div>

        {/* Quick playbook buttons + log */}
        <div style={styles.row2}>
          <div style={styles.card}>
            <div style={styles.cardTitle}>Quick actions</div>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8, marginTop: 4 }}>
              {[
                ['Ping all', () => runPlaybook('ping.yml')],
                ['Deploy nginx', () => runPlaybook('nginx_deploy.yml', 'workers')],
                ['Patch workers', () => runPlaybook('patch.yml', 'workers')],
                ['Bootstrap', () => runPlaybook('bootstrap.yml')],
              ].map(([label, fn]) => (
                <button key={label} style={styles.btn} onClick={fn}>{label}</button>
              ))}
            </div>
          </div>
          <div style={styles.card}>
            <div style={styles.cardTitle}>Agent run log</div>
            <div style={{ fontFamily: 'monospace', fontSize: 11 }}>
              {logs.slice(0, 8).map((l, i) => (
                <div key={i} style={{ display: 'flex', gap: 8, padding: '4px 0', borderBottom: '1px solid #21262d' }}>
                  <span style={{ color: '#484f58', minWidth: 56 }}>{l.ts}</span>
                  <span style={{ ...styles.logTag, ...(l.tag === 'OK' ? styles.tagOk : l.tag === 'ERR' ? styles.tagErr : l.tag === 'RUN' ? styles.tagRun : styles.tagWarn) }}>{l.tag}</span>
                  <span style={{ color: '#8b949e', wordBreak: 'break-all' }}>{l.msg}</span>
                </div>
              ))}
            </div>
          </div>
        </div>
      </div>

      {/* ── AI response ── */}
      {aiResponse && (
        <div style={styles.aiResponse}>
          <strong style={{ color: '#bc8cff' }}>Agent:</strong>{' '}
          <span style={{ color: '#8b949e' }}>{aiResponse.message || JSON.stringify(aiResponse)}</span>
        </div>
      )}

      {/* ── AI command bar ── */}
      <div style={styles.aiBar}>
        <input
          style={styles.aiInput}
          value={aiInput}
          onChange={e => setAiInput(e.target.value)}
          onKeyDown={e => e.key === 'Enter' && sendAI()}
          placeholder="Ask the agent: run nginx playbook on workers, check disk, patch master…"
          disabled={aiLoading}
        />
        <button style={{ ...styles.aiBtn, opacity: aiLoading ? 0.6 : 1 }} onClick={sendAI} disabled={aiLoading}>
          {aiLoading ? '⟳ Thinking…' : 'Run ↗'}
        </button>
      </div>
    </div>
  )
}

// ── Styles ────────────────────────────────────────────────────────────────────

const styles = {
  shell:       { display: 'flex', flexDirection: 'column', minHeight: '100vh', background: '#0d1117', color: '#e6edf3', fontFamily: "'IBM Plex Sans', sans-serif", fontSize: 13 },
  topbar:      { display: 'flex', alignItems: 'center', gap: 12, padding: '10px 16px', background: '#161b22', borderBottom: '1px solid #30363d' },
  logo:        { fontFamily: 'monospace', fontSize: 13, color: '#3fb950', letterSpacing: '0.05em' },
  pill:        { display: 'flex', alignItems: 'center', gap: 6, background: '#21262d', border: '1px solid #30363d', borderRadius: 20, padding: '3px 10px', fontSize: 11 },
  dot:         { width: 7, height: 7, borderRadius: '50%' },
  badge:       { fontSize: 10, padding: '2px 7px', borderRadius: 4, border: '1px solid #1f4a7a', color: '#58a6ff', background: '#051220' },
  body:        { flex: 1, padding: 16, display: 'flex', flexDirection: 'column', gap: 14, overflowY: 'auto' },
  row4:        { display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 12 },
  row2main:    { display: 'grid', gridTemplateColumns: '1.6fr 1fr', gap: 12 },
  row2:        { display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 },
  card:        { background: '#161b22', border: '1px solid #30363d', borderRadius: 8, padding: 14 },
  cardTitle:   { fontSize: 11, fontWeight: 500, color: '#8b949e', letterSpacing: '0.06em', textTransform: 'uppercase', marginBottom: 10, display: 'flex', alignItems: 'center', justifyContent: 'space-between' },
  tag:         { fontSize: 10, color: '#484f58' },
  kpiCard:     { background: '#161b22', border: '1px solid #30363d', borderRadius: 8, padding: 14 },
  kpiLabel:    { fontSize: 11, fontWeight: 500, color: '#8b949e', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 4 },
  kpiVal:      { fontFamily: 'monospace', fontSize: 22, fontWeight: 500 },
  kpiSub:      { fontSize: 11, color: '#8b949e', marginTop: 2 },
  kpiTrend:    { fontSize: 11, marginTop: 4 },
  nodeRow:     { background: '#21262d', border: '1px solid #30363d', borderRadius: 6, padding: '10px 12px', marginBottom: 8 },
  nodeHeader:  { display: 'flex', alignItems: 'center', gap: 8, marginBottom: 8 },
  nodeIcon:    { width: 24, height: 24, borderRadius: 5, display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 10, fontWeight: 500, fontFamily: 'monospace', border: '1px solid', flexShrink: 0 },
  nodeMetrics: { display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 8 },
  statusBadge: { fontSize: 10, padding: '1px 6px', borderRadius: 3 },
  statusOk:    { background: '#0d2818', color: '#3fb950', border: '1px solid #238636' },
  statusErr:   { background: '#1c0a0a', color: '#f85149', border: '1px solid #6e2020' },
  btn:         { background: 'transparent', border: '1px solid #30363d', color: '#e6edf3', fontSize: 12, padding: '6px 12px', borderRadius: 6, cursor: 'pointer', fontFamily: 'monospace' },
  logTag:      { fontSize: 10, padding: '1px 5px', borderRadius: 3, minWidth: 36, textAlign: 'center' },
  tagOk:       { background: '#0d2818', color: '#3fb950' },
  tagErr:      { background: '#1c0a0a', color: '#f85149' },
  tagRun:      { background: '#051220', color: '#58a6ff' },
  tagWarn:     { background: '#1a1208', color: '#e3b341' },
  aiBar:       { display: 'flex', gap: 8, padding: '12px 16px', background: '#161b22', borderTop: '1px solid #30363d' },
  aiInput:     { flex: 1, background: '#21262d', border: '1px solid #30363d', borderRadius: 6, padding: '8px 12px', color: '#e6edf3', fontFamily: 'monospace', fontSize: 12, outline: 'none' },
  aiBtn:       { background: '#58a6ff', border: 'none', color: '#000', fontFamily: 'monospace', fontSize: 12, fontWeight: 500, padding: '8px 14px', borderRadius: 6, cursor: 'pointer' },
  aiResponse:  { margin: '0 16px 10px', padding: '10px 12px', background: '#21262d', border: '1px solid #30363d', borderRadius: 6, fontSize: 12, fontFamily: 'monospace' },
}
