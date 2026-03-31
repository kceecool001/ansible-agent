import { useState, useEffect, useRef, useCallback } from 'react'

const WS_URL = import.meta.env.VITE_WS_URL || 'ws://localhost:8000'
const MAX_RECONNECT_DELAY = 60000 // 60 seconds
const INITIAL_RECONNECT_DELAY = 3000 // 3 seconds

export function useMetrics() {
  const [nodes, setNodes] = useState([])
  const [connected, setConnected] = useState(false)
  const [lastTs, setLastTs] = useState(null)
  const ws = useRef(null)
  const reconnectTimer = useRef(null)
  const reconnectDelay = useRef(INITIAL_RECONNECT_DELAY)

  const connect = useCallback(() => {
    if (ws.current?.readyState === WebSocket.OPEN) return

    ws.current = new WebSocket(`${WS_URL}/ws/metrics`)

    ws.current.onopen = () => {
      setConnected(true)
      reconnectDelay.current = INITIAL_RECONNECT_DELAY // Reset delay on successful connection
      clearTimeout(reconnectTimer.current)
      // keep-alive ping every 20s
      const ping = setInterval(() => {
        if (ws.current?.readyState === WebSocket.OPEN) {
          ws.current.send('ping')
        }
      }, 20_000)
      ws.current._ping = ping
    }

    ws.current.onmessage = (evt) => {
      try {
        const msg = JSON.parse(evt.data)
        if (msg.type === 'metrics') {
          setNodes(msg.nodes)
          setLastTs(msg.ts)
        }
      } catch {}
    }

    ws.current.onclose = () => {
      setConnected(false)
      clearInterval(ws.current?._ping)
      // Exponential backoff with max delay
      reconnectTimer.current = setTimeout(() => {
        reconnectDelay.current = Math.min(
          reconnectDelay.current * 2,
          MAX_RECONNECT_DELAY
        )
        connect()
      }, reconnectDelay.current)
    }

    ws.current.onerror = () => {
      ws.current?.close()
    }
  }, [])

  useEffect(() => {
    connect()
    return () => {
      clearTimeout(reconnectTimer.current)
      clearInterval(ws.current?._ping)
      ws.current?.close()
    }
  }, [connect])

  return { nodes, connected, lastTs }
}
