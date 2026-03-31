import { Component } from 'react'

class ErrorBoundary extends Component {
  constructor(props) {
    super(props)
    this.state = { hasError: false, error: null, errorInfo: null }
  }

  static getDerivedStateFromError(error) {
    return { hasError: true }
  }

  componentDidCatch(error, errorInfo) {
    console.error('Error caught by boundary:', error, errorInfo)
    this.setState({ error, errorInfo })
  }

  render() {
    if (this.state.hasError) {
      return (
        <div style={styles.container}>
          <div style={styles.card}>
            <h1 style={styles.title}>⚠️ Something went wrong</h1>
            <p style={styles.message}>
              The dashboard encountered an unexpected error. Please refresh the page to continue.
            </p>
            <button 
              style={styles.button}
              onClick={() => window.location.reload()}
            >
              Refresh Page
            </button>
            {process.env.NODE_ENV === 'development' && this.state.error && (
              <details style={styles.details}>
                <summary style={styles.summary}>Error Details (dev only)</summary>
                <pre style={styles.pre}>
                  {this.state.error.toString()}
                  {this.state.errorInfo?.componentStack}
                </pre>
              </details>
            )}
          </div>
        </div>
      )
    }

    return this.props.children
  }
}

const styles = {
  container: {
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    minHeight: '100vh',
    background: '#0d1117',
    color: '#e6edf3',
    fontFamily: "'IBM Plex Sans', sans-serif",
    padding: '20px',
  },
  card: {
    background: '#161b22',
    border: '1px solid #30363d',
    borderRadius: '8px',
    padding: '32px',
    maxWidth: '600px',
    width: '100%',
  },
  title: {
    color: '#f85149',
    fontSize: '24px',
    marginBottom: '16px',
  },
  message: {
    color: '#8b949e',
    fontSize: '14px',
    lineHeight: '1.6',
    marginBottom: '24px',
  },
  button: {
    background: '#58a6ff',
    border: 'none',
    color: '#000',
    fontFamily: 'monospace',
    fontSize: '14px',
    fontWeight: '500',
    padding: '10px 20px',
    borderRadius: '6px',
    cursor: 'pointer',
  },
  details: {
    marginTop: '24px',
    fontSize: '12px',
  },
  summary: {
    cursor: 'pointer',
    color: '#58a6ff',
    marginBottom: '8px',
  },
  pre: {
    background: '#0d1117',
    border: '1px solid #30363d',
    borderRadius: '4px',
    padding: '12px',
    overflow: 'auto',
    fontSize: '11px',
    color: '#f85149',
  },
}

export default ErrorBoundary
