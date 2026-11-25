// Category → pane component (ProfileEditorView.detailContent(for:)).

import type React from 'react';
import type { CategoryID } from './model';
import { GeneralPane } from './categories/General';
import { AppearancePane } from './categories/Appearance';
import { ModelsPane } from './categories/Models';
import { FusionPane } from './categories/Fusion';
import { SquelchPane } from './categories/Squelch';
import { FoldersPane } from './categories/Folders';
import { EnvironmentPane } from './categories/Environment';
import { MCPPane } from './categories/MCP';
import { BrowserPane } from './categories/Browser';
import { ResourcesPane } from './categories/Resources';
import { CredentialsPane } from './categories/Credentials';
import { TracingPane } from './categories/Tracing';
import { GuardrailsPane } from './categories/Guardrails';
import { SandboxPolicyPane } from './categories/SandboxPolicy';
import { SupplyChainPane } from './categories/SupplyChain';
import { PromptInjectionPane } from './categories/PromptInjection';
import { PIIPane } from './categories/PII';

export const PANES: Partial<Record<CategoryID, React.ComponentType>> = {
  general: GeneralPane,
  appearance: AppearancePane,
  localModels: ModelsPane,
  fusion: FusionPane,
  squelch: SquelchPane,
  folders: FoldersPane,
  environment: EnvironmentPane,
  mcp: MCPPane,
  browser: BrowserPane,
  resources: ResourcesPane,
  credentials: CredentialsPane,
  tracing: TracingPane,
  guardrails: GuardrailsPane,
  firewall: SandboxPolicyPane,
  supplyChain: SupplyChainPane,
  promptInjection: PromptInjectionPane,
  pii: PIIPane,
};
