import * as React from "react";

export interface ConfirmCardProps {
  /** Heading. Default "Run shell command?". */
  title?: string;
  /** The command body (monospace). */
  command?: string;
  /** pending shows Allow/Deny; allowed/denied collapse to an audit line. */
  state?: "pending" | "allowed" | "denied";
  /** The machine requesting approval — shown as a chip. */
  machine?: { name: string; color?: string };
  /** Provenance once resolved, e.g. "answered on iPhone". */
  answeredBy?: string;
  onAllow?: () => void;
  onDeny?: () => void;
  style?: React.CSSProperties;
}

/**
 * Inline shell-command approval card; answerable from any attached client.
 */
export declare function ConfirmCard(props: ConfirmCardProps): React.ReactElement;
