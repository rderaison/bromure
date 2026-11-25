import React from 'react';
import { createRoot } from 'react-dom/client';
import '@xterm/xterm/css/xterm.css';
import './ui/theme.css';
import './ui/kit/kit.css';
import { App } from './app/App';

createRoot(document.getElementById('root')!).render(<App />);
