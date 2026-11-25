// The editor sidebar's category glyphs: white SF-Symbol look-alikes drawn on
// the colored rounded square (GradientIcon / categoryIcon in ProfileViews.swift).
// Filled SF symbols knock their detail out of the white shape, so these use a
// mask (the square's gradient shows through) rather than Lucide outlines.

import React from 'react';
import type { CategoryID } from './model';

let uid = 0;
function Masked({ shape, holes }: { shape: React.ReactNode; holes: React.ReactNode }) {
  const id = React.useMemo(() => `edg${++uid}`, []);
  return (
    <>
      <mask id={id} maskUnits="userSpaceOnUse" x="0" y="0" width="24" height="24">
        <g fill="#fff" stroke="#fff">{shape}</g>
        <g fill="#000" stroke="#000">{holes}</g>
      </mask>
      <rect width="24" height="24" fill="#fff" mask={`url(#${id})`} />
    </>
  );
}

const star = (x: number, y: number, s: number) =>
  `M${x} ${y - s}Q${x} ${y} ${x + s} ${y}Q${x} ${y} ${x} ${y + s}Q${x} ${y} ${x - s} ${y}Q${x} ${y} ${x} ${y - s}Z`;

const G: Record<CategoryID, () => React.ReactNode> = {
  general: () => <Masked
    shape={<rect x="2" y="5" width="20" height="14" rx="2.2" strokeWidth="0" />}
    holes={<g strokeWidth="0">
      <circle cx="7.6" cy="10" r="2" />
      <path d="M4.4 16.3c0-2.2 1.4-3.4 3.2-3.4s3.2 1.2 3.2 3.4z" />
      <rect x="12.3" y="8.6" width="7" height="1.5" rx=".5" /><rect x="12.3" y="11.3" width="7" height="1.5" rx=".5" /><rect x="12.3" y="14" width="5" height="1.5" rx=".5" />
    </g>} />,
  appearance: () => <Masked
    shape={<path strokeWidth="0" d="M12 2.8c-5.3 0-9.4 3.9-9.4 8.9 0 4.8 3.9 8.8 8.6 8.8 1.4 0 2.2-.8 2.2-1.9 0-1.3-1-1.7-1-2.9 0-1.1.9-1.8 2.1-1.8h2.4c2.8 0 4.6-1.7 4.6-4.2 0-3.8-4.2-6.9-9.5-6.9z" />}
    holes={<g strokeWidth="0"><circle cx="7.3" cy="11.2" r="1.7" /><circle cx="9.4" cy="7.1" r="1.7" /><circle cx="14" cy="6.6" r="1.7" /><circle cx="17.3" cy="9.6" r="1.7" /><circle cx="7.6" cy="15.9" r="1.7" /></g>} />,
  localModels: () => <g fill="#fff"><path d={star(14, 14.5, 6.5)} /><path d={star(7, 8.5, 3)} /><path d={star(10.5, 3.6, 1.5)} /></g>,
  fusion: () => <path fill="#fff" d="M14.2 1.8 5 13.6h6.3L9.8 22.2l9.3-12h-6.4z" />,
  squelch: () => <Masked
    shape={<circle cx="12" cy="12" r="9.6" strokeWidth="0" />}
    holes={<g strokeWidth="0"><rect x="6.8" y="7.9" width="10.4" height="1.7" rx=".85" /><rect x="8" y="11.15" width="8" height="1.7" rx=".85" /><rect x="9.6" y="14.4" width="4.8" height="1.7" rx=".85" /></g>} />,
  folders: () => <Masked
    shape={<path strokeWidth="0" d="M2.5 6.8c0-1.2.9-2 2-2h4.6c.6 0 1 .2 1.4.6l1.3 1.3h7.7c1.2 0 2 .9 2 2v9.4c0 1.2-.9 2-2 2h-15c-1.2 0-2-.9-2-2z" />}
    holes={<rect x="2.5" y="8.4" width="19" height=".9" strokeWidth="0" />} />,
  environment: () => <Masked
    shape={<rect x="2" y="4" width="20" height="16" rx="2.2" strokeWidth="0" />}
    holes={<g><path d="M5.3 7.9 7.6 9.5 5.3 11.1" fill="none" strokeWidth="1.3" strokeLinecap="round" strokeLinejoin="round" /><rect x="8.4" y="10.6" width="3.4" height="1.1" strokeWidth="0" /></g>} />,
  mcp: () => (
    <g transform="translate(3 3) scale(0.1)" fill="none" stroke="#fff" strokeWidth="20" strokeLinecap="round">
      <path d="M18 84.8528L85.8822 16.9706C95.2548 7.59798 110.451 7.59798 119.823 16.9706V16.9706C129.196 26.3431 129.196 41.5391 119.823 50.9117L68.5581 102.177" />
      <path d="M69.2652 101.47L119.823 50.9117C129.196 41.5391 144.392 41.5391 153.765 50.9117L154.118 51.2652C163.491 60.6378 163.491 75.8338 154.118 85.2063L92.7248 146.6C89.6006 149.724 89.6006 154.789 92.7248 157.913L105.331 170.52" />
      <path d="M102.853 33.9411L52.6482 84.1457C43.2756 93.5183 43.2756 108.714 52.6482 118.087V118.087C62.0208 127.459 77.2167 127.459 86.5893 118.087L136.794 67.8822" />
    </g>),
  browser: () => (
    <g fill="none" stroke="#fff" strokeWidth="1.4">
      <circle cx="12" cy="12" r="8.6" /><ellipse cx="12" cy="12" rx="4" ry="8.6" />
      <path d="M3.4 12h17.2M5 7.6h14M5 16.4h14M12 3.4v17.2" />
    </g>),
  resources: () => (
    <g fill="#fff">
      <rect x="3.5" y="7" width="17" height="10" rx="1.6" />
      {[5.5, 8, 10.5, 13, 15.5, 18].map(x => <React.Fragment key={x}><rect x={x - .55} y="4.9" width="1.1" height="2.4" /><rect x={x - .55} y="16.7" width="1.1" height="2.4" /></React.Fragment>)}
    </g>),
  credentials: () => <Masked
    shape={<g strokeWidth="0"><circle cx="12" cy="7.2" r="4.9" /><rect x="10.6" y="10" width="2.8" height="11.6" rx="1.1" /><rect x="12.4" y="14.6" width="3.1" height="1.9" rx=".5" /><rect x="12.4" y="17.6" width="2.4" height="1.9" rx=".5" /></g>}
    holes={<circle cx="12" cy="6" r="1.4" strokeWidth="0" />} />,
  tracing: () => (
    <g fill="none" stroke="#fff" strokeWidth="1.4" strokeLinecap="round">
      <path d="M11.5 20.2H7.2c-1.1 0-1.9-.8-1.9-1.9V5.6c0-1.1.8-1.9 1.9-1.9h8.6c1.1 0 1.9.8 1.9 1.9v6" />
      <path d="M8.5 7.6h6M8.5 10.6h6M8.5 13.6h3" />
      <circle cx="15.4" cy="16.6" r="2.6" /><path d="m17.3 18.5 2.2 2.2" />
    </g>),
  guardrails: () => <Masked
    shape={<path strokeWidth="0" d="M12 2.4 4.4 5.4v6.2c0 5 3.4 8.6 7.6 10.2 4.2-1.6 7.6-5.2 7.6-10.2V5.4z" />}
    holes={<g strokeWidth="0"><rect x="11" y="7" width="2" height="7" rx="1" /><circle cx="12" cy="16.6" r="1.25" /></g>} />,
  firewall: () => <Masked
    shape={<path strokeWidth="0" d="M12.6 2c.4 3.4 6.6 5.8 6.6 12.1 0 4.4-3.1 7.6-7.2 7.6s-7.2-3.1-7.2-7.4c0-3.2 1.7-5.4 3.4-6.9.1 2 .9 3.3 2.2 3.8C10.1 8.1 10.6 4.6 12.6 2z" />}
    holes={<path strokeWidth="0" d="M12.2 12.6c1.2 1.4 2.9 2.6 2.9 4.7 0 1.7-1.3 2.9-3 2.9s-3-1.2-3-2.8c0-1.9 1.6-3 3.1-4.8z" />} />,
  supplyChain: () => <Masked
    shape={<path strokeWidth="0" d="M12 2.4 20.6 6.8v10.4L12 21.6l-8.6-4.4V6.8z" />}
    holes={<g fill="none" strokeWidth="1.1" strokeLinejoin="round"><path d="M3.4 6.8 12 11.2l8.6-4.4M12 11.2v10.4" /><path d="M7.7 4.6l8.6 4.4" /></g>} />,
  promptInjection: () => <Masked
    shape={<path strokeWidth="1.6" strokeLinejoin="round" d="M12 3.6 21 19.4H3z" />}
    holes={<g strokeWidth="0"><rect x="11" y="8.6" width="2" height="6.4" rx="1" /><circle cx="12" cy="17.1" r="1.2" /></g>} />,
  pii: () => <Masked
    shape={<g><circle cx="13.2" cy="11" r="8" fill="none" strokeWidth="1.5" /><circle cx="13.2" cy="9" r="2.8" strokeWidth="0" /><path strokeWidth="0" d="M8.3 16.4c1-2.1 2.8-3.1 4.9-3.1s3.9 1 4.9 3.1c-1.3 1.3-3 2.1-4.9 2.1s-3.6-.8-4.9-2.1z" /><circle cx="6.4" cy="17.4" r="5" strokeWidth="0" /></g>}
    holes={<g><circle cx="6.4" cy="17.4" r="3.9" fill="none" strokeWidth="1" /><path d="m4.6 17.5 1.3 1.3 2.4-2.6" fill="none" strokeWidth="1.2" strokeLinecap="round" strokeLinejoin="round" /></g>} />,
  automation: () => (
    <g fill="none" stroke="#fff" strokeWidth="1.5" strokeLinecap="round">
      <circle cx="12" cy="10.4" r="1.6" fill="#fff" stroke="none" /><path d="M12 12.2v7.6" />
      <path d="M8.6 7.2a4.6 4.6 0 0 0 0 6.4M15.4 7.2a4.6 4.6 0 0 1 0 6.4M5.8 4.6a8.4 8.4 0 0 0 0 11.6M18.2 4.6a8.4 8.4 0 0 1 0 11.6" />
    </g>),
};

/** The 22pt colored rounded square with its white glyph. */
export function CategoryIcon({ id, color, size = 22 }: { id: CategoryID; color: [string, string]; size?: number }) {
  return (
    <span className="ed-caticon" style={{ width: size, height: size, background: `linear-gradient(${color[0]}, ${color[1]})` }}>
      <svg viewBox="0 0 24 24" width={size * 0.73} height={size * 0.73} aria-hidden>{G[id]()}</svg>
    </span>
  );
}
