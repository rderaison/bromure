// A failing view must never blank the whole window: each region (sidebar,
// stage, in-app windows) renders inside one of these. The error shows as a
// card with "Try Again"; the rest of the app keeps working.
import React from 'react';

export class ErrorBoundary extends React.Component<{ children: React.ReactNode; name: string; onReset?: () => void; resetKey?: unknown }, { error: Error | null }> {
  state = { error: null as Error | null };
  static getDerivedStateFromError(error: Error) { return { error }; }
  componentDidCatch(error: Error, info: React.ErrorInfo) { console.error(`[${this.props.name}]`, error, info.componentStack); }
  componentDidUpdate(prev: { resetKey?: unknown }) {
    if (this.state.error && prev.resetKey !== this.props.resetKey) this.setState({ error: null });
  }
  render() {
    if (!this.state.error) return this.props.children;
    return (
      <div style={{ flex: 1, display: 'grid', placeItems: 'center', padding: 24, minHeight: 0 }}>
        <div style={{ maxWidth: 420, textAlign: 'center', display: 'flex', flexDirection: 'column', gap: 10, alignItems: 'center' }}>
          <div style={{ fontWeight: 600, fontSize: 15 }}>Something went wrong showing this view.</div>
          <div className="secondary" style={{ fontSize: 12, userSelect: 'text' }}>{this.state.error.message}</div>
          <button className="btn" onClick={() => { this.setState({ error: null }); this.props.onReset?.(); }}>Try Again</button>
        </div>
      </div>
    );
  }
}
